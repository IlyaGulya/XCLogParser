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

import XCTest
@testable import XCLogParser

class LexerTests: XCTestCase {

    let lexer = Lexer(filePath: "dummy.xcactivitylog")

    func testTokenizeInt() throws {
        let logContents = "SLF09#"
        let tokens = try lexer.tokenize(contents: logContents, redacted: false, withoutBuildSpecificInformation: false)
        XCTAssertEqual(1, tokens.count)
        let classNameToken = tokens[0]
        XCTAssertEqual(classNameToken, Token.int(9))
    }

    func testTokenizeClassName() throws {
        let logContents = "SLF09#21%IDEActivityLogSection"
        let tokens = try lexer.tokenize(contents: logContents, redacted: false, withoutBuildSpecificInformation: false)
        XCTAssertEqual(2, tokens.count)
        let classNameToken = tokens[1]
        XCTAssertEqual(classNameToken, Token.className("IDEActivityLogSection"))
    }

    func testTokenizeClassNameRef() throws {
        let logContents = "SLF09#21%IDEActivityLogSection1@"
        let tokens = try lexer.tokenize(contents: logContents, redacted: false, withoutBuildSpecificInformation: false)
        XCTAssertTrue(tokens.count == 3)
        let classNameReferenceToken = tokens[2]
        XCTAssertEqual(classNameReferenceToken, Token.classNameRef("IDEActivityLogSection"))
    }

    func testTokenizeString() throws {
        let logContents = "SLF09#21%IDEActivityLogSection1@39\"Xcode.IDEActivityLogDomainType.BuildLog"
        let tokens = try lexer.tokenize(contents: logContents, redacted: false, withoutBuildSpecificInformation: false)
        XCTAssertTrue(tokens.count == 4)
        let stringToken = tokens[3]
        XCTAssertEqual(stringToken, Token.string("Xcode.IDEActivityLogDomainType.BuildLog"))
    }

    func testTokenizeStringUsesUTF8ByteLength() throws {
        let value = "➜ Sources/Bundle+Locali🙂"
        let logContents = "SLF0#\(value.utf8.count)\"\(value)1#"

        let tokens = try lexer.tokenize(contents: logContents, redacted: false, withoutBuildSpecificInformation: false)

        XCTAssertEqual(tokens, [.int(0), .string(value), .int(1)])
    }

    func testTokenizeDouble() throws {
        let logContents = "SLF09#21%IDEActivityLogSection1@39\"Xcode.IDEActivityLogDomainType.BuildLog356098f239dfc041^"
        let tokens = try lexer.tokenize(contents: logContents, redacted: false, withoutBuildSpecificInformation: false)
        XCTAssertTrue(tokens.count == 5)
        let doubleToken = tokens[4]
        XCTAssertEqual(doubleToken, Token.double(566129637.19043601))
    }

    func testTokenizeListNil() throws {
        let logContents = "SLF09#21%IDEActivityLogSection1" +
                          "@39\"Xcode.IDEActivityLogDomainType.BuildLog356098f239dfc041^-"
        let tokens = try lexer.tokenize(contents: logContents, redacted: false, withoutBuildSpecificInformation: false)
        XCTAssertTrue(tokens.count == 6)
        let nilToken = tokens[5]
        XCTAssertEqual(nilToken, Token.null)
    }

    func testTokenizeList() throws {
        let logContents = "SLF09#21%IDEActivityLogSection1" +
                            "@39\"Xcode.IDEActivityLogDomainType.BuildLog356098f239dfc041^-242("
        let tokens = try lexer.tokenize(contents: logContents, redacted: false, withoutBuildSpecificInformation: false)
        XCTAssertTrue(tokens.count == 7)
        let listToken = tokens[6]
        XCTAssertEqual(listToken, Token.list(242))
    }

    func testTokenizeError() {
        // `=` is not a valid token identifier, we should throw an error
        let logContents = "SLF09#21%IDEActivityLogSection1" +
        "@39\"Xcode.IDEActivityLogDomainType.BuildLog356098f239dfc041^-242="
        XCTAssertThrowsError(try lexer.tokenize(contents: logContents,
                                                redacted: false,
                                                withoutBuildSpecificInformation: false))
    }

    func testTokenizeStringWithTokenDelimiters() throws {
        let logContents = "SLF09#21%IDEActivityLogSection1" +
        "@38\"##Xcode.IDEActivityLogDomainType.Build356098f239dfc0^-242("
        let tokens = try lexer.tokenize(contents: logContents, redacted: false, withoutBuildSpecificInformation: false)
        XCTAssertTrue(tokens.count == 7)

    }

    func testTokenizeStringRedacted() throws {
        let logContents = "SLF09#21%IDEActivityLogSection1@36\"Compile /Users/myuser/project/File.m"
        let tokens = try lexer.tokenize(contents: logContents, redacted: true, withoutBuildSpecificInformation: false)
        XCTAssertTrue(tokens.count == 4)
        let stringToken = tokens[3]
        XCTAssertEqual(stringToken, Token.string("Compile /Users/<redacted>/project/File.m"))
    }

