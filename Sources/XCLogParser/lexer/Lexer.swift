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
    private let typeDelimiterBytes: Set<UInt8>
    private let payloadBytes: Set<UInt8>
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
        while !scanner.isAtEnd {

            guard let logTokens = scanSLFType(scanner: scanner,
                                              redacted: redacted,
                                              withoutBuildSpecificInformation: withoutBuildSpecificInformation),
                  logTokens.isEmpty == false else {
                print(tokens)
                throw XCLogParserError.invalidLine(scanner.approximateLine)
            }
            tokens.append(contentsOf: logTokens)
        }
        return tokens
    }

    private func scanSLFHeader(scanner: Scanner) -> Bool {
        return scanner.scan(string: Lexer.SLFHeader)
    }

    private func scanSLFType(scanner: Scanner,
                             redacted: Bool,
                             withoutBuildSpecificInformation: Bool) -> [Token]? {
        let payload = self.scanPayload(scanner: scanner)

        guard let tokenTypes = self.scanTypeDelimiter(scanner: scanner), tokenTypes.count > 0 else {
            return nil
        }

        return tokenTypes.compactMap { tokenType -> Token? in
            scanToken(scanner: scanner,
                      payload: payload,
                      tokenType: tokenType,
                      redacted: redacted,
                      withoutBuildSpecificInformation: withoutBuildSpecificInformation)
        }
    }

    /// Keeps only the characters that encode to a single UTF-8 byte, matching the
    /// behaviour of the previous per-call conversion inside `Scanner`.
    private static func singleByteSet(from characters: Set<Character>) -> Set<UInt8> {
        Set(characters.compactMap { character -> UInt8? in
            let characterBytes = Array(String(character).utf8)
            return characterBytes.count == 1 ? characterBytes[0] : nil
        })
    }

    private func scanPayload(scanner: Scanner) -> String {
        return scanner.scanCharacters(from: payloadBytes) ?? ""
    }

    private func scanTypeDelimiter(scanner: Scanner) -> [TokenType]? {
        guard let delimiters = scanner.scanCharacters(from: self.typeDelimiterBytes) else {
            return nil
        }

        if delimiters.count > 1 {
            // if we found a string, we discard other type delimiters because there are part of the string
            let tokenString = TokenType.string
            if let char = delimiters.first, tokenString.rawValue == String(char) {
                scanner.moveOffset(by: -(delimiters.count - 1))
                return [tokenString]
            }
        }
        // sometimes we found one or more nil list (-) next to the type delimiter
        // in that case we'll return the delimiter and one or more `Token.null`
        return delimiters.compactMap { character -> TokenType? in
            TokenType(rawValue: String(character))
        }
    }

    private func scanToken(scanner: Scanner,
                           payload: String,
                           tokenType: TokenType,
                           redacted: Bool,
                           withoutBuildSpecificInformation: Bool) -> Token? {
        switch tokenType {
        case .int:
            return handleIntTokenTypeCase(payload: payload)
        case .className:
            return handleClassNameTokenTypeCase(scanner: scanner,
                                                payload: payload,
                                                redacted: redacted,
                                                withoutBuildSpecificInformation: withoutBuildSpecificInformation)
        case .classNameRef:
            return handleClassNameRefTokenTypeCase(payload: payload)
        case .string:
            return handleStringTokenTypeCase(scanner: scanner,
                                             payload: payload,
                                             redacted: redacted,
                                             withoutBuildSpecificInformation: withoutBuildSpecificInformation)
        case .double:
            return handleDoubleTokenTypeCase(payload: payload)
        case .null:
            return .null
        case .list:
            return handleListTokenTypeCase(payload: payload)
        case .json:
            return handleJSONTokenTypeCase(scanner: scanner,
                                           payload: payload,
                                           redacted: redacted,
                                           withoutBuildSpecificInformation: withoutBuildSpecificInformation)
        }
    }

    private func handleIntTokenTypeCase(payload: String) -> Token? {
        guard let value = UInt64(payload) else {
            print("error parsing int")
            return nil
        }
        return .int(value)
    }

    private func handleClassNameTokenTypeCase(scanner: Scanner,
                                              payload: String,
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

    private func handleClassNameRefTokenTypeCase(payload: String) -> Token? {
        guard let value = Int(payload) else {
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
                                           payload: String,
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
                                         payload: String,
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

    private func handleDoubleTokenTypeCase(payload: String) -> Token? {
        guard let double = hexToInt(payload) else {
            print("error parsing double")
            return nil
        }
        return .double(double)
    }

    private func handleListTokenTypeCase(payload: String) -> Token? {
        guard let value = Int(payload) else {
            print("error parsing list")
            return nil
        }
        return .list(value)
    }

    private func scanString(length: String,
                            scanner: Scanner,
                            redacted: Bool,
                            withoutBuildSpecificInformation: Bool) -> String? {
        guard let value = Int(length), let scannedResult = scanner.scan(count: value) else {
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

    private func hexToInt(_ input: String) -> Double? {
        guard let beValue = UInt64(input, radix: 16) else {
            return nil
        }
        let result =  Double(bitPattern: beValue.byteSwapped)
        return result
    }
}

private extension Scanner {
    var approximateLine: String {
        preview(count: 21)
    }
}
