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
import Yams

/// A description of the log to generate.
///
/// These fields are not arbitrary knobs: each one exists because a benchmark conclusion depends on
/// it. Generating a log of the right *size* with the wrong shape produces numbers that look
/// plausible and measure nothing. `Benchmarks/Profiles/*.yaml` holds the checked-in profiles, and
/// `Benchmarks/Profiles/README.md` records which measurement each field feeds.
public struct Profile: Codable, Equatable {

    /// Number of leaf sections - the compile steps. Drives token count and the parser's array growth.
    public var sectionCount: Int

    /// Fraction of sections whose text contains at least one diagnostic marker, 0...1.
    ///
    /// The single largest win measured came from not splitting the text of sections that hold no
    /// diagnostic. At 1.0 that optimisation is invisible; at 0.0 the notice parser never runs.
    public var diagnosticDensity: Double

    /// Bytes of section text per section, before diagnostics are inserted.
    public var sectionTextBytes: Range

    /// Notices per section that has any, as a long-tailed distribution.
    ///
    /// A uniform count here misses what actually hurt: most sections have a handful and a few have
    /// hundreds, and the deep ones are what made notice parsing and detail sharing expensive.
    public var noticesPerSection: Tail

    /// How many distinct `detail` strings to draw from, as a fraction of total notices, 0...1.
    ///
    /// Low values make the parser derive many notices whose `detail` is the same string, which is
    /// what produced the copy-on-write sharing that dominated reported memory. This cannot be set
    /// directly - the generator controls it only by repeating section text.
    public var detailVariety: Double

    /// Target frequency of the `":"` byte in the emitted text, 0...1, or nil to leave it alone.
    ///
    /// Both diagnostic markers start with `":"`, and the notice fast path is gated on how often that
    /// byte occurs. Real logs sit near 0.008.
    public var colonByteFrequency: Double?

    /// Fraction of leaf sections that are C/ObjC compilations rather than Swift ones, 0...1.
    ///
    /// These are the sections that carry `[-Wflag]` markers in their text, and finding those is a
    /// regex scan over the whole section text - 5.12% of parse samples in a real log. A log made
    /// entirely of Swift compilations never runs that code, so an optimisation there looks free.
    public var clangSectionShare: Double

    /// Number of targets the leaf sections are spread across.
    ///
    /// `groupedByTarget()` reads the target out of each section's `commandDetailDesc` and rebuilds the
    /// tree around it. With one target that reduces to a single group and the reduce-over-dictionary
    /// it performs is never exercised at width.
    public var targetCount: Int

    /// Depth of intermediate sections between the root and the leaves, at least 1.
    ///
    /// The parser walks sections recursively, so a flat root-to-leaves log leaves the recursion
    /// untested at depth and understates the cost of carrying parent state down the tree.
    public var nestingDepth: Int

    /// Fraction of notices that are errors rather than warnings, 0...1.
    ///
    /// Errors take a different path through `assignNoticesFrom` than warnings do, and a log with no
    /// errors at all leaves the build-status and linker-error handling unexercised.
    public var errorShare: Double

    /// Emit the SwiftDriver section layout instead of the older `CompileSwift ` one.
    ///
    /// Xcode 12 moved Swift compilation behind `swift-driver`, and the sections changed shape with
    /// it: the `-debug-time-*` flags land in a `SwiftDriver …` section whose own text is empty,
    /// while the per-function timing output lands in its `SwiftCompile …` and `SwiftEmitModule …`
    /// siblings, which carry no flag. Nothing about that arrangement can be expressed by the flat
    /// one-section-per-file layout, so it needs its own switch rather than a knob on the old one.
    ///
    /// `nil` leaves the generator emitting the pre-SwiftDriver layout, which is what every existing
    /// profile describes.
    public var swiftDriverLayout: SwiftDriverLayout?

    /// Seed for the generator's PRNG. A profile plus a seed is a reproducible log.
    public var seed: UInt64

    /// How to shape a SwiftDriver-layout log.
    ///
    /// The fields exist to make two separate claims falsifiable. `flaggedTargetShare` below 1 is what
    /// tests the scoping - with every target flagged, a parser that ignored targets entirely would
    /// produce the same output and look correct. `decoyTimingText` is what tests that the flag is
    /// what admits the text rather than the text's own shape.
    public struct SwiftDriverLayout: Codable, Equatable {

