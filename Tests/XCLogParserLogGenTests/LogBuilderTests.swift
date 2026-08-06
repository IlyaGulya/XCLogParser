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
import Gzip
@testable import XCLogParser
@testable import XCLogParserLogGen

class LogBuilderTests: XCTestCase {

    private func profile(sections: Int = 40,
                         density: Double = 1.0,
                         variety: Double = 1.0,
                         clangShare: Double = 0,
                         targets: Int = 1,
                         depth: Int = 1,
                         errors: Double = 0,
                         seed: UInt64 = 7) -> Profile {
        return Profile(
            sectionCount: sections,
            diagnosticDensity: density,
            sectionTextBytes: Profile.Range(min: 200, max: 800),
            noticesPerSection: Profile.Tail(buckets: [
                Profile.Bucket(count: 2, weight: 70),
                Profile.Bucket(count: 9, weight: 30)
            ]),
            detailVariety: variety,
            colonByteFrequency: 0.0078,
            clangSectionShare: clangShare,
            targetCount: targets,
            nestingDepth: depth,
            errorShare: errors,
            seed: seed
        )
    }

    private func parse(_ document: Data) throws -> BuildStep {
        let lexer = Lexer(filePath: "generated.xcactivitylog")
        // Failable on purpose: a nil here would mean the generator emitted invalid UTF-8, which is
        // a generator bug worth failing the test rather than papering over with replacement
        // characters.
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

    private func notices(in step: BuildStep) -> [Notice] {
        return (step.warnings ?? []) + (step.errors ?? []) + (step.notes ?? [])
            + step.subSteps.flatMap { notices(in: $0) }
    }

    /// The generated document has to survive the real lexer and parser. Everything else in this file
    /// depends on that, and a layout mistake shows up here as a thrown error.
    func testGeneratedLogParses() throws {
        var builder = LogBuilder(profile: profile())
        let (document, stats) = builder.build()
        let root = try parse(document)
        // Not `root.subSteps.count`: the generated sections all name the same target, so
        // `groupedByTarget()` correctly folds them under one target step and the leaves sit a level
        // down. Counting the whole tree is what corresponds to the requested section count.
        func leaves(_ step: BuildStep) -> Int {
            return step.subSteps.isEmpty ? 1 : step.subSteps.reduce(0) { $0 + leaves($1) }
        }
        XCTAssertEqual(leaves(root), stats.sectionCount)
    }

    /// Guards the failure mode that hides itself: a log where every notice parses but every `detail`
    /// comes back nil, because the location written into the file and the marker written into the
    /// text disagree by one. The notice count stays correct, nothing throws, and the most expensive
    /// code path in the parser silently never runs - so asserting on counts alone is not enough.
    func testNoticeDetailsResolve() throws {
        // Swift-only on purpose: these are the notices whose detail comes from the
        // `path:line:column:` lookup, so every one of them must resolve. Clang notices reach their
        // detail by a different route and are covered separately.
        var builder = LogBuilder(profile: profile(clangShare: 0))
        let (document, _) = builder.build()
        let parsed = notices(in: try parse(document))

        XCTAssertFalse(parsed.isEmpty, "generated log produced no notices to check")
        let withDetail = parsed.filter { ($0.detail?.isEmpty == false) }
        XCTAssertEqual(withDetail.count, parsed.count,
                       "every generated notice should resolve to a detail from the section text")
    }

    /// The clang path is the reason `clangSectionShare` exists: finding `[-Wflag]` in section text is
    /// a regex scan over the whole text, and it was 5.12% of parse samples in a real log. A log made
    /// only of Swift compilations never runs it, so work done there measures as free.
    func testClangSectionsProduceClangNotices() throws {
        var builder = LogBuilder(profile: profile(sections: 200, clangShare: 1.0))
        let (document, stats) = builder.build()
        let parsed = notices(in: try parse(document))

        XCTAssertEqual(stats.clangSections, 200)
        let withFlag = parsed.filter { $0.clangFlag?.isEmpty == false }
        XCTAssertFalse(withFlag.isEmpty, "clang sections should yield notices carrying a -W flag")
        let clangTypes = parsed.filter { $0.type == .clangWarning || $0.type == .deprecatedWarning }
        XCTAssertFalse(clangTypes.isEmpty, "clang sections should yield clang-typed notices")
    }

    /// `-Wdeprecated-declarations` has to actually drive the reclassification, since that is a
    /// distinct branch in `assignNoticesFrom`.
    func testClangSectionsProduceDeprecatedWarnings() throws {
        var builder = LogBuilder(profile: profile(sections: 400, clangShare: 1.0))
        let (document, _) = builder.build()
        let parsed = notices(in: try parse(document))
        XCTAssertTrue(parsed.contains { $0.type == .deprecatedWarning },
                      "expected -Wdeprecated-declarations to be reclassified")
    }

    /// `errorShare: 0` has to mean the marker is absent from the bytes, not merely that no notice is
    /// typed as an error. The real fleet log contains no `": error:"` in 278 MB, and that absence is
    /// what made the marker-scanning measurement possible: the first of two searches always ran to
    /// the end of every line and always failed. A stray error marker would quietly remove the
    /// worst case the profile exists to reproduce.
    func testZeroErrorShareEmitsNoErrorMarker() throws {
        var builder = LogBuilder(profile: profile(sections: 200, errors: 0))
        let (document, _) = builder.build()
        let text = try XCTUnwrap(String(bytes: document, encoding: .utf8))

        XCTAssertFalse(text.contains(": error:"),
                       "errorShare 0 must leave no \": error:\" marker anywhere in the document")
        XCTAssertTrue(text.contains(": warning:"), "expected warning markers to still be present")
    }

    func testErrorShareProducesErrors() throws {
        var builder = LogBuilder(profile: profile(sections: 200, errors: 1.0))
        let (document, stats) = builder.build()
        let parsed = notices(in: try parse(document))

        XCTAssertEqual(stats.errorCount, stats.noticeCount)
        XCTAssertTrue(parsed.contains { $0.type == .swiftError }, "expected errors in the output")
    }

    /// `groupedByTarget()` reads the target out of each section's `commandDetailDesc`, so multiple
    /// targets have to actually show up as separate groups in the parsed tree.
    func testMultipleTargetsAppearInTheTree() throws {
        var builder = LogBuilder(profile: profile(sections: 120, targets: 6, depth: 2))
        let (document, stats) = builder.build()
        let root = try parse(document)

        XCTAssertEqual(stats.intermediateSections, 6)
        XCTAssertGreaterThan(root.subSteps.count, 1,
                             "several targets should not collapse into a single group")
    }

    /// Nesting has to produce real depth: the parser walks sections recursively and carries parent
    /// state down, which a flat root-to-leaves log never exercises.
    func testNestingProducesDepth() throws {
        var flatBuilder = LogBuilder(profile: profile(sections: 60, targets: 4, depth: 1))
        var nestedBuilder = LogBuilder(profile: profile(sections: 60, targets: 4, depth: 3))

        func depth(_ step: BuildStep) -> Int {
            return 1 + (step.subSteps.map { depth($0) }.max() ?? 0)
        }
        let flat = depth(try parse(flatBuilder.build().document))
        let nested = depth(try parse(nestedBuilder.build().document))
        XCTAssertGreaterThan(nested, flat, "a deeper profile should produce a deeper tree")
    }

    /// A detail is only useful if it carries the continuation lines too, since folding those in is
    /// what makes the strings big enough for sharing to matter.
    func testDetailIncludesContinuationLines() throws {
        var builder = LogBuilder(profile: profile())
        let (document, _) = builder.build()
        let parsed = notices(in: try parse(document))

        let detail = try XCTUnwrap(parsed.first?.detail)
        XCTAssertTrue(detail.contains(": warning: "), "detail should carry the marker: \(detail)")
        XCTAssertTrue(detail.contains("\n"), "detail should fold in continuation lines: \(detail)")
    }

    /// Low variety has to actually produce shared details, because that sharing is the property the
    /// memory measurements depend on.
    func testLowVarietyProducesSharedDetails() throws {
        var sharing = LogBuilder(profile: profile(sections: 200, variety: 0.05))
        let (shared, _) = sharing.build()
        var varying = LogBuilder(profile: profile(sections: 200, variety: 1.0))
        let (unique, _) = varying.build()

        func distinctRatio(_ document: Data) throws -> Double {
            let parsed = notices(in: try parse(document))
            let details = Set(parsed.compactMap { $0.detail })
            return Double(details.count) / Double(max(1, parsed.count))
        }

        let sharedRatio = try distinctRatio(shared)
        let uniqueRatio = try distinctRatio(unique)
        XCTAssertLessThan(sharedRatio, uniqueRatio,
                          "a low detailVariety should collapse details onto fewer distinct strings")
    }

    /// A profile plus a seed has to be a log, not a family of logs: a benchmark comparison against
    /// an older run is only valid if the input can be regenerated exactly.
    func testSameSeedProducesIdenticalOutput() throws {
        var first = LogBuilder(profile: profile(seed: 99))
        var second = LogBuilder(profile: profile(seed: 99))
        XCTAssertEqual(first.build().document, second.build().document)
    }

    func testDifferentSeedProducesDifferentOutput() throws {
        var first = LogBuilder(profile: profile(seed: 1))
        var second = LogBuilder(profile: profile(seed: 2))
        XCTAssertNotEqual(first.build().document, second.build().document)
    }

    /// The realised numbers are what the generator reports, so they have to describe the document it
    /// actually produced rather than the profile it was asked for.
    func testStatisticsMatchTheParsedLog() throws {
        var builder = LogBuilder(profile: profile(sections: 120, density: 0.5))
        let (document, stats) = builder.build()
        let parsed = notices(in: try parse(document))

        XCTAssertEqual(parsed.count, stats.noticeCount)
        XCTAssertEqual(stats.sectionCount, 120)
        XCTAssertGreaterThan(stats.sectionsWithDiagnostics, 0)
        XCTAssertLessThan(stats.sectionsWithDiagnostics, 120)
    }

    /// Zero density is the control: it should produce a parseable log with no notices at all, which
    /// is what isolates the cost of section text from the cost of diagnostics.
    func testZeroDensityProducesNoNotices() throws {
        var builder = LogBuilder(profile: profile(density: 0.0))
        let (document, stats) = builder.build()
        XCTAssertEqual(stats.noticeCount, 0)
        XCTAssertEqual(notices(in: try parse(document)).count, 0)
    }

    /// The target is reachable at a realistic diagnostic density, which is what the profiles use.
    func testColonFrequencyApproachesTheProfile() throws {
        var builder = LogBuilder(profile: profile(sections: 400, density: 0.068))
        let (_, stats) = builder.build()
        XCTAssertEqual(stats.colonByteFrequency, 0.0078, accuracy: 0.003)
    }

    /// Documents the ceiling rather than pretending it does not exist: diagnostic lines are
    /// colon-rich, so above a certain density they alone exceed the requested frequency and the
    /// filler cannot bring it back down. This is why the generator reports the realised figure next
    /// to the requested one instead of just echoing the profile.
    func testColonFrequencyIsExceededAtHighDensity() throws {
        var builder = LogBuilder(profile: profile(sections: 400, density: 1.0))
        let (_, stats) = builder.build()
        XCTAssertGreaterThan(stats.colonByteFrequency, 0.0078)
    }
}
