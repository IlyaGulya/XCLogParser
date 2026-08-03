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

class ExactNeedleTests: XCTestCase {

    /// The needles actually used in the parser.
    private let patterns = [
        "-Wdeprecated", "deprecated", " deprecated:", "was deprecated in",
        "has been deprecated", "is deprecated", "-ftime-trace", "-print_statistics",
        "-debug-time-function-bodies", "-debug-time-expression-type-checking"
    ]

    func testMatchesFoundationContains() {
        for pattern in patterns {
            let needle = ExactNeedle(pattern)
            for input in ["", pattern, "pre \(pattern) post", pattern.uppercased(),
                          "\(pattern)\(pattern)", "x", " \(pattern)"] {
                XCTAssertEqual(needle.matches(input), input.contains(pattern),
                               "pattern=\(pattern) input=\(input.debugDescription)")
            }
        }
    }

    /// The search must not fold case - these call sites use `contains`/`range(of:)`
    /// without options, so an uppercased needle must not match.
    func testIsCaseSensitive() {
        XCTAssertTrue(ExactNeedle("deprecated").matches("is deprecated"))
        XCTAssertFalse(ExactNeedle("deprecated").matches("is DEPRECATED"))
        XCTAssertFalse(ExactNeedle("-Wdeprecated").matches("-wdeprecated"))
    }

    /// A combining mark fused onto the end of an otherwise-matching region defeats
    /// `String.contains`, so the byte search must agree by falling back rather
    /// than reporting a match. See `CaseFolding`'s doc comment.
    func testCombiningMarkAgreesWithFoundation() {
        for scalar in 0x0300...0x036F {
            let mark = String(UnicodeScalar(scalar)!)
            for pattern in patterns {
                let fused = pattern + mark
                XCTAssertEqual(ExactNeedle(pattern).matches(fused), fused.contains(pattern),
                               "pattern=\(pattern) mark=U+\(String(scalar, radix: 16))")
            }
        }
    }

    /// A non-ASCII scalar that is *not* a combining mark starts its own cluster, so
    /// Foundation does match through it. These are the cases an "any non-ASCII byte
    /// means no match" shortcut would get wrong.
    func testNonCombiningNonAsciiStillMatches() {
        for suffix in ["é", "日", "\u{212A}"] {
            let input = "is deprecated" + suffix
            XCTAssertTrue(input.contains("is deprecated"))
            XCTAssertTrue(ExactNeedle("is deprecated").matches(input))
        }
    }

    func testEmptyNeedleMatchesFoundation() {
        XCTAssertEqual(ExactNeedle("").matches("abc"), "abc".contains(""))
    }
}
