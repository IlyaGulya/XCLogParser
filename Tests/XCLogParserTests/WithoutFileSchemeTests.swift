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

/// `withoutFileScheme` replaces a Foundation `replacingOccurrences(of: "file://", with: "")` with a
/// prefix drop on the common path. The whole-log diff cannot establish that it is equivalent: both
/// benchmark logs only ever contain a single leading `file://`, so they exercise one branch of three.
/// These are differential tests against the call it replaced.
class WithoutFileSchemeTests: XCTestCase {

    private func assertMatchesFoundation(_ input: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(input.withoutFileScheme,
                       input.replacingOccurrences(of: "file://", with: ""),
                       "disagreed on \(String(reflecting: input))",
                       file: file, line: line)
    }

    func testLeadingSchemeIsStripped() {
        assertMatchesFoundation("file:///Users/x/A.swift")
        XCTAssertEqual("file:///Users/x/A.swift".withoutFileScheme, "/Users/x/A.swift")
    }

    func testNoSchemeIsUnchanged() {
        assertMatchesFoundation("/Users/x/A.swift")
        assertMatchesFoundation("")
        assertMatchesFoundation("https://example.com/a")
    }

    /// The case the fast path must not swallow: the original removed *every* occurrence, so a marker
    /// away from the front is still removed.
    func testInteriorSchemeIsAlsoRemoved() {
        assertMatchesFoundation("/tmp/file://A.swift")
        assertMatchesFoundation("file:///a/file://b")
        assertMatchesFoundation("file://file://a")
        assertMatchesFoundation("file://file://file://")
    }

    func testPartialAndAdjacentMarkers() {
        assertMatchesFoundation("file:/")
        assertMatchesFoundation("file:/-/a")
        assertMatchesFoundation("FILE://a")
        assertMatchesFoundation("file://")
    }

    /// `String` comparison works on grapheme clusters, so a combining mark fused to the marker's last
    /// character can make Foundation report no match. Whatever it decides, this must agree.
    func testCombiningMarksAgreeWithFoundation() {
        for scalar in 0x0300...0x036F {
            guard let mark = Unicode.Scalar(scalar) else { continue }
            assertMatchesFoundation("file://\(Character(mark))a")
            assertMatchesFoundation("/a/file://\(Character(mark))")
        }
    }

    /// A generated sweep over strings assembled from fragments that can form, break and repeat the
    /// marker, which is where an off-by-one in the prefix drop would show up.
    func testDifferentialSweep() {
        let fragments = ["file", ":", "/", "//", "file://", "a", "", "F", "ile://", "://"]
        var state: UInt64 = 0x9E3779B97F4A7C15
        for _ in 0..<20_000 {
            var input = ""
            let parts = 1 + Int(state % 5)
            for _ in 0..<parts {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                input += fragments[Int(state % UInt64(fragments.count))]
            }
            assertMatchesFoundation(input)
        }
    }
}
