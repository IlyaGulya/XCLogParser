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

/// Parity between each hand-written `write(to:)` and its `Encodable` conformance.
///
/// Split from `JSONWriterTests`, which covers the writer's own formatting, because this is a
/// different question: not "does the writer emit valid JSON" but "does each type still emit all of
/// itself". It shares that class's fixture so the two cannot disagree about what a step looks like.
class JSONWriterParityTests: XCTestCase {

    /// The parity check for every *other* hand-written writer, each encoded on its own.
    ///
    /// `testBuildStepWritesTheSameFieldsAsJSONEncoder` reaches these types only through a step, so a
    /// field dropped from one of them shows up there as a missing nested key - but only while the
    /// fixture keeps populating it. Encoding each type directly ties the check to the type instead of
    /// to `populatedStep`'s contents, which is what stops the five smaller writers drifting silently.
    func testEveryWriterMatchesJSONEncoder() throws {
        func check<T: Encodable>(_ value: T,
                                 _ write: (T, inout JSONWriter) -> Void,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) throws {
            var writer = JSONWriter()
            write(value, &writer)
            let viaWriter = try JSONSerialization.jsonObject(with: Data(writer.bytes))
            let viaEncodable = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(value))
            XCTAssertEqual(JSONWriterTests.keyPaths(of: viaWriter), JSONWriterTests.keyPaths(of: viaEncodable),
                           "\(T.self): hand-written JSON drifted from the Encodable conformance",
                           file: file, line: line)
            XCTAssertEqual(viaWriter as? NSDictionary, viaEncodable as? NSDictionary,
                           "\(T.self): values differ", file: file, line: line)
        }

        let step = JSONWriterTests.populatedStep()
        // Both shapes of Notice: every optional populated, and every optional nil.
        for notice in (step.warnings ?? []) {
            try check(notice) { $0.write(to: &$1) }
        }
        for functionTime in (step.swiftFunctionTimes ?? []) {
            try check(functionTime) { $0.write(to: &$1) }
        }
        for typeCheck in (step.swiftTypeCheckTimes ?? []) {
            try check(typeCheck) { $0.write(to: &$1) }
        }
        if let linker = step.linkerStatistics {
            try check(linker) { $0.write(to: &$1) }
        }
        if let taskMetrics = step.taskMetrics {
            try check(taskMetrics) { $0.write(to: &$1) }
        }
    }
}
