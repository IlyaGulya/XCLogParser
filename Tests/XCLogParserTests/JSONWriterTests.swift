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

/// `JSONWriter` replaces `JSONEncoder` for the build-step report, so the interesting assertions are
/// all "does this still agree with Foundation". Key *order* deliberately differs (declaration order
/// instead of Foundation's unstable hash order) and empty arrays are `[]`, so comparison is on
/// parsed structure rather than bytes, except where the format itself is under test.
class JSONWriterTests: XCTestCase {

    // MARK: - Scalar parity with JSONEncoder

    /// Foundation prints a `Double` shortest-round-trip and drops a trailing `.0`, so it writes `3`
    /// where Swift's `description` writes `3.0`. Integral durations are common in real logs (every
    /// non-compilation step has `compilationDuration` 0), so this is not an edge case for us.
    func testDoubleFormattingMatchesJSONEncoder() throws {
        let encoder = JSONEncoder()
        var values: [Double] = [0, -0.0, 1, 3, 896.5835649967194, 0.1, 1e-7, 1.5e20, 1e21,
                                5e-324, 1234567890.123456, .leastNonzeroMagnitude, .greatestFiniteMagnitude]
        // A deterministic xorshift sweep, so a failure is reproducible rather than flaky.
        var state = UInt64(12345)
        for _ in 0..<20000 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            values.append(Double(bitPattern: state))
        }
        for value in values where value.isFinite {
            var writer = JSONWriter()
            writer.value(value)
            let mine = String(bytes: writer.bytes, encoding: .utf8)
            let foundation = String(bytes: try encoder.encode([value]), encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            XCTAssertEqual(mine, foundation, "disagreed on \(value.bitPattern)")
        }
    }

    /// Non-finite values cannot arise from this model and `JSONEncoder` throws on them; the writer
    /// emits `null` rather than the invalid JSON `inf`, so a hypothetical one cannot corrupt a report.
    func testNonFiniteDoublesBecomeNull() {
        for value in [Double.infinity, -.infinity, .nan] {
            var writer = JSONWriter()
            writer.value(value)
            XCTAssertEqual(String(bytes: writer.bytes, encoding: .utf8), "null")
        }
    }

