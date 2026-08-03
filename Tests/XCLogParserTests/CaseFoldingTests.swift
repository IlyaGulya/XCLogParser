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

/// Differential tests for the case-insensitive matchers in `Prefix.swift`.
///
/// These go through `Prefix`/`Contains`/`Suffix` rather than calling `CaseFolding`
/// directly, because the contract being tested belongs to the pair: the byte path
/// may answer `nil` and hand over to Foundation whenever it likes, and the only
/// thing that must hold is that the visible answer never changes. Testing the fast
/// path alone would pin an implementation detail and miss the handover entirely.
///
/// The reference is `lowercased().starts(with:)`/`.contains`/`.hasSuffix` - exactly
/// what these types replaced.
class CaseFoldingTests: XCTestCase {

    /// Patterns taken from the parser's own `switch` statements, plus the empty
    /// pattern, whose three answers disagree with each other by design.
    private let patterns = [
        "CompileSwift ", "CompileC ", "Ld ", "PhaseScriptExecution ", "Lexical",
        "error: Swiftc", "Command PhaseScriptExecution", "Semantic Issue",
        "failed with a nonzero exit code", ".xcactivitylog", "Notice", ""
    ]

    private func inputs(around pattern: String) -> [String] {
        return [
            "", pattern, pattern.uppercased(), pattern.lowercased(),
            "pre " + pattern, pattern + " post", "pre " + pattern + " post",
            pattern + pattern, "x", " ", String(pattern.dropLast()),
            pattern.isEmpty ? "" : String(pattern.dropFirst())
        ]
    }

    func testPrefixAgreesWithFoundation() {
        for pattern in patterns {
            let matcher = Prefix(pattern)
            for input in inputs(around: pattern) {
                let expected = input.lowercased().starts(with: pattern.lowercased())
                XCTAssertEqual(matcher ~= input, expected,
                               "pattern=\(pattern.debugDescription) input=\(input.debugDescription)")
            }
        }
    }

    func testContainsAgreesWithFoundation() {
        for pattern in patterns {
            let matcher = Contains(pattern)
            for input in inputs(around: pattern) {
                let expected = input.lowercased().contains(pattern.lowercased())
                XCTAssertEqual(matcher ~= input, expected,
                               "pattern=\(pattern.debugDescription) input=\(input.debugDescription)")
            }
        }
    }

    func testSuffixAgreesWithFoundation() {
        for pattern in patterns {
            let matcher = Suffix(pattern)
            for input in inputs(around: pattern) {
                let expected = input.lowercased().hasSuffix(pattern.lowercased())
                XCTAssertEqual(matcher ~= input, expected,
                               "pattern=\(pattern.debugDescription) input=\(input.debugDescription)")
            }
        }
    }

    /// `contains("")` is `false` while `starts(with: "")` and `hasSuffix("")` are
    /// `true`. The byte path special-cases the empty needle to preserve exactly that
    /// asymmetry, so it gets its own test rather than hiding inside a sweep.
    func testEmptyPatternKeepsFoundationsAsymmetry() {
        XCTAssertTrue(Prefix("") ~= "anything")
        XCTAssertTrue(Suffix("") ~= "anything")
        XCTAssertFalse(Contains("") ~= "anything")
        XCTAssertTrue(Prefix("") ~= "")
        XCTAssertTrue(Suffix("") ~= "")
        XCTAssertFalse(Contains("") ~= "")
    }

    /// A combining mark fused onto the last cluster compared changes Foundation's
    /// answer. `asciiStarts` examines one byte past the pattern for exactly this
    /// reason; if it ever stopped doing so, this test is what fails.
    func testCombiningMarkAgreesWithFoundation() {
        for scalar in 0x0300...0x036F {
            let mark = String(UnicodeScalar(scalar)!)
            for pattern in patterns where !pattern.isEmpty {
                let fused = pattern + mark
                let lowered = pattern.lowercased()
                XCTAssertEqual(Prefix(pattern) ~= fused, fused.lowercased().starts(with: lowered),
                               "prefix=\(pattern.debugDescription) mark=U+\(String(scalar, radix: 16))")
                XCTAssertEqual(Contains(pattern) ~= fused, fused.lowercased().contains(lowered),
                               "contains=\(pattern.debugDescription) mark=U+\(String(scalar, radix: 16))")
                XCTAssertEqual(Suffix(pattern) ~= fused, fused.lowercased().hasSuffix(lowered),
                               "suffix=\(pattern.debugDescription) mark=U+\(String(scalar, radix: 16))")
            }
        }
    }

