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
@testable import XCLogParserLogGen

class SLFWriterTests: XCTestCase {

    private func tokens(_ writer: SLFWriter) throws -> [Token] {
        let document = writer.document()
        let contents = try XCTUnwrap(String(bytes: document, encoding: .utf8))
        return try Lexer(filePath: "generated.xcactivitylog")
            .tokenize(contents: contents,
                      redacted: false,
                      withoutBuildSpecificInformation: false)
    }

    /// Round-trips every token type through the real lexer, so the writer is checked against the
    /// reader rather than against my reading of the format.
    func testScalarsRoundTrip() throws {
        var writer = SLFWriter()
        writer.int(42)
        writer.string("hello")
        writer.double(1.5)
        writer.list(3)
        writer.null()
        writer.json("{\"a\":1}")

        let parsed = try tokens(writer)
        // The leading int is the log version from the header.
        XCTAssertEqual(parsed.count, 7)
        guard case .int(let version) = parsed[0] else { return XCTFail("expected version int") }
        XCTAssertEqual(version, 10)
        guard case .int(let value) = parsed[1] else { return XCTFail("expected int") }
        XCTAssertEqual(value, 42)
        guard case .string(let text) = parsed[2] else { return XCTFail("expected string") }
        XCTAssertEqual(text, "hello")
        guard case .double(let number) = parsed[3] else { return XCTFail("expected double") }
        XCTAssertEqual(number, 1.5)
        guard case .list(let count) = parsed[4] else { return XCTFail("expected list") }
        XCTAssertEqual(count, 3)
        guard case .null = parsed[5] else { return XCTFail("expected null") }
        guard case .json(let json) = parsed[6] else { return XCTFail("expected json") }
        XCTAssertEqual(json, "{\"a\":1}")
    }

    /// Doubles are emitted as a byte-swapped bit pattern, and `String(_:radix:)` drops leading
    /// zeros. Without zero padding, 1.0 renders as "f03f" and the lexer swaps those four digits into
    /// an unrelated number - a corruption nothing rejects, because the result is still a valid double.
    func testDoublesAreZeroPadded() throws {
        for value in [0.0, 1.0, 2.0, 1e-9, 1234.5678, -1.0] {
            var writer = SLFWriter()
            writer.double(value)
            let parsed = try tokens(writer)
            guard case .double(let round) = parsed[1] else {
                return XCTFail("expected double for \(value)")
            }
            XCTAssertEqual(round, value, "round trip failed for \(value)")
        }
    }

    /// A `className` declaration must be immediately followed by a reference to itself; the
    /// declaration alone does not count as a reference. `getClassRefToken` enforces this, and getting
    /// it wrong fails at the *following* token, which is why it reads as an unrelated error.
    func testFirstClassRefDeclaresAndReferences() throws {
        var writer = SLFWriter()
        writer.classRef("IDEActivityLogSection")

        let parsed = try tokens(writer)
        XCTAssertEqual(parsed.count, 3)
        guard case .className(let declared) = parsed[1] else { return XCTFail("expected className") }
        XCTAssertEqual(declared, "IDEActivityLogSection")
        guard case .classNameRef(let referenced) = parsed[2] else {
            return XCTFail("expected classNameRef")
        }
        XCTAssertEqual(referenced, "IDEActivityLogSection")
    }

    /// A repeat use emits only the reference, and it has to resolve to the same name. The table is
    /// append-ordered and shared across the whole document, so an index computed by hand is only
    /// correct relative to every declaration before it.
    func testRepeatClassRefEmitsOnlyAReference() throws {
        var writer = SLFWriter()
        writer.classRef("First")
        writer.classRef("Second")
        writer.classRef("First")

        let parsed = try tokens(writer)
        // version, First decl, First ref, Second decl, Second ref, First ref
        XCTAssertEqual(parsed.count, 6)
        guard case .classNameRef(let last) = parsed[5] else { return XCTFail("expected ref") }
        XCTAssertEqual(last, "First")
    }

    /// Lengths are byte counts, not character counts, so anything outside ASCII has to be measured
    /// in UTF-8 or the lexer reads a truncated string and then misreads the next token.
    func testMultiByteStringsUseByteLengths() throws {
        var writer = SLFWriter()
        writer.string("→ проект ✅")
        writer.int(7)

        let parsed = try tokens(writer)
        guard case .string(let text) = parsed[1] else { return XCTFail("expected string") }
        XCTAssertEqual(text, "→ проект ✅")
        // The following token has to still line up; a wrong length shifts everything after it.
        guard case .int(let value) = parsed[2] else { return XCTFail("expected int") }
        XCTAssertEqual(value, 7)
    }

    func testEmptyStringRoundTrips() throws {
        var writer = SLFWriter()
        writer.string("")
        writer.int(1)

        let parsed = try tokens(writer)
        guard case .string(let text) = parsed[1] else { return XCTFail("expected string") }
        XCTAssertEqual(text, "")
        guard case .int(let value) = parsed[2] else { return XCTFail("expected int") }
        XCTAssertEqual(value, 1)
    }
}