        /// Fraction of targets built with `-debug-time-function-bodies` and
        /// `-debug-time-expression-type-checking`, 0...1.
        ///
        /// At 0 no target carries the flags, which is the common path: the parse should read no
        /// section text at all. At 1 every target carries them, which measures the feature at full
        /// load but cannot detect a parser that lost the target scoping. Between the two, the
        /// unflagged targets are the control group.
        public var flaggedTargetShare: Double

        /// Timing lines in each flagged `SwiftCompile` section's text.
        ///
        /// This is the volume knob for the feature: a flagged fleet log carries around 450,000
        /// timing lines in 176 MB of text, and everything expensive about parsing them scales with
        /// this number rather than with the section count.
        public var timingLinesPerFile: Int

        /// Give unflagged targets timing-shaped text too.
        ///
        /// The point of the whole scoping exercise. Xcode emits plenty of text that looks like
        /// timing output, so a parser that admits text on its shape rather than on its target's flag
        /// will pick this up - and with this false, that bug produces identical output and no test
        /// can see it.
        public var decoyTimingText: Bool

        public init(flaggedTargetShare: Double,
                    timingLinesPerFile: Int,
                    decoyTimingText: Bool = true) {
            self.flaggedTargetShare = flaggedTargetShare
            self.timingLinesPerFile = timingLinesPerFile
            self.decoyTimingText = decoyTimingText
        }

        /// Written out rather than synthesised, because the synthesised decoder does not know about
        /// the initializer's default and would require the key in YAML. Defaulting to `true` is the
        /// safer direction: a profile that omits it gets the decoys, so a scoping bug still fails
        /// rather than going unnoticed.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            flaggedTargetShare = try container.decode(Double.self, forKey: .flaggedTargetShare)
            timingLinesPerFile = try container.decode(Int.self, forKey: .timingLinesPerFile)
            decoyTimingText = try container.decodeIfPresent(Bool.self,
                                                           forKey: .decoyTimingText) ?? true
        }
    }

    public struct Range: Codable, Equatable {
        public var min: Int
        public var max: Int

        public init(min: Int, max: Int) {
            self.min = min
            self.max = max
        }
    }

    public init(sectionCount: Int,
                diagnosticDensity: Double,
                sectionTextBytes: Range,
                noticesPerSection: Tail,
                detailVariety: Double,
                colonByteFrequency: Double?,
                clangSectionShare: Double = 0,
                targetCount: Int = 1,
                nestingDepth: Int = 1,
                errorShare: Double = 0,
                swiftDriverLayout: SwiftDriverLayout? = nil,
                seed: UInt64) {
        self.sectionCount = sectionCount
        self.diagnosticDensity = diagnosticDensity
        self.sectionTextBytes = sectionTextBytes
        self.noticesPerSection = noticesPerSection
        self.detailVariety = detailVariety
        self.colonByteFrequency = colonByteFrequency
        self.clangSectionShare = clangSectionShare
        self.targetCount = targetCount
        self.nestingDepth = nestingDepth
        self.errorShare = errorShare
        self.swiftDriverLayout = swiftDriverLayout
        self.seed = seed
    }

    /// A discrete distribution given as explicit weighted buckets, so a profile states its tail
    /// rather than implying one through a parameter nobody can eyeball.
    public struct Tail: Codable, Equatable {
        public var buckets: [Bucket]

        public init(buckets: [Bucket]) {
            self.buckets = buckets
        }
    }

    /// One bucket of a `Tail`.
    public struct Bucket: Codable, Equatable {
        /// Notice count for this bucket.
        public var count: Int
        /// Relative weight. Need not sum to anything in particular.
        public var weight: Double

        public init(count: Int, weight: Double) {
            self.count = count
            self.weight = weight
        }
    }
}

extension Profile {

