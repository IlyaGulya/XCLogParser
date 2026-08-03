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
import XCTest
@testable import XCLogParser

/// Differential tests for the byte scanner that replaced `Notice.clangWarningRegexp`.
///
/// `parseClangWarningFlags` is private, so these go through `Notice.parseFromLogSection` and read the
/// `clangFlag` of each resulting notice - the only externally visible effect of the flags list.
class ClangWarningFlagsTests: XCTestCase {

    /// What the original implementation did, kept here as the differential reference.
    private func referenceFlags(_ text: String) -> [String] {
        guard let regexp = Notice.clangWarningRegexp else {
            return []
        }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regexp.matches(in: text, options: .reportCompletion, range: range).map {
            String(text.substring($0.range))
        }
    }

    /// The scanner's flags, recovered via the one public entry point that exposes them.
    ///
    /// `parseFromLogSection` zips the flags against `logSection.messages`, so the section needs at
    /// least as many messages as there are flags for all of them to surface.
    private func parsedFlags(_ text: String, count: Int) -> [String] {
        let messages = (0..<count).map { index in
            IDEActivityLogMessage(title: "m\(index)",
                                  shortTitle: "",
                                  timeEmitted: 0,
                                  rangeEndInSectionText: 0,
                                  rangeStartInSectionText: 0,
                                  subMessages: [],
                                  severity: 0,
                                  type: "",
                                  location: DVTTextDocumentLocation(documentURLString: "",
                                                                    timestamp: 0,
                                                                    startingLineNumber: 0,
                                                                    startingColumnNumber: 0,
                                                                    endingLineNumber: 0,
                                                                    endingColumnNumber: 0,
                                                                    characterRangeEnd: 0,
                                                                    characterRangeStart: 0,
                                                                    locationEncoding: 0),
                                  categoryIdent: "",
                                  secondaryLocations: [],
                                  additionalDescription: "")
        }
        let section = IDEActivityLogSection(sectionType: 1,
                                           domainType: "",
                                           title: "title",
                                           signature: "signature",
                                           timeStartedRecording: 0,
                                           timeStoppedRecording: 1,
                                           subSections: [],
                                           text: text,
                                           messages: messages,
                                           wasCancelled: false,
                                           isQuiet: false,
                                           wasFetchedFromCache: false,
                                           subtitle: "",
                                           location: DVTDocumentLocation(documentURLString: "",
                                                                         timestamp: 0),
                                           commandDetailDesc: "",
                                           uniqueIdentifier: "id",
                                           localizedResultString: "",
                                           xcbuildSignature: "",
                                           attachments: [],
                                           unknown: 0)
        return Notice.parseFromLogSection(section, forType: .other, truncLargeIssues: false)
            .compactMap { $0.clangFlag }
    }

    private func assertAgrees(_ text: String, file: StaticString = #file, line: UInt = #line) {
        let expected = referenceFlags(text)
        XCTAssertEqual(parsedFlags(text, count: max(expected.count, 1)), expected,
                       "disagreed on \(text.debugDescription)", file: file, line: line)
    }

    func testMatchesRegexOnRealisticDiagnostics() {
        assertAgrees("/a/b.m:3:1: warning: unused variable 'x' [-Wunused-variable]")
        assertAgrees("""
        /a/b.m:3:1: warning: one [-Wunused-variable]
        /a/c.m:9:2: warning: two [-Wunused-function]
        """)
        assertAgrees("no flags here at all")
        assertAgrees("")
    }

    /// The cases where the pattern does not mean what it looks like it means.
    func testMatchesRegexOnPatternEdgeCases() {
        // Whole match, not the capture group: brackets and every trailing "]" are kept.
        assertAgrees("[[-Wx]]")
        assertAgrees("[-W]]] tail")
        // `[\w-,]*` accepts an empty body, and punctuation only.
        assertAgrees("[-W]")
        assertAgrees("[-W-,,-]")
        // Comma-joined flags are a single match.
        assertAgrees("[-Wa,b] [-Wc]")
        // Unterminated: no match, and scanning must resume without losing the later flag.
        assertAgrees("[-Wab [-Wcd]")
        assertAgrees("[-Wab")
        // Lowercase "w" is not the marker.
        assertAgrees("[-wunused]")
        // Truncated markers at the very end must not read past the buffer.
        assertAgrees("[")
        assertAgrees("[-")
        assertAgrees("[-W")
        assertAgrees("x[-W")
    }

    /// `\w` is Unicode-aware, so these are real matches for the regex and the scanner has to defer to
    /// it rather than treat the non-ASCII byte as a terminator.
    func testAgreesOnNonAsciiFlags() {
        assertAgrees("[-Wдлина]")
        assertAgrees("[-Wé]")
        assertAgrees("[-Wunused-variable] и [-Wдлина]")
        // Non-word non-ASCII: not part of the body, so the flag ends before it and there is no "]".
        assertAgrees("[-Wab→cd]")
        // Non-ASCII outside any candidate still has to agree.
        assertAgrees("ошибка: [-Wunused-variable]")
    }

    /// Section text can contain NUL bytes, and the regex looks straight past them.
    func testAgreesAcrossEmbeddedNulBytes() {
        assertAgrees("a\u{0}b [-Wunused-variable]")
        assertAgrees("[-Wone]\u{0}[-Wtwo]")
    }

    /// Random structured text, to catch edge cases not reasoned about above.
    ///
    /// This calls the scanner directly rather than going through `parseFromLogSection`, so it can run
    /// enough cases to be worth something and can check the `nil` (defer-to-regex) result too.
    func testScannerAgreesOnGeneratedText() {
        let pieces = ["[", "]", "-", "W", "w", ",", "_", "a", "9", " ", "é", "\u{0301}", "\u{0}", "→",
                      "д", "🙂", "[-W", "]]"]
        var state: UInt64 = 0xDEAD_BEEF_CAFE
        func next(_ bound: Int) -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state % UInt64(bound))
        }
        var deferred = 0
        for _ in 0..<200_000 {
            let text = (0..<next(18)).map { _ in pieces[next(pieces.count)] }.joined()
            let expected = referenceFlags(text)
            guard let actual = Notice.asciiClangWarningFlags(text: text) else {
                deferred += 1
                continue
            }
            XCTAssertEqual(actual, expected, "disagreed on \(text.debugDescription)")
        }
        // The non-ASCII inputs above must actually reach the fallback, or this proves nothing about it.
        XCTAssertGreaterThan(deferred, 0)
    }

    /// The same sweep through the real parser, at a size that keeps the test fast.
    func testAgreesOnGeneratedText() {
        let pieces = ["[", "]", "-", "W", "w", ",", "_", "a", "9", " ", "é", "\u{0301}", "\u{0}", "→"]
        // A small xorshift, so the cases are fixed rather than flaky.
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next(_ bound: Int) -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state % UInt64(bound))
        }
        for _ in 0..<3_000 {
            let text = (0..<next(14)).map { _ in pieces[next(pieces.count)] }.joined()
            assertAgrees(text)
        }
    }
}