    func testTokenizeStringWithoutBuildSpecificInformation() throws {
        let logContents = "SLF09#21%IDEActivityLogSection1@385\"/Applications/Xcode.app/Contents/Developer/" +
            "Toolchains/XcodeDefault.xctoolchain/usr/bin/libtool: file: /Users/myuser/Library/Developer/Xcode/" +
            "DerivedData/Product-bolnckhlbzxpxoeyfujluasoupft/Build/Intermediates.noindex/Product.build/" +
            "Debug-iphonesimulator/Library.build/Objects-normal/x86_64/Object.o is not an object file" +
        " (not allowed in a library) some hexadecimal number 0x7fcdc8712290"

        let tokens = try lexer.tokenize(contents: logContents, redacted: false, withoutBuildSpecificInformation: true)
        XCTAssertTrue(tokens.count == 4)
        let stringToken = tokens[3]
        XCTAssertEqual(stringToken, Token.string("/Applications/Xcode.app/Contents/Developer/Toolchains/" +
            "XcodeDefault.xctoolchain/usr/bin/libtool: file: /Users/myuser/Library/Developer/Xcode/" +
            "DerivedData/Product/Build/Intermediates.noindex/Product.build/Debug-iphonesimulator/" +
            "Library.build/Objects-normal/x86_64/Object.o is not an object file (not allowed in a library) " +
            "some hexadecimal number <hexadecimal_number>"))
    }

    func testTokenizeStringRedactedAndWithoutBuildSpecificInformation() throws {
        let logContents = "SLF09#21%IDEActivityLogSection1@385\"/Applications/Xcode.app/Contents/Developer/" +
            "Toolchains/XcodeDefault.xctoolchain/usr/bin/libtool: file: /Users/myuser/Library/Developer/Xcode/" +
            "DerivedData/Product-bolnckhlbzxpxoeyfujluasoupft/Build/Intermediates.noindex/Product.build/" +
            "Debug-iphonesimulator/Library.build/Objects-normal/x86_64/Object.o is not an object file" +
        " (not allowed in a library) some hexadecimal number 0x7fcdc8712290"

        let tokens = try lexer.tokenize(contents: logContents, redacted: true, withoutBuildSpecificInformation: true)
        XCTAssertTrue(tokens.count == 4)
        let stringToken = tokens[3]
        XCTAssertEqual(stringToken, Token.string("/Applications/Xcode.app/Contents/Developer/Toolchains/" +
            "XcodeDefault.xctoolchain/usr/bin/libtool: file: /Users/<redacted>/Library/Developer/Xcode/" +
            "DerivedData/Product/Build/Intermediates.noindex/Product.build/Debug-iphonesimulator/" +
            "Library.build/Objects-normal/x86_64/Object.o is not an object file (not allowed in a library) " +
            "some hexadecimal number <hexadecimal_number>"))
    }

    /// A `classNameRef` that names a class index which was never declared must not crash.
    ///
    /// `handleClassNameRefTokenTypeCase` subscripted `classNames` with an index taken straight from the
    /// log, so a malformed document killed the process with "Index out of range" rather than reporting an
    /// invalid line. Found by differential testing over generated SLF documents.
    /// It now throws `invalidLine`, which is how the lexer reports every other unusable payload.
    func testTokenizeClassNameRefWithNoDeclaredClassThrowsRatherThanCrashing() {
        // Reference to class 1 with no `%` class-name token before it.
        XCTAssertThrowsError(try lexer.tokenize(contents: "SLF01@356098f239dfc041^",
                                                redacted: false,
                                                withoutBuildSpecificInformation: false))
    }

    /// Index 0 is the other end of the same bug: `value - 1` makes it -1, so a bounds check that only
    /// tested the upper end would still crash here.
    func testTokenizeClassNameRefZeroThrowsRatherThanCrashing() {
        XCTAssertThrowsError(try lexer.tokenize(contents: "SLF09#21%IDEActivityLogSection0@",
                                                redacted: false,
                                                withoutBuildSpecificInformation: false))
    }

    /// `Scanner` now borrows an `UnsafeRawBufferPointer` instead of owning an `[UInt8]`, which is what
    /// removes the copy of the log. That is only safe because every `Token` owns its own `String`: if a
    /// token ever kept a range into the input instead, the values read here would be garbage. This test
    /// exists to fail loudly if that invariant is broken, since the failure would otherwise be a silent
    /// use-after-free rather than a wrong answer.
    func testTokensOutliveTheScannedBuffer() throws {
        let expected = "Xcode.IDEActivityLogDomainType.BuildLog"
        var tokens: [Token] = []
        do {
            // Scoped so the Data is released before the tokens are inspected. Freshly allocated rather
            // than a literal, so the bytes are heap storage that can actually be reclaimed.
            var data = Data("SLF09#21%IDEActivityLogSection1@39\"\(expected)".utf8)
            tokens = try lexer.tokenize(data: data,
                                        redacted: false,
                                        withoutBuildSpecificInformation: false)
            data.removeAll(keepingCapacity: false)
        }
        // Churn the heap, so a dangling read is likely to see something other than the original bytes.
        for _ in 0..<64 {
            _ = Data(repeating: 0xAA, count: 4096)
        }
        XCTAssertEqual(tokens.last, .string(expected))
    }


    /// `TokenType(byte:)` replaced `TokenType(rawValue: String(UnicodeScalar(byte)))` in the lexer's
    /// hot path. The two must agree for every possible byte, not just the eight delimiters - a byte
    /// that wrongly produced a type would silently mis-tokenize a log.
    func testTokenTypeByteInitMatchesRawValueInitForEveryByte() {
        for byte in UInt8.min...UInt8.max {
            let viaRawValue = TokenType(rawValue: String(UnicodeScalar(byte)))
            XCTAssertEqual(TokenType(byte: byte),
                           viaRawValue,
                           "disagreed on byte 0x\(String(byte, radix: 16))")
        }
    }
}
