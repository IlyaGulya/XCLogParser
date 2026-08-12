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

/// End-to-end coverage for the SwiftDriver section layout Xcode 12 introduced.
///
/// `SwiftCompilerParserTests` covers the parsing logic against hand-built sections. This file covers
/// the part those cannot: a whole generated log going through the real lexer, activity parser and
/// build-step parser, with the flags in one section and the timing output in its siblings.
///
/// Why a generated log rather than a committed fixture: a real one carries absolute paths, target
/// names and project names, and the flagged logs that exercise this are 16 MB. The generator states
/// what it wrote, so the expected counts come from the log itself rather than from a number pasted
/// into an assertion.
class SwiftDriverLayoutTests: XCTestCase {

    private func profile(sections: Int = 40,
                         targets: Int = 4,
                         flaggedShare: Double = 0.5,
                         linesPerFile: Int = 8,
                         decoys: Bool = true,
                         seed: UInt64 = 20_260_812) -> Profile {
        return Profile(
            sectionCount: sections,
            diagnosticDensity: 0,
            sectionTextBytes: Profile.Range(min: 0, max: 0),
            noticesPerSection: Profile.Tail(buckets: [Profile.Bucket(count: 0, weight: 1)]),
            detailVariety: 0,
            colonByteFrequency: nil,
            clangSectionShare: 0,
            targetCount: targets,
            nestingDepth: 1,
            errorShare: 0,
            swiftDriverLayout: Profile.SwiftDriverLayout(flaggedTargetShare: flaggedShare,
                                                         timingLinesPerFile: linesPerFile,
                                                         decoyTimingText: decoys),
            seed: seed
        )
    }

    private func parse(_ document: Data) throws -> BuildStep {
        let lexer = Lexer(filePath: "generated.xcactivitylog")
        let contents = try XCTUnwrap(String(bytes: document, encoding: .utf8))
        let tokens = try lexer.tokenize(contents: contents,
                                        redacted: false,
                                        withoutBuildSpecificInformation: false)
        let log = try ActivityParser().parseIDEActiviyLogFromTokens(tokens)
        return try ParserBuildSteps(machineName: "test",
                                    omitWarningsDetails: false,
                                    omitNotesDetails: false,
                                    truncLargeIssues: false).parse(activityLog: log)
    }

    private func functionTimes(in step: BuildStep) -> [SwiftFunctionTime] {
        return (step.swiftFunctionTimes ?? []) + step.subSteps.flatMap { functionTimes(in: $0) }
    }

    private func typeChecks(in step: BuildStep) -> [SwiftTypeCheck] {
        return (step.swiftTypeCheckTimes ?? []) + step.subSteps.flatMap { typeChecks(in: $0) }
    }

    /// The whole point, in one assertion: the flags are in the `SwiftDriver` sections, the timing text
    /// is in their `SwiftCompile` siblings, and the parse finds exactly what the generator wrote.
    ///
    /// Both counts come from the generator's realised statistics, which deliberately exclude decoy
    /// lines - so this is simultaneously "found everything real" and "found nothing else".
    func testFindsExactlyTheTimesWrittenIntoFlaggedTargets() throws {
        var builder = LogBuilder(profile: profile())
        let (document, stats) = builder.build()

        let root = try parse(document)

        XCTAssertEqual(functionTimes(in: root).count, stats.functionTimingLines)
        XCTAssertEqual(typeChecks(in: root).count, stats.typeCheckTimingLines)
        // Guards the assertion above from passing on an empty log, which it would if the generator
        // silently produced no timing text at all.
        XCTAssertGreaterThan(stats.functionTimingLines, 0)
        XCTAssertGreaterThan(stats.typeCheckTimingLines, 0)
    }

