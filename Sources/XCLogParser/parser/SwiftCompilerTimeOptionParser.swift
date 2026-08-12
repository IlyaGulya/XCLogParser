// Copyright (c) 2019 Spotify AB.
//
// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import Foundation

/// Parses `swiftc` commands for time compiler outputs
protocol SwiftCompilerTimeOptionParser {

    associatedtype SwiftcOption

    /// Returns true if the compiler command included the flag to generate
    /// this compiler report
    /// - Parameter commandDesc: The command description
    func hasCompilerFlag(commandDesc: String) -> Bool

    /// Parses the Set of commands to look for swift compiler time outputs of type `SwiftcOption`
    /// - Parameter commands: Dictionary of command descriptions and ocurrences
    /// - Returns: A dictionary using the key as file and the Compiler time output as value
    func parse(from commands: [String: Int]) -> [String: [SwiftcOption]]

    /// Parses one command's raw timing text.
    ///
    /// `parse(from:)` needs every text at once, which means holding them all. Section texts here run
    /// to a megabyte each, so a caller that can parse one and drop it wants this instead. The file
    /// grouping that `parse(from:)` does afterwards is `merge(_:into:)`.
    ///
    /// - Returns: the options in this text, or `nil` if it holds none.
    func parse(command: String, occurrences: Int) -> [SwiftcOption]?

    /// Parses one already-split timing line.
    ///
    /// A section's text holds both kinds of line - function bodies have three tab-separated fields,
    /// expression type checks have two - so a caller with both parsers would otherwise split the same
    /// megabyte of text twice. Splitting once and offering each line to both parsers is the same work
    /// for the parser and half the work for the text.
    ///
    /// - Parameter fields: the line's tab-separated fields, as slices of the text.
    /// - Returns: the option, or `nil` if this line is not of this parser's kind.
    func parse(fields: [Substring], occurrences: Int) -> SwiftcOption?

    /// The UTF-8 form of `parse(fields:occurrences:)`.
    ///
    /// Splitting a `String` by `Character` runs grapheme breaking over every byte, which on a flagged
    /// fleet log means 176 MB of it. Both separators are ASCII, so splitting the UTF-8 view gives the
    /// same fields for several times less work - and the fields are then converted only where a
    /// `String` is actually needed.
    func parse(utf8Fields: [String.UTF8View.SubSequence],
               occurrences: Int,
               fileURLs: FileURLCache) -> SwiftcOption?

    /// The file each option belongs to, for grouping.
    ///
    /// The two option types name the field the same way but do not share a protocol, and giving them
    /// one for a single property is more machinery than reading it here.
    func file(of option: SwiftcOption) -> String

}

extension SwiftCompilerTimeOptionParser {

    /// Adds `options` to `grouped`, keyed by file.
    ///
    /// The accumulating half of `parse(from:)`, split out so a caller can parse one text at a time and
    /// let each one go before decoding the next.
    func merge(_ options: [SwiftcOption], into grouped: inout [String: [SwiftcOption]]) {
        for option in options {
            grouped[file(of: option), default: []].append(option)
        }
    }

}

extension SwiftCompilerTimeOptionParser {

    /// Parses /users/mnf/project/SomeFile.swift:10:12
    /// - Returns: ("file:///users/mnf/project/SomeFile.swift", 10, 12)
    func parseNameAndLocation(from fileAndLocation: String)
        -> (String, Int, Int)? { // swiftlint:disable:this large_tuple
        parseNameAndLocation(from: fileAndLocation[...])
    }

    /// The `Substring` form, so a caller that already sliced a line does not have to rebuild a `String`
    /// for it.
    ///
    /// Splits on `:` by index rather than with `components(separatedBy:)`. That call allocates an array
    /// and a `String` per part, and this runs once per timing line - millions of times on a log built
    /// with the flags, where it was the largest single source of string allocation in the parse.
    func parseNameAndLocation(from fileAndLocation: Substring)
        -> (String, Int, Int)? { // swiftlint:disable:this large_tuple
        // /users/mnf/project/SomeFile.swift:10:12 - the last two colons separate line and column, and
        // the path itself may contain colons, so scan from the end.
        guard let lastColon = fileAndLocation.lastIndex(of: ":") else {
            return nil
        }
        let beforeLast = fileAndLocation[..<lastColon]
        guard let secondLastColon = beforeLast.lastIndex(of: ":") else {
            return nil
        }

        let rawFile = fileAndLocation[..<secondLastColon]
        guard rawFile != "<invalid loc>" else {
            return nil
        }
        // `components(separatedBy:)` produced exactly three parts, so a path with its own colon was
        // rejected. Keeping that: anything before the line and column must hold no colon of its own.
        guard !rawFile.contains(":") else {
            return nil
        }

        guard let line = Int(beforeLast[beforeLast.index(after: secondLastColon)...]),
              let column = Int(fileAndLocation[fileAndLocation.index(after: lastColon)...]) else {
            return nil
        }

        return (prefixWithFileURL(fileName: String(rawFile)), line, column)
    }

