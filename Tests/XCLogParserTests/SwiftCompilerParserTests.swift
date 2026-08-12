// Copyright (c) 2019 Spotify AB.
//
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

class SwiftCompilerParserTests: XCTestCase {

    let parser = SwiftCompilerParser()

    func testParseSwiftFunctionTimes() throws {
        try runParseSwiftFunctionTimesTest(rawFile: "myapp/MyView", escapedFile: "myapp/MyView")
        try runParseSwiftFunctionTimesTest(rawFile: "my app/MyView", escapedFile: "my%20app/MyView")
    }

    private func runParseSwiftFunctionTimesTest(rawFile: String,
                                                escapedFile: String,
                                                file: StaticString = #file,
                                                line: UInt = #line) throws {
        let emptylogSection = getFakeSwiftcSection(text: "text",
                                              commandDescription: "command")
        let text =
        "0.05ms\t/Users/user/\(rawFile).swift:9:9\tgetter textLabel\r" +
        "4.96ms\t/Users/user/\(rawFile).swift:11:14\tinitializer init(frame:)\r" +
        "0.04ms\t<invalid loc>\tgetter None\r"
        let swiftTimesLogSection = getFakeSwiftcSection(text:
            text, commandDescription: "-debug-time-function-bodies")

        let duplicatedSwiftTimeslogSection = getFakeSwiftcSection(text:
            text, commandDescription: "-debug-time-function-bodies")
        let expectedFile = "file:///Users/user/\(escapedFile).swift"
        parser.addLogSection(emptylogSection)
        parser.addLogSection(swiftTimesLogSection)
        parser.addLogSection(duplicatedSwiftTimeslogSection)

        parser.parse()
        guard let functionTimes = parser.findFunctionTimesForFilePath(expectedFile) else {
            XCTFail("The command should have swiftc function times", file: file, line: line)
            return
        }
        XCTAssertEqual(2, functionTimes.count, file: file, line: line)
        let getter = functionTimes[0]
        let initializer = functionTimes[1]
        XCTAssertEqual(0.05, getter.durationMS, file: file, line: line)
        XCTAssertEqual(9, getter.startingLine, file: file, line: line)
        XCTAssertEqual(9, getter.startingColumn, file: file, line: line)
        XCTAssertEqual(2, getter.occurrences, file: file, line: line)
        XCTAssertEqual(expectedFile.removingPercentEncoding, getter.file, file: file, line: line)
        XCTAssertEqual("getter textLabel", getter.signature, file: file, line: line)
        XCTAssertEqual("initializer init(frame:)", initializer.signature, file: file, line: line)
        XCTAssertEqual(2, initializer.occurrences, file: file, line: line)
    }

    func testParseSwiftTypeCheckTimes() throws {
        try runTestParseSwiftTypeCheckTimes(rawFile: "project/CreatorHeaderViewModel",
                                            escapedFile: "project/CreatorHeaderViewModel")
        try runTestParseSwiftTypeCheckTimes(rawFile: "my project/CreatorHeaderViewModel",
                                            escapedFile: "my%20project/CreatorHeaderViewModel")
    }

    private func runTestParseSwiftTypeCheckTimes(rawFile: String,
                                                 escapedFile: String,
                                                 file: StaticString = #file,
                                                 line: UInt = #line) throws {
        let emptylogSection = getFakeSwiftcSection(text: "text",
                                              commandDescription: "command")

        let swiftTimesLogSection = getFakeSwiftcSection(text:
            "0.72ms\t/Users/\(rawFile).swift:19:15\r",
        commandDescription: "-debug-time-expression-type-checking")

        let duplicatedSwiftTimeslogSection = getFakeSwiftcSection(text:
            "0.72ms\t/Users/\(rawFile).swift:19:15\r",
        commandDescription: "-debug-time-expression-type-checking")
        let expectedFile = "file:///Users/\(escapedFile).swift"
        parser.addLogSection(emptylogSection)
        parser.addLogSection(swiftTimesLogSection)
        parser.addLogSection(duplicatedSwiftTimeslogSection)

        parser.parse()

        guard let typeChecks = parser.findTypeChecksForFilePath(expectedFile)
            else {
            XCTFail("The command should have swiftc type check times")
            return
        }
        XCTAssertEqual(1, typeChecks.count)
        XCTAssertEqual(19, typeChecks[0].startingLine)
        XCTAssertEqual(15, typeChecks[0].startingColumn)
        XCTAssertEqual(0.72, typeChecks[0].durationMS)
        XCTAssertEqual(expectedFile.removingPercentEncoding, typeChecks[0].file)
        XCTAssertEqual(2, typeChecks[0].occurrences)
    }

