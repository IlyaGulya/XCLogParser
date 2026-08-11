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

final class Scanner {

    /// The input, borrowed rather than owned.
    ///
    /// A pointer, not an `[UInt8]`, so that the caller can keep the log in whatever it already has -
    /// in practice the `Data` returned by gunzip. Copying that into an `Array` cost a full extra copy
    /// of the log (+297 MB on a 265 MB log, measured per stage) purely to satisfy this type.
    ///
    /// The scanner therefore does NOT keep the input alive. Every instance must live inside the
    /// `withUnsafeBytes` closure that produced the pointer; `Lexer.tokenize` is the only thing that
    /// creates one on a real log, and it does exactly that.
    private let bytes: UnsafeRawBufferPointer

    private(set) var offset: Int

    /// How many bytes there are to scan.
    ///
    /// Exposed so `Lexer.tokenize` can size its token array from the input without knowing how the
    /// scanner stores it - the input arrives as a `String`, an `[UInt8]` or a `Data` depending on the
    /// entry point, and the loop is shared.
    var byteCount: Int {
        bytes.count
    }

    var isAtEnd: Bool {
        offset >= bytes.count
    }

    /// Scans `bytes` in place, without copying or retaining them.
    ///
    /// - important: `bytes` must remain valid for the whole lifetime of this scanner. See the note on
    /// the `bytes` property.
    init(bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
        self.offset = 0
    }

    /// Runs `body` with a scanner over the UTF-8 bytes of `string`.
    ///
    /// For tests and other callers that have a `String` literal rather than a log. Takes a closure
    /// because the scanner may not outlive the buffer it borrows, which a plain initializer could not
    /// enforce.
    static func withScanner<T>(string: String, _ body: (Scanner) throws -> T) rethrows -> T {
        let bytes = Array(string.utf8)
        return try bytes.withUnsafeBytes { try body(Scanner(bytes: $0)) }
    }

    func scan(count: Int) -> String? {
        let endOffset = self.offset + count

        guard count >= 0, endOffset <= bytes.count else { return nil }

        // Behaviour change on malformed input only: `String(bytes:encoding:)` returned nil for invalid
        // UTF-8, failing the whole line, where `String(decoding:)` substitutes U+FFFD. Valid UTF-8 -
        // every real log, and every fixture here - decodes identically, and this avoids the copy the
        // failable initialiser makes.
        let result = string(in: offset..<endOffset)

        self.offset += count

        return result
    }

    func scan(string value: String) -> Bool {
        let valueBytes = Array(value.utf8)
        let endOffset = offset + valueBytes.count
        guard endOffset <= bytes.count,
              bytes[offset..<endOffset].elementsEqual(valueBytes)
        else { return false }

        self.offset += valueBytes.count
        return true
    }

    /// Scans while the current byte is in `allowedBytes`, returning the byte range consumed.
    ///
    /// Returns a range rather than a `String` because the callers do not want a string: the lexer
    /// either parses the run as a number or looks at its first byte. Materialising one meant a heap
    /// allocation plus a UTF-8 validation pass per token, tens of millions of times per log - and
    /// `String(bytes:encoding:)` also copies. `scanCharacters` was the hottest function in the lexer;
    /// see `Lexer.scanPayload` and `unsignedInteger(in:)` for what replaced the parsing.
    ///
    /// - parameter allowedBytes: The bytes to accept. Callers build this once and reuse it.
    func scanCharacters(from allowedBytes: ByteSet) -> Range<Int> {
        let startOffset = offset

        while offset < bytes.count, allowedBytes.contains(bytes[offset]) {
            self.offset += 1
        }

        return startOffset..<offset
    }

    /// The byte at `index`, or `nil` when it is out of bounds.
    func byte(at index: Int) -> UInt8? {
        guard index >= 0, index < bytes.count else {
            return nil
        }
        return bytes[index]
    }

    /// The bytes in `range`, decoded as UTF-8.
    ///
    /// Every caller that still needs a `String` goes through here, so the decode stays in one place.
    func string(in range: Range<Int>) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes[range], as: UTF8.self)
    }

    /// Parses `bytes[range]` as a base-`radix` unsigned integer, or `nil` if it is empty or contains a
    /// digit that is not valid in that radix.
    ///
    /// This is what lets `scanCharacters` return a range: the lexer's payloads are all numbers - a
    /// decimal length, a class-name index, a hex-encoded double - so they can be accumulated straight
    /// from the bytes instead of being built into a `String` and handed to `UInt64.init(_:)`.
    ///
    /// Overflow returns `nil` rather than trapping, which matches what `UInt64("...")` does on a run of
    /// digits too long to represent.
    func unsignedInteger(in range: Range<Int>, radix: UInt64 = 10) -> UInt64? {
        // A sign is accepted, to stay interchangeable with the initializer this replaced: `UInt64("+1")`
        // is 1, and `UInt64("-0")` is 0 - negative zero being the one negative an unsigned type can
        // represent. Both were found by differential sweep, not by reading the documentation. The
        // payload byte set contains neither sign, so neither can arise from the lexer, but the two
        // should not differ where they need not.
        var digits = range
        var negative = false
        if let first = byte(at: digits.lowerBound),
           first == UInt8(ascii: "+") || first == UInt8(ascii: "-") {
            negative = first == UInt8(ascii: "-")
            digits = (digits.lowerBound + 1)..<digits.upperBound
        }
        guard !digits.isEmpty else {
            return nil
        }
        var value: UInt64 = 0
        for index in digits {
            guard let digit = Scanner.digitValue(bytes[index], radix: radix) else {
                return nil
            }
            let (multiplied, overflowedMultiply) = value.multipliedReportingOverflow(by: radix)
            guard !overflowedMultiply else {
                return nil
            }
            let (added, overflowedAdd) = multiplied.addingReportingOverflow(digit)
            guard !overflowedAdd else {
                return nil
            }
            value = added
        }
        // "-0" is 0; any other negative has no unsigned representation.
        if negative && value != 0 {
            return nil
        }
        return value
    }

    /// The value of an ASCII digit in `radix`, or `nil` if `byte` is not one.
    ///
    /// Both cases are accepted for hex digits, matching `Int(_:radix:)`.
    private static func digitValue(_ byte: UInt8, radix: UInt64) -> UInt64? {
        let value: UInt64
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            value = UInt64(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "z"):
            value = UInt64(byte - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "Z"):
            value = UInt64(byte - UInt8(ascii: "A")) + 10
        default:
            return nil
        }
        return value < radix ? value : nil
    }

    func moveOffset(by value: Int) {
        self.offset += value
    }

    func preview(count: Int) -> String {
        let endOffset = min(offset + count, bytes.count)
        return string(in: offset..<endOffset)
    }
}