    /// U+212A KELVIN SIGN lowercases to ASCII "k", so a pattern containing "k" can
    /// match input that holds no ASCII "k" at all. Any shortcut that answered from
    /// the bytes alone would get these wrong; the fast path must decline.
    func testScalarsThatLowercaseIntoAsciiAgreeWithFoundation() {
        let cases = [
            ("\u{212A}", "k"),      // KELVIN SIGN -> k
            ("\u{212B}", "\u{e5}"), // ANGSTROM SIGN -> a-ring, not ASCII, but same shape of hazard
            ("\u{0130}", "i")       // LATIN CAPITAL I WITH DOT ABOVE -> "i" + combining dot
        ]
        for (exotic, _) in cases {
            for input in ["Lin\(exotic) ", "\(exotic)d ", "wor\(exotic)", exotic] {
                XCTAssertEqual(Prefix("Ld ") ~= input,
                               input.lowercased().starts(with: "ld "), input.debugDescription)
                XCTAssertEqual(Contains("k") ~= input,
                               input.lowercased().contains("k"), input.debugDescription)
                XCTAssertEqual(Suffix("k") ~= input,
                               input.lowercased().hasSuffix("k"), input.debugDescription)
            }
        }
    }

    /// Non-ASCII that is neither combining nor case-folding into ASCII still starts
    /// its own cluster, so Foundation matches straight through it. These are the
    /// cases an "any non-ASCII means no match" shortcut would get wrong.
    func testNonCombiningNonAsciiStillMatches() {
        for suffix in ["é", "日", "🙂"] {
            let input = "CompileSwift " + suffix
            XCTAssertTrue(Prefix("CompileSwift ") ~= input)
            XCTAssertTrue(Contains("compileswift") ~= input)
            XCTAssertTrue(Suffix(suffix) ~= input)
        }
    }

    /// Embedded NUL is a legal byte in a log payload and must not terminate a scan.
    func testEmbeddedNulBytesAgreeWithFoundation() {
        let inputs = ["Ld \u{0}x", "\u{0}Ld ", "a\u{0}b", "\u{0}"]
        for input in inputs {
            XCTAssertEqual(Prefix("Ld ") ~= input, input.lowercased().starts(with: "ld "),
                           input.debugDescription)
            XCTAssertEqual(Contains("ld ") ~= input, input.lowercased().contains("ld "),
                           input.debugDescription)
            XCTAssertEqual(Suffix("b") ~= input, input.lowercased().hasSuffix("b"),
                           input.debugDescription)
        }
    }

    /// A pattern longer than the input must be rejected without reading out of
    /// bounds - the `bytes.count >= pattern.count` guard in `firstMatch`.
    func testPatternLongerThanInput() {
        for pattern in patterns where !pattern.isEmpty {
            for input in ["", "x", String(pattern.prefix(1))] {
                XCTAssertEqual(Prefix(pattern) ~= input,
                               input.lowercased().starts(with: pattern.lowercased()))
                XCTAssertEqual(Contains(pattern) ~= input,
                               input.lowercased().contains(pattern.lowercased()))
                XCTAssertEqual(Suffix(pattern) ~= input,
                               input.lowercased().hasSuffix(pattern.lowercased()))
            }
        }
    }

    /// A random sweep over a small alphabet, which hits overlap and near-miss shapes
    /// that hand-written cases tend to miss ("aab" searched for in "aaab").
    func testDifferentialSweep() {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return seed
        }
        let alphabet = Array("aAbB \u{0}é")
        func randomString(maxLength: Int) -> String {
            let length = Int(next() % UInt64(maxLength + 1))
            return String((0..<length).map { _ in alphabet[Int(next() % UInt64(alphabet.count))] })
        }

        for _ in 0..<2000 {
            let pattern = randomString(maxLength: 4)
            let input = randomString(maxLength: 10)
            let lowered = pattern.lowercased()
            XCTAssertEqual(Prefix(pattern) ~= input, input.lowercased().starts(with: lowered),
                           "prefix=\(pattern.debugDescription) input=\(input.debugDescription)")
            XCTAssertEqual(Contains(pattern) ~= input, input.lowercased().contains(lowered),
                           "contains=\(pattern.debugDescription) input=\(input.debugDescription)")
            XCTAssertEqual(Suffix(pattern) ~= input, input.lowercased().hasSuffix(lowered),
                           "suffix=\(pattern.debugDescription) input=\(input.debugDescription)")
        }
    }
}