    /// A SwiftDriver build: the flag is in one section's command, the timing text is in another's.
    ///
    /// This is the arrangement Xcode 12 introduced and the reason `targetKey` exists. Neither section
    /// on its own looks like something to parse - the `SwiftDriver` section has the flag and no text,
    /// the `SwiftCompile` section has text and no flag - so a parser that only accepts a section whose
    /// own command carries the flag finds nothing here.
    func testParsesTimesWhenTheFlagIsInASiblingSection() throws {
        let target = "target-app"
        let driver = getFakeSwiftcSection(text: "",
                                          commandDescription: "-debug-time-function-bodies",
                                          signature: "SwiftDriver MyApp")
        let compile = getFakeSwiftcSection(text: "0.05ms\t/Users/user/MyView.swift:9:9\tgetter textLabel\r",
                                          commandDescription: "swift-frontend -c MyView.swift",
                                          signature: "SwiftCompile normal arm64 MyView.swift")
        parser.addLogSection(driver, targetKey: target)
        parser.addLogSection(compile, targetKey: target)

        parser.parse()

        let times = parser.findFunctionTimesForFilePath("file:///Users/user/MyView.swift")
        XCTAssertEqual(1, times?.count)
        XCTAssertEqual("getter textLabel", times?.first?.signature)
        XCTAssertEqual(0.05, times?.first?.durationMS)
    }

    /// The same for expression type checking, whose lines have two fields rather than three.
    func testParsesTypeChecksWhenTheFlagIsInASiblingSection() throws {
        let target = "target-app"
        let driver = getFakeSwiftcSection(text: "",
                                          commandDescription: "-debug-time-expression-type-checking",
                                          signature: "SwiftDriver MyApp")
        let compile = getFakeSwiftcSection(text: "0.72ms\t/Users/user/MyView.swift:19:15\r",
                                          commandDescription: "swift-frontend -c MyView.swift",
                                          signature: "SwiftCompile normal arm64 MyView.swift")
        parser.addLogSection(driver, targetKey: target)
        parser.addLogSection(compile, targetKey: target)

        parser.parse()

        let checks = parser.findTypeChecksForFilePath("file:///Users/user/MyView.swift")
        XCTAssertEqual(1, checks?.count)
        XCTAssertEqual(19, checks?.first?.startingLine)
        XCTAssertEqual(0.72, checks?.first?.durationMS)
    }

    /// A build where one target has the flags and another does not.
    ///
    /// The regression guard for the scoping. A flag is evidence about the target it was found in and
    /// nothing else, so the unflagged target's text must not be parsed even though it is shaped
    /// exactly like timing output - Xcode reports plenty of things that are, and a global "did anyone
    /// pass the flag" test would claim all of them.
    func testAFlaggedTargetDoesNotVouchForAnotherTarget() throws {
        let driver = getFakeSwiftcSection(text: "",
                                          commandDescription: "-debug-time-function-bodies",
                                          signature: "SwiftDriver Flagged")
        let flagged = getFakeSwiftcSection(text: "0.05ms\t/Users/user/Flagged.swift:9:9\tgetter a\r",
                                          commandDescription: "swift-frontend -c Flagged.swift",
                                          signature: "SwiftCompile normal arm64 Flagged.swift")
        let decoy = getFakeSwiftcSection(text: "9.99ms\t/Users/user/Decoy.swift:1:1\tgetter b\r",
                                         commandDescription: "swift-frontend -c Decoy.swift",
                                         signature: "SwiftCompile normal arm64 Decoy.swift")
        parser.addLogSection(driver, targetKey: "target-flagged")
        parser.addLogSection(flagged, targetKey: "target-flagged")
        parser.addLogSection(decoy, targetKey: "target-unflagged")

        parser.parse()

        XCTAssertEqual(1, parser.findFunctionTimesForFilePath("file:///Users/user/Flagged.swift")?.count)
        XCTAssertNil(parser.findFunctionTimesForFilePath("file:///Users/user/Decoy.swift"))
    }

    /// A build that passed neither flag, which is almost every build.
    ///
    /// Worth its own test because the flag scan is what keeps the common path cheap: nothing here
    /// should be parsed, and the timing-shaped text should never even be read.
    func testAnUnflaggedBuildYieldsNothing() throws {
        let compile = getFakeSwiftcSection(text: "0.05ms\t/Users/user/MyView.swift:9:9\tgetter textLabel\r",
                                          commandDescription: "swift-frontend -c MyView.swift",
                                          signature: "SwiftCompile normal arm64 MyView.swift")
        parser.addLogSection(compile, targetKey: "target-app")

        parser.parse()

        XCTAssertFalse(parser.hasFlaggedTargets())
        XCTAssertFalse(parser.hasFunctionTimes())
        XCTAssertFalse(parser.hasTypeChecks())
    }

    private func getFakeSwiftcSection(text: String,
                                      commandDescription: String,
                                      signature: String = "") -> IDEActivityLogSection {
        return IDEActivityLogSection(sectionType: 1,
                                     domainType: "",
                                     title: "Swiftc Compilation",
                                     signature: signature,
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
                                     commandDetailDesc: commandDescription,
                                     uniqueIdentifier: "",
                                     localizedResultString: "",
                                     xcbuildSignature: "",
                                     attachments: [],
                                     unknown: 0)
    }

}
