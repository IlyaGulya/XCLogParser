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

class StringTrimExtensionTests: XCTestCase {

    /// The whole safety argument for the fast path is "it returns exactly what Foundation would".
    /// A spot-check cannot establish that, so this drives every ASCII byte and every non-ASCII
    /// member of the set through both paths and demands equality.
    func testMatchesFoundationForEveryAsciiBoundary() {
        let cores = ["", "a", "path/to/file.swift", "a b", "  inner  spaces  "]
        for byte in UInt8(0)...UInt8(127) {
            let scalar = String(UnicodeScalar(byte))
            for core in cores {
                for candidate in [scalar + core, core + scalar, scalar + core + scalar] {
                    XCTAssertEqual(candidate.trimmedIfNeeded(),
                                   candidate.trimmingCharacters(in: .whitespacesAndNewlines),
                                   "mismatch for byte 0x\(String(byte, radix: 16)) around \"\(core)\"")
                }
            }
        }
    }

    /// The non-ASCII whitespace members are the ones a byte test could plausibly get wrong: they
    /// must fall through to Foundation and still be trimmed.
    func testMatchesFoundationForNonAsciiWhitespace() {
        let set = CharacterSet.whitespacesAndNewlines
        var members: [String] = []
        for value in 0x80...0x3000 {
            guard let scalar = Unicode.Scalar(UInt32(value)), set.contains(scalar) else { continue }
            members.append(String(scalar))
        }
        XCTAssertFalse(members.isEmpty, "expected non-ASCII members in .whitespacesAndNewlines")
        for member in members {
            for candidate in [member + "x", "x" + member, member + "x" + member] {
                XCTAssertEqual(candidate.trimmedIfNeeded(),
                               candidate.trimmingCharacters(in: .whitespacesAndNewlines),
                               "mismatch around U+\(String(member.unicodeScalars.first!.value, radix: 16))")
            }
        }
    }

    /// Non-whitespace non-ASCII must not be mistaken for something to trim.
    func testDoesNotTrimNonWhitespaceNonAscii() {
        for candidate in ["héllo", "日本語", "→arrow", "emoji🙂"] {
            XCTAssertEqual(candidate.trimmedIfNeeded(), candidate)
            XCTAssertEqual(candidate.trimmedIfNeeded(),
                           candidate.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The byte-level trim slices UTF-8 directly, so a multi-byte scalar in the *interior* is what
    /// would break if the cut were made at the wrong offset. Both ends are ASCII whitespace here,
    /// which is exactly the case that now avoids Foundation.
    func testTrimsAsciiEdgesAroundNonAsciiInterior() {
        let interiors = ["héllo wörld", "日本語のテキスト", "a→b", "🙂 emoji 🙂", "\u{00A0}nbsp inside"]
        for interior in interiors {
            for candidate in [" \(interior) ", "\t\(interior)\n", "\r\n  \(interior)  \t"] {
                XCTAssertEqual(candidate.trimmedIfNeeded(),
                               candidate.trimmingCharacters(in: .whitespacesAndNewlines),
                               "mismatch for interior \"\(interior)\"")
            }
        }
    }

    /// Multi-byte scalars adjacent to the trimmed run: the first kept byte is a UTF-8 lead byte and
    /// the last kept byte is a continuation byte, so an off-by-one would produce replacement
    /// characters rather than a wrong-length string, and equality with Foundation catches it.
    func testTrimsRightUpToAMultiByteScalar() {
        for candidate in ["  日本  ", "\t🙂\t", " é ", "\n\u{00A0}x\u{00A0}\n"] {
            XCTAssertEqual(candidate.trimmedIfNeeded(),
                           candidate.trimmingCharacters(in: .whitespacesAndNewlines),
                           "mismatch for \"\(candidate.debugDescription)\"")
        }
    }

    /// A string that is nothing but whitespace trims to empty - the case where first and last are
    /// the same byte and both are trimmable.
    func testWhitespaceOnlyStringsBecomeEmpty() {
        for candidate in ["", " ", "\n", "\t\r\n ", "\u{00A0}\u{2028}"] {
            XCTAssertEqual(candidate.trimmedIfNeeded(),
                           candidate.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

}