    /// The regression guard for the target scoping.
    ///
    /// Half the targets carry the flags and half do not, and every target's text is timing-shaped. A
    /// parser that admitted text on its shape - or that treated the flag as a global "did anyone pass
    /// it" - picks up the decoys too and this fails. Verified to fail that way: removing the
    /// target-membership check from `forEachTimingCandidate` takes 144/20 to 292/36.
    func testDecoyTargetsContributeNoTimes() throws {
        var builder = LogBuilder(profile: profile())
        let (document, _) = builder.build()

        let root = try parse(document)
        let files = Set(functionTimes(in: root).map(\.file) + typeChecks(in: root).map(\.file))
        XCTAssertFalse(files.isEmpty)

        // Two kinds of path reach the output. A compile section's file is dealt round-robin over the
        // targets, so its target is its `File<n>` index modulo the target count. A module-emit
        // section's file names its target directly. Either way the first two targets are the flagged
        // ones, so anything attributed to target 2 or 3 is a decoy that leaked.
        for file in files {
            let target = try XCTUnwrap(Self.targetIndex(in: file, targetCount: 4),
                                       "unexpected file in output: \(file)")
            XCTAssertLessThan(target, 2, "times attributed to an unflagged target: \(file)")
        }
    }

    /// A build that passed neither flag, which is nearly every build.
    ///
    /// The text is still timing-shaped, so this is what would fail if the flags stopped being what
    /// admits it.
    func testAnUnflaggedBuildYieldsNoTimes() throws {
        var builder = LogBuilder(profile: profile(flaggedShare: 0))
        let (document, stats) = builder.build()

        XCTAssertEqual(stats.flaggedTargets, 0)
        XCTAssertEqual(stats.functionTimingLines, 0)

        let root = try parse(document)
        XCTAssertTrue(functionTimes(in: root).isEmpty)
        XCTAssertTrue(typeChecks(in: root).isEmpty)
    }

    /// Every target flagged, so nothing is held back.
    ///
    /// Worth having alongside the half-flagged case because it is the configuration a benchmark runs,
    /// and because it fails if the scoping is too *strict* - a bug the decoy test cannot see, since
    /// finding nothing at all passes it.
    func testEveryTargetFlaggedFindsEveryTime() throws {
        var builder = LogBuilder(profile: profile(flaggedShare: 1))
        let (document, stats) = builder.build()

        let root = try parse(document)

        XCTAssertEqual(stats.flaggedTargets, 4)
        XCTAssertEqual(functionTimes(in: root).count, stats.functionTimingLines)
        XCTAssertEqual(typeChecks(in: root).count, stats.typeCheckTimingLines)
    }

    /// The `SwiftDriver` sections must carry the flags and no text, and their siblings the reverse.
    ///
    /// Asserted on the generated document rather than on the parse, because it is the premise every
    /// other test here rests on: if the generator ever put the flag and the text in the same section,
    /// the layout would be trivially parseable and the suite would still pass while testing nothing.
    func testTheFlagAndTheTimingTextAreInDifferentSections() throws {
        var builder = LogBuilder(profile: profile(flaggedShare: 1))
        let (document, _) = builder.build()
        let text = try XCTUnwrap(String(bytes: document, encoding: .utf8))

        XCTAssertTrue(text.contains("SwiftDriver -- "))
        XCTAssertTrue(text.contains("-debug-time-function-bodies"))
        XCTAssertTrue(text.contains("SwiftCompile normal arm64"))
        XCTAssertTrue(text.contains("SwiftEmitModule normal arm64"))
        // The pre-SwiftDriver signature must not appear: if it did, the older code path would pick
        // these sections up and none of this would be testing the new layout.
        XCTAssertFalse(text.contains("CompileSwift normal arm64"))
    }

    /// Which target a result's file belongs to, or `nil` if the path is neither shape the generator
    /// emits - which is a test-expectation failure rather than something to skip quietly.
    private static func targetIndex(in file: String, targetCount: Int) -> Int? {
        if let marker = file.range(of: "/Sources/Target", options: .backwards),
           let slash = file.range(of: "/", range: marker.upperBound..<file.endIndex) {
            return Int(file[marker.upperBound..<slash.lowerBound])
        }
        guard let marker = file.range(of: "/File", options: .backwards),
              let dot = file.range(of: ".swift", options: .backwards),
              let index = Int(file[marker.upperBound..<dot.lowerBound]) else {
            return nil
        }
        return index % targetCount
    }
}