    /// The escape set was read off `JSONEncoder`, including the two surprises: `/` becomes `\/`
    /// (optional per RFC 8259, and a build log is almost all paths) and `\u00xx` hex is lowercase.
    func testStringEscapingMatchesJSONEncoder() throws {
        let encoder = JSONEncoder()
        var cases: [String] = ["", "plain", "/usr/bin/swift", "a\"b", "a\\b", "tab\there",
                               "nl\nhere", "cr\rhere", "\u{08}\u{0C}", "\u{0B}\u{1F}\u{00}",
                               "é", "日本語", "\u{7F}", "\u{2028}\u{2029}", "emoji 🚀 ok",
                               "-Wshorten-64-to-32", "/path/with \"quotes\"/and\\slash"]
        for scalar in 0...0x7F {
            cases.append("x\(String(UnicodeScalar(UInt8(scalar))))y")
        }
        for text in cases {
            var writer = JSONWriter()
            writer.value(text)
            let mine = String(bytes: writer.bytes, encoding: .utf8)
            let foundation = String(bytes: try encoder.encode([text]), encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            XCTAssertEqual(mine, foundation, "disagreed on \(text.debugDescription)")
        }
    }

    func testIntegerFormatting() {
        for value in [0, 1, 9, 10, -1, -9, -10, 12345, -12345, Int.max, Int.min] {
            var writer = JSONWriter()
            writer.value(value)
            XCTAssertEqual(String(bytes: writer.bytes, encoding: .utf8), "\(value)")
        }
        for value in [UInt64.min, 1, 9, 10, UInt64.max] {
            var writer = JSONWriter()
            writer.value(value)
            XCTAssertEqual(String(bytes: writer.bytes, encoding: .utf8), "\(value)")
        }
    }

    // MARK: - Format

    /// Pins the pretty-printed shape: two-space indent, `" : "` separator, and `[]` for an empty
    /// array rather than Foundation's `[\n\n  ]` artifact.
    func testPrettyPrintedShape() {
        var writer = JSONWriter()
        writer.beginObject()
        writer.field("a", 1)
        writer.key("empty")
        writer.beginArray()
        writer.endArray()
        writer.key("list")
        writer.beginArray()
        writer.value("x")
        writer.beginObject()
        writer.field("nested", true)
        writer.endObject()
        writer.endArray()
        writer.field("last", "z" as String?)
        writer.field("gone", nil as String?)
        writer.key("explicit")
        writer.null()
        writer.endObject()
        XCTAssertEqual(String(bytes: writer.bytes, encoding: .utf8), """
        {
          "a" : 1,
          "empty" : [],
          "list" : [
            "x",
            {
              "nested" : true
            }
          ],
          "last" : "z",
          "explicit" : null
        }
        """)
    }

    // MARK: - Model parity

    /// The critical regression guard. The hand-written `write(to:)` methods have no compiler check
    /// tying them to their type's stored properties, so a newly added field would silently vanish
    /// from the report. This diffs the emitted key set against `JSONEncoder`'s, recursively, which
    /// fails the moment the two drift apart.
    func testBuildStepWritesTheSameFieldsAsJSONEncoder() throws {
        let step = Self.populatedStep()
        var writer = JSONWriter()
        step.write(to: &writer)

        let encoder = JSONEncoder()
        let viaEncodable = try JSONSerialization.jsonObject(with: try encoder.encode(step))
        let viaWriter = try JSONSerialization.jsonObject(with: Data(writer.bytes))

        XCTAssertEqual(Self.keyPaths(of: viaWriter), Self.keyPaths(of: viaEncodable),
                       "hand-written JSON drifted from the Encodable conformance")
    }

    /// Field *values* must match too, not just the key set - `JSONSerialization` normalizes both
    /// sides to the same Foundation objects, so this compares them directly.
    func testBuildStepValuesMatchJSONEncoder() throws {
        let step = Self.populatedStep()
        var writer = JSONWriter()
        step.write(to: &writer)

        let encoder = JSONEncoder()
        let viaEncodable = try JSONSerialization.jsonObject(with: try encoder.encode(step))
        let viaWriter = try JSONSerialization.jsonObject(with: Data(writer.bytes))
        XCTAssertEqual(viaWriter as? NSDictionary, viaEncodable as? NSDictionary)
    }

    /// Key order is now declaration order rather than Foundation's hash order, which is what makes
    /// the report byte-reproducible for the first time. Two writes of the same tree must be equal.
    func testOutputIsDeterministic() {
        let step = Self.populatedStep()
        var first = JSONWriter()
        step.write(to: &first)
        var second = JSONWriter()
        step.write(to: &second)
        XCTAssertEqual(first.bytes, second.bytes)
    }

    /// A `nil` optional must produce **no key**, not a `null`.
    ///
    /// The synthesized `encode(to:)` uses `encodeIfPresent`, so today's reports simply lack a
    /// `warnings` key on a step with no warnings. Writing `null` instead would add a key to almost
    /// every step - a schema change. This test exists because the first version of the writer got
    /// this wrong and the field-set parity test below caught it.
    func testNilOptionalsOmitTheKeyEntirely() throws {
        let step = Self.step(warnings: nil, errors: nil, notes: nil)
        var writer = JSONWriter()
        step.write(to: &writer)
        let object = try JSONSerialization.jsonObject(with: Data(writer.bytes)) as? [String: Any]
        for field in ["warnings", "errors", "notes", "swiftFunctionTimes",
                      "swiftTypeCheckTimes", "linkerStatistics", "clangTimeTraceFile"] {
            XCTAssertNil(object?[field], "\(field) should be absent, not null")
        }
    }

    /// An *empty* array is still an empty array - only `nil` disappears.
    func testEmptyArraysAreWrittenAsEmpty() throws {
        let step = Self.step(warnings: [], errors: [], notes: [])
        var writer = JSONWriter()
        step.write(to: &writer)
        let object = try JSONSerialization.jsonObject(with: Data(writer.bytes)) as? [String: Any]
        for field in ["warnings", "errors", "notes"] {
            XCTAssertEqual((object?[field] as? [Any])?.count, 0, "\(field) should be []")
        }
    }

    func testNestedSubStepsAreWrittenDepthFirst() throws {
        let leaf = Self.step(identifier: "leaf")
        let middle = Self.step(identifier: "middle", subSteps: [leaf])
        let root = Self.step(identifier: "root", subSteps: [middle])
        var writer = JSONWriter()
        root.write(to: &writer)
        let object = try JSONSerialization.jsonObject(with: Data(writer.bytes)) as? [String: Any]
        let middleJSON = (object?["subSteps"] as? [[String: Any]])?.first
        let leafJSON = (middleJSON?["subSteps"] as? [[String: Any]])?.first
        XCTAssertEqual(object?["identifier"] as? String, "root")
        XCTAssertEqual(middleJSON?["identifier"] as? String, "middle")
        XCTAssertEqual(leafJSON?["identifier"] as? String, "leaf")
    }

    // MARK: - Fixtures

    /// Recursively collects `a.b[].c`-style key paths, so a missing or extra field anywhere in the
    /// tree shows up as a set difference.
    /// Not `private`: `JSONWriterParityTests` compares key sets with the same helper, so the two
    /// classes cannot disagree about what counts as a key path.
    static func keyPaths(of value: Any, prefix: String = "") -> Set<String> {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.reduce(into: Set<String>()) { paths, entry in
                let path = prefix.isEmpty ? entry.key : "\(prefix).\(entry.key)"
                paths.insert(path)
                paths.formUnion(keyPaths(of: entry.value, prefix: path))
            }
        case let array as [Any]:
            return array.reduce(into: Set<String>()) { paths, element in
                paths.formUnion(keyPaths(of: element, prefix: "\(prefix)[]"))
            }
        default:
            return []
        }
    }