    /// Decoded with defaults for the optional shape fields, so a profile that predates them still
    /// loads and describes exactly the log it used to describe.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sectionCount = try container.decode(Int.self, forKey: .sectionCount)
        diagnosticDensity = try container.decode(Double.self, forKey: .diagnosticDensity)
        sectionTextBytes = try container.decode(Range.self, forKey: .sectionTextBytes)
        noticesPerSection = try container.decode(Tail.self, forKey: .noticesPerSection)
        detailVariety = try container.decode(Double.self, forKey: .detailVariety)
        colonByteFrequency = try container.decodeIfPresent(Double.self, forKey: .colonByteFrequency)
        clangSectionShare = try container.decodeIfPresent(Double.self, forKey: .clangSectionShare) ?? 0
        targetCount = try container.decodeIfPresent(Int.self, forKey: .targetCount) ?? 1
        nestingDepth = try container.decodeIfPresent(Int.self, forKey: .nestingDepth) ?? 1
        errorShare = try container.decodeIfPresent(Double.self, forKey: .errorShare) ?? 0
        swiftDriverLayout = try container.decodeIfPresent(SwiftDriverLayout.self,
                                                         forKey: .swiftDriverLayout)
        seed = try container.decode(UInt64.self, forKey: .seed)
    }

    public static func load(contentsOf url: URL) throws -> Profile {
        let text = try String(contentsOf: url, encoding: .utf8)
        let profile = try YAMLDecoder().decode(Profile.self, from: text)
        try profile.validate()
        return profile
    }

    /// Rejects profiles that would silently generate something other than what they describe.
    ///
    /// Checked at load rather than at use so a bad profile fails before any work happens, naming the
    /// field. A profile that asks for an impossible shape is a bug in the profile, not input to
    /// clamp quietly.
    public func validate() throws {
        try validateFractions()
        try validateSizes()
        try validateBuckets()
    }

    /// Every 0...1 field, checked together so the ranges live in one place.
    private func validateFractions() throws {
        let fractions: [(String, Double?)] = [
            ("diagnosticDensity", diagnosticDensity),
            ("detailVariety", detailVariety),
            ("clangSectionShare", clangSectionShare),
            ("errorShare", errorShare),
            ("colonByteFrequency", colonByteFrequency),
            ("swiftDriverLayout.flaggedTargetShare", swiftDriverLayout?.flaggedTargetShare)
        ]
        for (name, value) in fractions {
            guard let value = value else { continue }
            guard (0...1).contains(value) else {
                throw LogGenError.invalidProfile("\(name) must be between 0 and 1")
            }
        }
    }

    private func validateSizes() throws {
        guard sectionCount > 0 else {
            throw LogGenError.invalidProfile("sectionCount must be greater than 0")
        }
        guard sectionTextBytes.min >= 0, sectionTextBytes.max >= sectionTextBytes.min else {
            throw LogGenError.invalidProfile("sectionTextBytes needs 0 <= min <= max")
        }
        guard targetCount >= 1, targetCount <= sectionCount else {
            throw LogGenError.invalidProfile("targetCount needs 1 <= targetCount <= sectionCount")
        }
        guard nestingDepth >= 1 else {
            throw LogGenError.invalidProfile("nestingDepth must be at least 1")
        }
        if let layout = swiftDriverLayout {
            guard layout.timingLinesPerFile >= 0 else {
                throw LogGenError.invalidProfile(
                    "swiftDriverLayout.timingLinesPerFile cannot be negative")
            }
            // The scoping is only observable with a target on each side of the flag, and a profile
            // asking for a share strictly between 0 and 1 is asking for exactly that. One target
            // cannot provide it, so this would silently generate a log that proves less than the
            // profile claims.
            let partiallyFlagged = layout.flaggedTargetShare > 0 && layout.flaggedTargetShare < 1
            guard !partiallyFlagged || targetCount >= 2 else {
                throw LogGenError.invalidProfile(
                    "swiftDriverLayout.flaggedTargetShare between 0 and 1 needs targetCount of at least 2")
            }
        }
    }

    private func validateBuckets() throws {
        guard !noticesPerSection.buckets.isEmpty else {
            throw LogGenError.invalidProfile("noticesPerSection needs at least one bucket")
        }
        guard noticesPerSection.buckets.allSatisfy({ $0.weight >= 0 }) else {
            throw LogGenError.invalidProfile("noticesPerSection weights cannot be negative")
        }
        guard noticesPerSection.buckets.contains(where: { $0.weight > 0 }) else {
            throw LogGenError.invalidProfile("noticesPerSection needs one bucket with weight above 0")
        }
        guard noticesPerSection.buckets.allSatisfy({ $0.count >= 0 }) else {
            throw LogGenError.invalidProfile("noticesPerSection counts cannot be negative")
        }
    }
}

public enum LogGenError: Error, CustomStringConvertible {
    case invalidProfile(String)
    case unreadableProfile(String, String)
    case usage(String)

    public var description: String {
        switch self {
        case .invalidProfile(let reason):
            return "Invalid profile: \(reason)."
        case .unreadableProfile(let path, let reason):
            return "Cannot read profile \(path): \(reason)."
        case .usage(let message):
            return message
        }
    }
}
