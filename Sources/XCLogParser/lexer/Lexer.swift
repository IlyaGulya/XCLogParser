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

public final class Lexer {

    static let SLFHeader = "SLF"

    let typeDelimiters: Set<Character>
    /// Byte-set equivalents of the character sets used while scanning. Built once here because
    /// `Scanner.scanCharacters(from:)` runs tens of millions of times per log.
    private let typeDelimiterBytes: ByteSet
    private let payloadBytes: ByteSet
    let filePath: String
    var classNames = [String]()
    var userDirToRedact: String? {
        get {
            redactor.userDirToRedact
        }
        set {
            redactor.userDirToRedact = newValue
        }
    }
    private var redactor: LogRedactor

    public init(filePath: String) {
        self.filePath = filePath
        self.typeDelimiters = Set(TokenType.all())
        self.typeDelimiterBytes = Lexer.singleByteSet(from: self.typeDelimiters)
        self.payloadBytes = Lexer.singleByteSet(from: Set("abcdef0123456789"))
        self.redactor = LexRedactor()
    }

    /// Tokenizes an xcactivitylog serialized in the `SLF` format
    /// - parameter contents: The contents of the .xcactivitylog
    /// - parameter redacted: If true, the user's directory will be replaced by `<redacted>`
    /// for privacy concerns.
    /// - parameter withoutBuildSpecificInformation: If true, build specific information will be removed from the logs.
    /// - returns: An array of all the `Token` in the log.
    /// - throws: An error if the document is not a valid SLF document
    public func tokenize(contents: String,
                         redacted: Bool,
                         withoutBuildSpecificInformation: Bool) throws -> [Token] {
        return try tokenize(scanner: Scanner(string: contents),
                            redacted: redacted,
                            withoutBuildSpecificInformation: withoutBuildSpecificInformation)
    }

    /// Tokenizes an xcactivitylog held as `Data`.
    ///
    /// The entry point for a real log, and the one the library and the benchmark both use. An
    /// `.xcactivitylog` is `Data` on disk, so this is where the bytes already are.
    ///
    /// It copies today: `Scanner` requires a `String`, so this decodes the whole log into one before
    /// scanning it. That copy is what later commits in this branch remove, by teaching `Scanner` to
    /// borrow the bytes instead of owning a decoded copy. The entry point exists from here so that
    /// every measurement of that work times the same call, rather than timing `tokenize(contents:)`
    /// until the day the byte path appears and then silently switching over.
    ///
    /// - parameter data: The decompressed .xcactivitylog.
    /// - parameter redacted: If true, the user's directory will be replaced by `<redacted>`.
    /// - parameter withoutBuildSpecificInformation: If true, build specific information is removed.
    /// - returns: An array of all the `Token` in the log.
    /// - throws: An error if the document is not a valid SLF document
    public func tokenize(data: Data,
                         redacted: Bool,
                         withoutBuildSpecificInformation: Bool) throws -> [Token] {
        return try tokenize(contents: String(decoding: data, as: UTF8.self),
                            redacted: redacted,
                            withoutBuildSpecificInformation: withoutBuildSpecificInformation)
    }

    /// The single tokenizing loop. Every public entry point funnels into this, so they cannot drift.
    private func tokenize(scanner: Scanner,
                          redacted: Bool,
                          withoutBuildSpecificInformation: Bool) throws -> [Token] {

        guard scanSLFHeader(scanner: scanner) else {
            throw XCLogParserError.invalidLogHeader(filePath)
        }

        var tokens = [Token]()
        // Growing this array geometrically dominated allocation profiling: `_consumeAndCreateNew`
        // reached 41.7% of all `swift_allocObject` calls in a full parse. Measured across two real
        // logs the ratio is roughly one token per 70 bytes of UTF-8 input (2_457_160/176_016_774 and
        // 1_453_770/278_297_242), so we deliberately under-reserve at 1/128 of the byte count: a
        // wrong estimate can only cost extra growth steps, never correctness.
        tokens.reserveCapacity(scanner.byteCount / 128)
        while !scanner.isAtEnd {

            guard scanSLFType(scanner: scanner,
                              into: &tokens,
                              redacted: redacted,
                              withoutBuildSpecificInformation: withoutBuildSpecificInformation) else {
                print(tokens)
                throw XCLogParserError.invalidLine(scanner.approximateLine)
            }
        }
        return tokens
    }

    private func scanSLFHeader(scanner: Scanner) -> Bool {
        return scanner.scan(string: Lexer.SLFHeader)
    }