    /// A step with every optional populated, so the parity tests actually exercise every branch.
    static func populatedStep() -> BuildStep {
        let notice = Notice(type: .clangWarning,
                            title: "warning: unused variable 'x' [-Wunused-variable]",
                            clangFlag: "-Wunused-variable",
                            documentURL: "file:///src/a b/main.m",
                            severity: 1,
                            startingLineNumber: 10,
                            endingLineNumber: 10,
                            startingColumnNumber: 4,
                            endingColumnNumber: 8,
                            characterRangeEnd: 120,
                            characterRangeStart: 100,
                            interfaceBuilderIdentifier: "ib-id",
                            detail: "main.m:10:4: warning: \"quoted\"\n  int x;\n")
        let plainNotice = Notice(type: .note, title: "note", clangFlag: nil,
                                 documentURL: "", severity: 0,
                                 startingLineNumber: 0, endingLineNumber: 0,
                                 startingColumnNumber: 0, endingColumnNumber: UInt64.max,
                                 characterRangeEnd: 0, characterRangeStart: 0)
        let linker = LinkerStatistics(totalMS: 1.5, optionParsingMS: 0, optionParsingPercent: 0.25,
                                      objectFileProcessingMS: 2, objectFileProcessingPercent: 3,
                                      resolveSymbolsMS: 4, resolveSymbolsPercent: 5,
                                      buildAtomListMS: 6, buildAtomListPercent: 7,
                                      runPassesMS: 8, runPassesPercent: 9,
                                      writeOutputMS: 10, writeOutputPercent: 11,
                                      pageins: 12, pageouts: 13, faults: 14,
                                      objectFiles: 15, objectFilesBytes: 16,
                                      archiveFiles: 17, archiveFilesBytes: 18,
                                      dylibFiles: 19, wroteOutputFileBytes: 20)
        return step(identifier: "root",
                    subSteps: [step(identifier: "child")],
                    warnings: [notice, plainNotice],
                    errors: [plainNotice],
                    notes: [],
                    swiftFunctionTimes: [SwiftFunctionTime(file: "file:///a.swift", durationMS: 1.25,
                                                           startingLine: 3, startingColumn: 4,
                                                           signature: "foo()", occurrences: 2)],
                    swiftTypeCheckTimes: [SwiftTypeCheck(file: "file:///b.swift", durationMS: 0,
                                                         startingLine: 1, startingColumn: 2,
                                                         occurrences: 1)],
                    clangTimeTraceFile: "/tmp/trace.json",
                    linkerStatistics: linker)
    }

    private static func step(identifier: String = "id",
                             subSteps: [BuildStep] = [],
                             warnings: [Notice]? = nil,
                             errors: [Notice]? = nil,
                             notes: [Notice]? = nil,
                             swiftFunctionTimes: [SwiftFunctionTime]? = nil,
                             swiftTypeCheckTimes: [SwiftTypeCheck]? = nil,
                             clangTimeTraceFile: String? = nil,
                             linkerStatistics: LinkerStatistics? = nil) -> BuildStep {
        return BuildStep(type: .detail,
                         machineName: "machine",
                         buildIdentifier: "build-id",
                         identifier: identifier,
                         parentIdentifier: "parent",
                         domain: "com.apple.dt.IDE.BuildLogSection",
                         title: "Compile /src/a b/main.m",
                         signature: "CompileC /src/a b/main.m normal arm64",
                         startDate: "2026-08-04T10:00:00.000Z",
                         endDate: "2026-08-04T10:00:01.000Z",
                         startTimestamp: 1785_000_000.5,
                         endTimestamp: 1785_000_001,
                         duration: 0.5,
                         detailStepType: .cCompilation,
                         buildStatus: "succeeded",
                         schema: "MyApp",
                         subSteps: subSteps,
                         warningCount: warnings?.count ?? 0,
                         errorCount: errors?.count ?? 0,
                         architecture: "arm64",
                         documentURL: "file:///src/a b/main.m",
                         warnings: warnings,
                         errors: errors,
                         notes: notes,
                         swiftFunctionTimes: swiftFunctionTimes,
                         fetchedFromCache: false,
                         compilationEndTimestamp: 1785_000_001,
                         compilationDuration: 0,
                         clangTimeTraceFile: clangTimeTraceFile,
                         linkerStatistics: linkerStatistics,
                         swiftTypeCheckTimes: swiftTypeCheckTimes)
    }
}
