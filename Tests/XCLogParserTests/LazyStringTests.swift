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
import Foundation
@testable import XCLogParser

/// Tests for the deferred form of `Token.string` - see `LazyString`. Kept out of `LexerTests` only
/// because that class is at its length limit.
class LazyStringTests: XCTestCase {

    var lexer = Lexer(filePath: "/tmp/xcactivitylog")

    override func setUp() {
        super.setUp()
        lexer = Lexer(filePath: "/tmp/xcactivitylog")
    }

    /// Only `tokenize(data:)` can defer decoding, because only it retains the log. A `Lexer` reused
    /// across entry points must not carry that retained log into the next call: while the deferred
    /// state was a sticky property rather than a per-call argument, the following `bytes:` call read
    /// this call's ranges out of the previous call's bytes and returned wrong strings silently.
    func testReusedLexerDoesNotReadOneLogsRangesFromAnother() throws {
        let first = "SLF04\"aaaa"
        let second = "SLF06\"bbbbbb"
        for _ in 0..<3 {
            _ = try lexer.tokenize(data: Data(first.utf8),
                                   redacted: false,
                                   withoutBuildSpecificInformation: false)
            XCTAssertEqual(try lexer.tokenize(bytes: Array(second.utf8),
                                              redacted: false,
                                              withoutBuildSpecificInformation: false),
                           [.string(LazyString("bbbbbb"))])
            XCTAssertEqual(try lexer.tokenize(contents: second,
                                              redacted: false,
                                              withoutBuildSpecificInformation: false),
                           [.string(LazyString("bbbbbb"))])
        }
    }

    /// A deferred string must survive the `Data` argument going out of scope at the call site: the
    /// tokens retain the log themselves, and reading one later must not touch freed memory.
    func testDeferredStringOutlivesTheCallSitesData() throws {
        var tokens: [Token] = []
        for index in 0..<64 {
            let value = String(repeating: "x", count: 4 + index % 7)
            tokens = try lexer.tokenize(data: Data("SLF0\(value.utf8.count)\"\(value)".utf8),
                                        redacted: false,
                                        withoutBuildSpecificInformation: false)
            XCTAssertEqual(tokens, [.string(LazyString(value))])
        }
        // Read again after 63 further logs have been tokenized and released.
        XCTAssertEqual(tokens, [.string(LazyString(String(repeating: "x", count: 4 + 63 % 7)))])
    }

}