    /// Parses
    func parseCompileDuration(_ durationString: String) -> Double {
        parseCompileDuration(durationString[...])
    }

    /// The `Substring` form. Slices a trailing `ms` off instead of calling
    /// `replacingOccurrences(of:with:)`, which built a fresh `String` for every timing line.
    ///
    /// The old spelling removed `ms` from anywhere in the field, so `"1ms2"` parsed as 12. That only
    /// differs for input `swiftc` does not produce - a duration is a number then the unit - but the
    /// fallback keeps it identical rather than nearly so.
    func parseCompileDuration(_ durationString: Substring) -> Double {
        if durationString.hasSuffix("ms"), let duration = Double(durationString.dropLast(2)) {
            return duration
        }
        if let duration = Double(durationString) {
            return duration
        }
        return Double(durationString.replacingOccurrences(of: "ms", with: "")) ?? 0.0
    }

    /// Transforms the fileName to a file URL to match the one in IDELogSection.documentURL
    /// It doesn't use `URL` class to do it, because it was slow in benchmarks
    /// - Parameter fileName: String with a fileName
    /// - Returns: A String with the URL to the file like `file:///`
    func prefixWithFileURL(fileName: String) -> String {
        return "file://\(fileName)"
    }

    /// The byte form of `parseNameAndLocation`, for a field that has not been made a `String` yet.
    ///
    /// Same rules as the `Substring` form: the last two colons separate line and column, and anything
    /// before them holding a colon of its own is rejected - which is what `components(separatedBy:)`
    /// did by requiring exactly three parts. Only the file name becomes a `String`, because it is the
    /// key the times are grouped by; the numbers are read straight from the digits.
    func parseNameAndLocation(fromUTF8 field: String.UTF8View.SubSequence,
                              fileURLs: FileURLCache)
        -> (String, Int, Int)? { // swiftlint:disable:this large_tuple
        let colon = UInt8(ascii: ":")
        guard let lastColon = field.lastIndex(of: colon) else {
            return nil
        }
        let beforeLast = field[..<lastColon]
        guard let secondLastColon = beforeLast.lastIndex(of: colon) else {
            return nil
        }
        let rawFile = field[..<secondLastColon]
        guard !rawFile.contains(colon) else {
            return nil
        }
        guard let line = Self.asciiInteger(beforeLast[beforeLast.index(after: secondLastColon)...]),
              let column = Self.asciiInteger(field[field.index(after: lastColon)...]) else {
            return nil
        }
        guard let file = fileURLs.url(forPathBytes: rawFile) else {
            return nil
        }
        return (file, line, column)
    }

    /// The byte form of `parseCompileDuration`.
    func parseCompileDuration(fromUTF8 field: String.UTF8View.SubSequence) -> Double {
        var digits = field
        if digits.count >= 2, digits.last == UInt8(ascii: "s"),
           digits[digits.index(digits.endIndex, offsetBy: -2)] == UInt8(ascii: "m") {
            digits = digits[..<digits.index(digits.endIndex, offsetBy: -2)]
        }
        // `Double` has no initializer over bytes, so this is the one field that still builds a string.
        // It is short - a handful of digits - where the signature and path are not.
        // swiftlint:disable:next optional_data_string_conversion
        return parseCompileDuration(String(decoding: digits, as: UTF8.self)[...])
    }

    /// Reads a non-negative decimal integer, or `nil` if the bytes are not exactly one.
    ///
    /// `Int(someSubstring)` would do this, but only after a `String` exists to hand it.
    static func asciiInteger(_ bytes: String.UTF8View.SubSequence) -> Int? {
        guard !bytes.isEmpty else {
            return nil
        }
        var value = 0
        for byte in bytes {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else {
                return nil
            }
            let (multiplied, overflowMultiply) = value.multipliedReportingOverflow(by: 10)
            guard !overflowMultiply else { return nil }
            let (added, overflowAdd) = multiplied.addingReportingOverflow(Int(byte - UInt8(ascii: "0")))
            guard !overflowAdd else { return nil }
            value = added
        }
        return value
    }
}
