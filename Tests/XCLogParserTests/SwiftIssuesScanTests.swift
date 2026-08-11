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

/// Differential tests for `parseSwiftIssuesDetailsByLocation`, whose marker search is a hand-written
/// byte scan standing in for `range(of: ": error:") ?? range(of: ": warning:")`.
class SwiftIssuesScanTests: XCTestCase {

    /// The original Foundation implementation, kept as the differential reference.
    ///
    /// This is the shape the byte scanner replaced: split on "\r", find the error marker or else the
    /// warning marker, key the entry on everything up to and including the byte before the marker.
    private func reference(_ text: String) -> [String: String] {
        var detailsByLocation = [String: String]()
        var currentKey: String?
        var currentDetail = ""
        for line in text.split(separator: "\r") {
            let detail = String(line)
            if let range = detail.range(of: ": error:") ?? detail.range(of: ": warning:") {
                if let key = currentKey {
                    detailsByLocation[key] = currentDetail
                }
                currentKey = String(detail[detail.startIndex...range.lowerBound])
                currentDetail = detail
            } else if currentKey != nil {
                currentDetail += "\n" + detail
            }
        }
        if let key = currentKey {
            detailsByLocation[key] = currentDetail
        }
        return detailsByLocation
    }

    private func assertAgrees(_ text: String, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(Notice.parseSwiftIssuesDetailsByLocation(text), reference(text),
                       "disagreed on \(text.debugDescription)", file: file, line: line)
    }

    func testAgreesOnRealisticInput() {
        assertAgrees("/a/b.swift:3:1: error: cannot find 'x' in scope\rlet y = x\r        ^")
        assertAgrees("/a/b.swift:3:1: warning: unused result\rfoo()\r^")
        assertAgrees("""
        /a/b.swift:1:1: error: first\rdetail one\r/a/c.swift:2:2: warning: second\rdetail two
        """.replacingOccurrences(of: "\n", with: "\r"))
        assertAgrees("no markers at all\rjust text")
        assertAgrees("")
    }

    /// Precedence is by *marker*, not by position: a later ": error:" beats an earlier ": warning:".
    func testErrorMarkerWinsRegardlessOfPosition() {
        assertAgrees("/a.swift:1:1: warning: w then: error: e")
        assertAgrees("/a.swift:1:1: error: e then: warning: w")
        assertAgrees("x: warning: a: error: b: warning: c")
    }

    /// Empty lines are dropped by `split`, so they never become continuations.
    func testEmptyLinesAndTerminators() {
        assertAgrees("/a.swift:1:1: error: e\r\r\rtrailing")
        assertAgrees("\r\r/a.swift:1:1: error: e\r")
        assertAgrees("\r")
        assertAgrees("/a.swift:1:1: error: e\r")
    }

    /// Continuation lines before any diagnostic have nowhere to attach and are discarded.
    func testLeadingContinuationsAreDropped() {
        assertAgrees("orphan line\ranother\r/a.swift:1:1: error: e\rdetail")
    }

    /// A combining scalar fused to the marker's trailing ":" defeats `String.contains`, so the byte
    /// scanner has to reject that match too.
    func testCombiningMarkAfterMarkerAgreesWithFoundation() {
        assertAgrees("/a.swift:1:1: error:\u{0301} fused")
        assertAgrees("/a.swift:1:1: warning:\u{0301} fused")
        // Non-combining non-ASCII starts a new cluster, so these really do match.
        assertAgrees("/a.swift:1:1: error:é not fused")
        assertAgrees("/a.swift:1:1: warning:日 not fused")
        // Every combining mark, against both markers.
        for scalarValue in 0x0300...0x036F {
            guard let scalar = Unicode.Scalar(scalarValue) else { continue }
            assertAgrees("/a.swift:1:1: error:\(scalar) x")
            assertAgrees("/a.swift:1:1: warning:\(scalar) x")
        }
    }

    /// Markers truncated at the very end of the buffer must not read past it.
    func testTruncatedMarkersAtEndOfInput() {
        for prefix in ["/a.swift:1:1", "x"] {
            for marker in [": error:", ": warning:"] {
                for length in 0...marker.count {
                    assertAgrees(prefix + String(marker.prefix(length)))
                }
            }
        }
    }

    /// Long runs of continuation lines, which is where the join is done in one pass over a byte
    /// buffer rather than by concatenating a `String` per line. The count is what that change is
    /// sensitive to, and the generated sweep below caps its input at 12 pieces, so the many-line case
    /// needs stating separately. Non-ASCII is included because the join copies bytes, not characters.
    func testAgreesOnLongContinuationRuns() {
        for count in [0, 1, 2, 3, 17, 64, 500] {
            let tail = (0..<count).map { "continuation \($0)" }.joined(separator: "\r")
            assertAgrees("/a.swift:1:1: error: e\r" + tail)
            assertAgrees("/a.swift:1:1: warning: w\r" + tail)
            // Two diagnostics, so the buffer is reused across flushes within one call.
            assertAgrees("/a.swift:1:1: error: e\r\(tail)\r/b.swift:2:2: error: e2\r\(tail)")
        }
        // Multi-byte scalars and NULs spread across the joined lines.
        for filler in ["日本語", "é", "🙂", "\u{0}", "a\u{0}b"] {
            let tail = (0..<12).map { _ in filler }.joined(separator: "\r")
            assertAgrees("/a.swift:1:1: error: e\r" + tail)
        }
    }

    /// Random structured text over the bytes that matter, to catch what was not reasoned about above.
    func testAgreesOnGeneratedText() {
        let pieces = [":", " ", "e", "error", "warning", "\r", "/a.swift", "1", "\u{0301}", "é",
                      ": error:", ": warning:", "\u{0}", "x"]
        var state: UInt64 = 0x5DEECE66D
        func next(_ bound: Int) -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state % UInt64(bound))
        }
        for _ in 0..<20_000 {
            let text = (0..<next(12)).map { _ in pieces[next(pieces.count)] }.joined()
            assertAgrees(text)
        }
    }
}
