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

/// Inputs a real Xcode never produces, but a truncated, corrupted or hand-edited log does.
///
/// Each test here fails by trapping rather than by returning a wrong value, so there is no
/// `XCTAssert` that can catch the regression: the process dies and the whole suite goes with it.
/// That is the point - these are the crashes, not the mismatches.
class MalformedInputTests: XCTestCase {

    // MARK: - getTargetFromCommand

    /// `getTargetFromCommand` searches for two markers independently and slices between them, so a
    /// `commandDetailDesc` where the closing marker appears *before* the opening one produces a
    /// reversed range. Slicing with it traps.
    ///
    /// Nothing about this string is realistic; it only has to contain both markers out of order,
    /// which corrupted text can.
    func testTargetFromCommandWithMarkersOutOfOrder() {
        let section = fakeSection(commandDetailDesc: "' from project 'in target 'App")

        XCTAssertNil(section.getTargetFromCommand())
    }

    /// The ordinary case still works - guarding the reversed range must not reject valid input.
    func testTargetFromCommandWithMarkersInOrder() {
        let section = fakeSection(commandDetailDesc: "CompileSwift (in target 'App' from project 'P')")

        XCTAssertEqual(section.getTargetFromCommand(), "App")
    }

    // MARK: - classNameRef bounds

    /// A `classNameRef` payload indexes the class names declared so far, one-based. A payload of `0`
    /// therefore asks for element -1, and any payload past the declarations asks past the end; both
    /// subscripted the array directly and killed the process with "Index out of range".
    ///
    /// This document declares no class names at all and then references one, which is the shortest
    /// way to reach that state. The reference is rejected as an unreadable payload, which reaches the
    /// caller as `invalidLine` - the same way every other malformed payload in that function is
    /// already reported.
    func testTokenizeClassNameRefOutOfBounds() {
        let lexer = Lexer(filePath: "dummy.xcactivitylog")

        XCTAssertThrowsError(try lexer.tokenize(contents: "SLF01@356098f239dfc041^",
                                                redacted: false,
                                                withoutBuildSpecificInformation: false)) { error in
            assertIsInvalidLine(error)
        }
    }

    /// Zero is the other end of the same defect: `value - 1` is -1 before the array is ever consulted.
    func testTokenizeClassNameRefZero() {
        let lexer = Lexer(filePath: "dummy.xcactivitylog")

        XCTAssertThrowsError(try lexer.tokenize(contents: "SLF010@",
                                                redacted: false,
                                                withoutBuildSpecificInformation: false)) { error in
            assertIsInvalidLine(error)
        }
    }

    // MARK: - NSRange width

    /// `NSRegularExpression` takes NSRange offsets in UTF-16 code units, but nine call sites built the
    /// range from `String.count`, which counts grapheme clusters. The two agree only for ASCII.
    ///
    /// Here the emoji is one cluster and two UTF-16 units, so a `count`-sized range stops one unit
    /// short of the end - and the marker this regex looks for sits in exactly that gap. The result is
    /// not a crash but a silent miss, which is why the assertion is on the returned value.
    func testTimeTraceFileFoundAfterNonASCIIText() {
        let parser = ClangCompilerParser()
        let padding = String(repeating: "🙂", count: 40)
        let text = "\(padding)\r" +
            "Time trace json-file dumped to /Users/project/Utility.json\r"
        let section = fakeSection(commandDetailDesc: "-ftime-trace", text: text)

        XCTAssertEqual(parser.parseTimeTraceFile(section), "/Users/project/Utility.json")
    }

    // MARK: - Helpers

    /// Asserts the specific error, not merely that something was thrown: the point of the fix is that
    /// a bad index is *reported* rather than fatal, so any other error would mean it failed elsewhere.
    private func assertIsInvalidLine(_ error: Error,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        guard case XCLogParserError.invalidLine = error else {
            XCTFail("expected invalidLine, got \(error)", file: file, line: line)
            return
        }
    }

    private func fakeSection(commandDetailDesc: String, text: String = "") -> IDEActivityLogSection {
        return IDEActivityLogSection(sectionType: 1,
                                     domainType: "",
                                     title: "Run Something",
                                     signature: "",
                                     timeStartedRecording: 0.0,
                                     timeStoppedRecording: 0.0,
                                     subSections: [],
                                     text: text,
                                     messages: [],
                                     wasCancelled: false,
                                     isQuiet: false,
                                     wasFetchedFromCache: false,
                                     subtitle: "",
                                     location: DVTDocumentLocation(documentURLString: "", timestamp: 0.0),
                                     commandDetailDesc: commandDetailDesc,
                                     uniqueIdentifier: "ABC",
                                     localizedResultString: "",
                                     xcbuildSignature: "",
                                     attachments: [],
                                     unknown: 0)
    }
}
