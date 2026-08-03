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

/// Differential tests for the byte-level number parsing that replaced `UInt64(_:radix:)` in the lexer.
///
/// The lexer used to build a `String` from the scanned payload and hand it to a Swift initializer. These
/// check that parsing straight from the bytes accepts and rejects exactly the same inputs.
class ScannerNumberTests: XCTestCase {

    private func parse(_ text: String, radix: UInt64) -> UInt64? {
        return XCLogParser.Scanner.withScanner(string: text) {
            $0.unsignedInteger(in: 0..<text.utf8.count, radix: radix)
        }
    }

    private func assertAgrees(_ text: String, radix: Int,
                              file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(parse(text, radix: UInt64(radix)), UInt64(text, radix: radix),
                       "disagreed on \(text.debugDescription) radix \(radix)",
                       file: file, line: line)
    }

    func testAgreesOnDecimalDigits() {
        for text in ["0", "1", "9", "10", "0123", "999999", "4294967295",
                     "18446744073709551615"] {
            assertAgrees(text, radix: 10)
        }
    }

    func testAgreesOnHexDigits() {
        for text in ["0", "a", "f", "A", "F", "ff", "FF", "aBcDeF", "356098f239dfc041",
                     "ffffffffffffffff", "0000000000000001"] {
            assertAgrees(text, radix: 16)
        }
    }

    /// `UInt64(_:)` returns nil rather than trapping on overflow, and so must this.
    func testAgreesOnOverflow() {
        for text in ["18446744073709551616", "99999999999999999999999999",
                     "10000000000000000000000000000000"] {
            assertAgrees(text, radix: 10)
        }
        for text in ["10000000000000000", "fffffffffffffffff"] {
            assertAgrees(text, radix: 16)
        }
    }

    /// Anything that is not a digit in the given radix must be rejected, exactly as before.
    func testAgreesOnRejectedInput() {
        for text in ["", " ", "1 ", " 1", "1a", "a", "g", "1.0", "1_000",
                     "０", "1\u{0}", "\u{0}1", "①", "٣"] {
            assertAgrees(text, radix: 10)
        }
        // A leading "+" is *accepted* by `UInt64(_:)`, which is easy to assume otherwise - this
        // assertion started out in the reject list above and the generated sweep disproved it.
        for text in ["+1", "+0", "+", "++1", "+f", "-0", "-00", "-1", "-f"] {
            assertAgrees(text, radix: 10)
            assertAgrees(text, radix: 16)
        }
        for text in ["", "g", "0x1f", "-a", "f f"] {
            assertAgrees(text, radix: 16)
        }
    }

    /// Generated digit strings, including boundary-length runs where overflow starts.
    func testAgreesOnGeneratedNumbers() {
        let alphabet = Array("0123456789abcdefABCDEFxg -+_.\u{0}")
        var state: UInt64 = 0xABCD_EF01_2345
        func next(_ bound: Int) -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state % UInt64(bound))
        }
        for _ in 0..<50_000 {
            let text = String((0..<next(24)).map { _ in alphabet[next(alphabet.count)] })
            assertAgrees(text, radix: 10)
            assertAgrees(text, radix: 16)
        }
    }

    /// The empty range is how a value with no payload shows up, and it must not parse as zero.
    func testEmptyRangeIsRejected() {
        XCLogParser.Scanner.withScanner(string: "123") {
            XCTAssertNil($0.unsignedInteger(in: 0..<0))
        }
    }
}

/// Tests for the bitmap that replaced `Set<UInt8>` in the scanning loops.
class ByteSetTests: XCTestCase {

    func testMatchesSetMembershipAcrossAllBytes() {
        let members: [UInt8] = [0, 1, 63, 64, 65, 127, 128, 129, 191, 192, 193, 254, 255,
                                UInt8(ascii: "a"), UInt8(ascii: "0")]
        let reference = Set(members)
        let byteSet = ByteSet(members)
        // Every one of the 256 possible values, so no word boundary goes unchecked.
        for value in UInt8.min...UInt8.max {
            XCTAssertEqual(byteSet.contains(value), reference.contains(value),
                           "disagreed on byte \(value)")
        }
    }

    func testEmptySetContainsNothing() {
        let byteSet = ByteSet([])
        for value in UInt8.min...UInt8.max {
            XCTAssertFalse(byteSet.contains(value))
        }
    }

    func testFullSetContainsEverything() {
        let byteSet = ByteSet(UInt8.min...UInt8.max)
        for value in UInt8.min...UInt8.max {
            XCTAssertTrue(byteSet.contains(value))
        }
    }
}