    /// Scans one SLF value and appends the resulting `Token`s directly to `tokens`.
    ///
    /// This used to return a freshly allocated `[Token]` per call. Since the overwhelming majority of
    /// calls produce exactly one token, that was one array allocation for each of the ~2.13M tokens in
    /// a large log. Appending into the caller's buffer removes that allocation entirely.
    ///
    /// - returns: `false` when the line is malformed (no type delimiter, or no token could be scanned),
    /// which mirrors the old `nil`/empty-array failure conditions.
    private func scanSLFType(scanner: Scanner,
                             into tokens: inout [Token],
                             redacted: Bool,
                             withoutBuildSpecificInformation: Bool) -> Bool {
        let payload = self.scanPayload(scanner: scanner)

        guard let (firstType, extraRange) = self.scanTypeDelimiter(scanner: scanner) else {
            return false
        }

        // Tracks whether at least one token was produced, replicating the old
        // `logTokens.isEmpty == false` guard without materialising an array.
        var appendedAny = false
        // `handleClassNameTokenTypeCase` mutates `classNames` and `handleClassNameRefTokenTypeCase`
        // indexes into it, so tokens must be produced strictly in delimiter order.
        if let token = scanToken(scanner: scanner,
                                 payload: payload,
                                 tokenType: firstType,
                                 redacted: redacted,
                                 withoutBuildSpecificInformation: withoutBuildSpecificInformation) {
            tokens.append(token)
            appendedAny = true
        }
        if let extraRange = extraRange {
            // Iterating the byte range rather than an array of decoded types: the array existed only
            // to be walked once, right here. See `scanTypeDelimiter`.
            for index in extraRange {
                guard let byte = scanner.byte(at: index),
                      let tokenType = TokenType(byte: byte) else {
                    continue
                }
                if let token = scanToken(scanner: scanner,
                                         payload: payload,
                                         tokenType: tokenType,
                                         redacted: redacted,
                                         withoutBuildSpecificInformation: withoutBuildSpecificInformation) {
                    tokens.append(token)
                    appendedAny = true
                }
            }
        }
        return appendedAny
    }

    /// Keeps only the characters that encode to a single UTF-8 byte, matching the
    /// behaviour of the previous per-call conversion inside `Scanner`.
    private static func singleByteSet(from characters: Set<Character>) -> ByteSet {
        ByteSet(characters.compactMap { character -> UInt8? in
            let characterBytes = Array(String(character).utf8)
            return characterBytes.count == 1 ? characterBytes[0] : nil
        })
    }

    /// The byte range of the value's payload - a decimal length, an index, or a hex-encoded double.
    ///
    /// Returned as a range rather than a `String`: every consumer parses it as a number, so building a
    /// string first was an allocation and a UTF-8 validation per token for nothing.
    private func scanPayload(scanner: Scanner) -> Range<Int> {
        return scanner.scanCharacters(from: payloadBytes)
    }

    /// Scans the type delimiter(s) of an SLF value.
    ///
    /// Returns the first `TokenType` plus, only in the rare multi-delimiter case, the byte range holding
    /// the remaining delimiters.
    ///
    /// Splitting the result this way means the common single-delimiter case — the overwhelming majority
    /// of the ~2.13M calls per large log — allocates no array at all, where the previous `compactMap`
    /// allocated one every time.
    ///
    /// The multi-delimiter case returns a *range* rather than a decoded `[TokenType]` for the same
    /// reason taken one step further: that array was built only to be iterated once by the single
    /// caller, and it was still 112,848 allocations - 49% of all array growth - on the flagged
    /// benchmark log. The caller now decodes each byte as it walks the range, which is the same work
    /// in the same order, minus the array.
    private func scanTypeDelimiter(scanner: Scanner) -> (first: TokenType, extra: Range<Int>?)? {
        let delimiterRange = scanner.scanCharacters(from: self.typeDelimiterBytes)
        guard let firstByte = scanner.byte(at: delimiterRange.lowerBound),
              // Every byte came from `typeDelimiters`, so this always succeeds.
              let firstType = TokenType(byte: firstByte) else {
            return nil
        }

        if delimiterRange.count > 1 {
            // if we found a string, we discard other type delimiters because there are part of the string
            if firstType == .string {
                scanner.moveOffset(by: -(delimiterRange.count - 1))
                return (.string, nil)
            }
            // sometimes we found one or more nil list (-) next to the type delimiter
            // in that case we'll return the delimiter and one or more `Token.null`
            return (firstType, delimiterRange.dropFirst())
        }
        return (firstType, nil)
    }

