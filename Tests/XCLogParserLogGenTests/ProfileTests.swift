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
@testable import XCLogParserLogGen

class ProfileTests: XCTestCase {

    private func write(_ yaml: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-\(UUID().uuidString).yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let valid = """
    sectionCount: 100
    diagnosticDensity: 0.068
    sectionTextBytes:
      min: 400
      max: 6000
    noticesPerSection:
      buckets:
        - count: 1
          weight: 70
        - count: 9
          weight: 30
    detailVariety: 0.22
    colonByteFrequency: 0.0078
    seed: 1
    """

    func testLoadsAProfile() throws {
        let profile = try Profile.load(contentsOf: try write(valid))
        XCTAssertEqual(profile.sectionCount, 100)
        XCTAssertEqual(profile.diagnosticDensity, 0.068)
        XCTAssertEqual(profile.sectionTextBytes.max, 6000)
        XCTAssertEqual(profile.noticesPerSection.buckets.count, 2)
        XCTAssertEqual(profile.colonByteFrequency, 0.0078)
    }

    /// `colonByteFrequency` is optional, meaning "leave the filler alone".
    func testColonFrequencyIsOptional() throws {
        let yaml = valid.replacingOccurrences(of: "colonByteFrequency: 0.0078\n", with: "")
        let profile = try Profile.load(contentsOf: try write(yaml))
        XCTAssertNil(profile.colonByteFrequency)
    }

    /// Invalid profiles are rejected at load with the offending field named, rather than clamped
    /// quietly - a profile that asks for an impossible shape is a bug in the profile, and silently
    /// generating something else would make the benchmark numbers describe an unknown input.
    func testRejectsOutOfRangeDensity() throws {
        let yaml = valid.replacingOccurrences(of: "diagnosticDensity: 0.068",
                                              with: "diagnosticDensity: 1.5")
        XCTAssertThrowsError(try Profile.load(contentsOf: try write(yaml))) { error in
            XCTAssertTrue("\(error)".contains("diagnosticDensity"), "got \(error)")
        }
    }

    func testRejectsZeroSections() throws {
        let yaml = valid.replacingOccurrences(of: "sectionCount: 100", with: "sectionCount: 0")
        XCTAssertThrowsError(try Profile.load(contentsOf: try write(yaml))) { error in
            XCTAssertTrue("\(error)".contains("sectionCount"), "got \(error)")
        }
    }

    func testRejectsInvertedTextRange() throws {
        let yaml = valid.replacingOccurrences(of: "min: 400", with: "min: 9000")
        XCTAssertThrowsError(try Profile.load(contentsOf: try write(yaml))) { error in
            XCTAssertTrue("\(error)".contains("sectionTextBytes"), "got \(error)")
        }
    }

    func testRejectsEmptyBuckets() throws {
        let yaml = """
        sectionCount: 100
        diagnosticDensity: 0.068
        sectionTextBytes:
          min: 400
          max: 6000
        noticesPerSection:
          buckets: []
        detailVariety: 0.22
        seed: 1
        """
        XCTAssertThrowsError(try Profile.load(contentsOf: try write(yaml))) { error in
            XCTAssertTrue("\(error)".contains("noticesPerSection"), "got \(error)")
        }
    }

    func testRejectsAllZeroWeights() throws {
        let yaml = valid.replacingOccurrences(of: "weight: 70", with: "weight: 0")
            .replacingOccurrences(of: "weight: 30", with: "weight: 0")
        XCTAssertThrowsError(try Profile.load(contentsOf: try write(yaml))) { error in
            XCTAssertTrue("\(error)".contains("noticesPerSection"), "got \(error)")
        }
    }

    /// The shape fields are optional, so a profile written before they existed still loads and still
    /// describes the same log rather than failing or silently changing shape.
    func testShapeFieldsDefaultWhenAbsent() throws {
        let profile = try Profile.load(contentsOf: try write(valid))
        XCTAssertEqual(profile.clangSectionShare, 0)
        XCTAssertEqual(profile.targetCount, 1)
        XCTAssertEqual(profile.nestingDepth, 1)
        XCTAssertEqual(profile.errorShare, 0)
    }

    func testRejectsTargetCountAboveSectionCount() throws {
        let yaml = valid + "\ntargetCount: 500"
        XCTAssertThrowsError(try Profile.load(contentsOf: try write(yaml))) { error in
            XCTAssertTrue("\(error)".contains("targetCount"), "got \(error)")
        }
    }

    func testRejectsOutOfRangeClangShare() throws {
        let yaml = valid + "\nclangSectionShare: 2.0"
        XCTAssertThrowsError(try Profile.load(contentsOf: try write(yaml))) { error in
            XCTAssertTrue("\(error)".contains("clangSectionShare"), "got \(error)")
        }
    }

    func testRejectsZeroNestingDepth() throws {
        let yaml = valid + "\nnestingDepth: 0"
        XCTAssertThrowsError(try Profile.load(contentsOf: try write(yaml))) { error in
            XCTAssertTrue("\(error)".contains("nestingDepth"), "got \(error)")
        }
    }

    /// Absent means the older layout, so every profile written before it existed still describes the
    /// log it used to describe.
    func testSwiftDriverLayoutIsOptional() throws {
        let profile = try Profile.load(contentsOf: try write(valid))
        XCTAssertNil(profile.swiftDriverLayout)
    }

    func testLoadsASwiftDriverLayout() throws {
        let yaml = valid + """

        targetCount: 4
        swiftDriverLayout:
          flaggedTargetShare: 0.5
          timingLinesPerFile: 12
          decoyTimingText: true
        """
        let layout = try XCTUnwrap(try Profile.load(contentsOf: try write(yaml)).swiftDriverLayout)
        XCTAssertEqual(layout.flaggedTargetShare, 0.5)
        XCTAssertEqual(layout.timingLinesPerFile, 12)
        XCTAssertTrue(layout.decoyTimingText)
    }

    func testRejectsOutOfRangeFlaggedShare() throws {
        let yaml = valid + """

        swiftDriverLayout:
          flaggedTargetShare: 1.5
          timingLinesPerFile: 4
        """
        XCTAssertThrowsError(try Profile.load(contentsOf: try write(yaml))) { error in
            XCTAssertTrue("\(error)".contains("flaggedTargetShare"), "got \(error)")
        }
    }

    /// A partially-flagged share is a request for unflagged targets to compare against, and one target
    /// cannot supply them. Rejected rather than clamped, because the log would then prove less than
    /// the profile says it does.
    func testRejectsPartialFlaggedShareWithOneTarget() throws {
        let yaml = valid + """

        swiftDriverLayout:
          flaggedTargetShare: 0.5
          timingLinesPerFile: 4
        """
        XCTAssertThrowsError(try Profile.load(contentsOf: try write(yaml))) { error in
            XCTAssertTrue("\(error)".contains("flaggedTargetShare"), "got \(error)")
        }
    }

    /// The all-or-nothing shares are meaningful with a single target, so they must still load.
    func testAcceptsWholeFlaggedSharesWithOneTarget() throws {
        for share in ["0.0", "1.0"] {
            let yaml = valid + """

            swiftDriverLayout:
              flaggedTargetShare: \(share)
              timingLinesPerFile: 4
            """
            XCTAssertNoThrow(try Profile.load(contentsOf: try write(yaml)), "share \(share)")
        }
    }

    /// The checked-in profiles are part of the deliverable, so they are validated here rather than
    /// only when someone runs the generator.
    func testCheckedInProfilesAreValid() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // XCLogParserLogGenTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Benchmarks/Profiles")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "yaml" }

        XCTAssertFalse(files.isEmpty, "expected checked-in profiles at \(root.path)")
        for file in files {
            XCTAssertNoThrow(try Profile.load(contentsOf: file), "invalid profile: \(file.lastPathComponent)")
        }
    }
}