    private func scanToken(scanner: Scanner,
                           payload: Range<Int>,
                           tokenType: TokenType,
                           redacted: Bool,
                           withoutBuildSpecificInformation: Bool) -> Token? {
        switch tokenType {
        case .int:
            return handleIntTokenTypeCase(scanner: scanner, payload: payload)
        case .className:
            return handleClassNameTokenTypeCase(scanner: scanner,
                                                payload: payload,
                                                redacted: redacted,
                                                withoutBuildSpecificInformation: withoutBuildSpecificInformation)
        case .classNameRef:
            return handleClassNameRefTokenTypeCase(scanner: scanner, payload: payload)
        case .string:
            return handleStringTokenTypeCase(scanner: scanner,
                                             payload: payload,
                                             redacted: redacted,
                                             withoutBuildSpecificInformation: withoutBuildSpecificInformation)
        case .double:
            return handleDoubleTokenTypeCase(scanner: scanner, payload: payload)
        case .null:
            return .null
        case .list:
            return handleListTokenTypeCase(scanner: scanner, payload: payload)
        case .json:
            return handleJSONTokenTypeCase(scanner: scanner,
                                           payload: payload,
                                           redacted: redacted,
                                           withoutBuildSpecificInformation: withoutBuildSpecificInformation)
        }
    }

    private func handleIntTokenTypeCase(scanner: Scanner, payload: Range<Int>) -> Token? {
        guard let value = scanner.unsignedInteger(in: payload) else {
            print("error parsing int")
            return nil
        }
        return .int(value)
    }

    private func handleClassNameTokenTypeCase(scanner: Scanner,
                                              payload: Range<Int>,
                                              redacted: Bool,
                                              withoutBuildSpecificInformation: Bool) -> Token? {
        guard let className = scanString(length: payload,
                                         scanner: scanner,
                                         redacted: redacted,
                                         withoutBuildSpecificInformation: withoutBuildSpecificInformation) else {
                                            print("error parsing string")
                                            return nil
        }
        classNames.append(className)
        return .className(className)
    }

    private func handleClassNameRefTokenTypeCase(scanner: Scanner, payload: Range<Int>) -> Token? {
        guard let parsed = scanner.unsignedInteger(in: payload), let value = Int(exactly: parsed) else {
            print("error parsing classNameRef")
            return nil
        }
        // Bounds-checked because the index comes from the log, not from us. `classNames` is populated by
        // the `className` tokens seen so far, so a malformed document can reference an entry that does
        // not exist - a payload of `0` gives -1, and any index past the declarations is out of range.
        // Subscripting directly crashed the process with "Index out of range"; returning nil reports it
        // as an invalid line, which is how every other malformed payload here behaves. Found by
        // differential testing over generated SLF documents ("SLF01@356098f239dfc041^" is enough).
        let element = value - 1
        guard classNames.indices.contains(element) else {
            print("error parsing classNameRef: no class name at index \(value)")
            return nil
        }
        return .classNameRef(classNames[element])
    }

    private func handleStringTokenTypeCase(scanner: Scanner,
                                           payload: Range<Int>,
                                           redacted: Bool,
                                           withoutBuildSpecificInformation: Bool) -> Token? {
        guard let content = scanString(length: payload,
                                       scanner: scanner,
                                       redacted: redacted,
                                       withoutBuildSpecificInformation: withoutBuildSpecificInformation) else {
                                        print("error parsing string")
                                        return nil
        }
        return .string(content)
    }

    private func handleJSONTokenTypeCase(scanner: Scanner,
                                         payload: Range<Int>,
                                         redacted: Bool,
                                         withoutBuildSpecificInformation: Bool) -> Token? {
        guard let content = scanString(length: payload,
                                       scanner: scanner,
                                       redacted: redacted,
                                       withoutBuildSpecificInformation: withoutBuildSpecificInformation) else {
                                        print("error parsing string")
                                        return nil
        }
        return .json(content)
    }

    private func handleDoubleTokenTypeCase(scanner: Scanner, payload: Range<Int>) -> Token? {
        guard let bigEndianBits = scanner.unsignedInteger(in: payload, radix: 16) else {
            print("error parsing double")
            return nil
        }
        return .double(Double(bitPattern: bigEndianBits.byteSwapped))
    }

    private func handleListTokenTypeCase(scanner: Scanner, payload: Range<Int>) -> Token? {
        guard let parsed = scanner.unsignedInteger(in: payload), let value = Int(exactly: parsed) else {
            print("error parsing list")
            return nil
        }
        return .list(value)
    }

    private func scanString(length: Range<Int>,
                            scanner: Scanner,
                            redacted: Bool,
                            withoutBuildSpecificInformation: Bool) -> String? {
        guard let parsed = scanner.unsignedInteger(in: length), let value = Int(exactly: parsed),
              let scannedResult = scanner.scan(count: value) else {
            print("error parsing string")
            return nil
        }

        var result = scannedResult
        if redacted {
            result = redactor.redactUserDir(string: result)
        }
        if withoutBuildSpecificInformation {
            result = result
                .removeProductBuildIdentifier()
                .removeHexadecimalNumbers()
        }
        return result
    }

}

private extension Scanner {
    var approximateLine: String {
        preview(count: 21)
    }
}
