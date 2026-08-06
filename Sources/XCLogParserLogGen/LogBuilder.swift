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

/// Builds an SLF document from a `Profile`.
///
/// This file decides *what* the log contains; `LogBuilder+Emit.swift` writes it out, and that is
/// where the parser's field order has to be matched.
public struct LogBuilder {

    private let profile: Profile
    private var random: SeededRandom
    /// The realised statistics, filled in as sections are emitted, so the generator reports what it
    /// actually produced rather than what was requested.
    private var stats = Statistics()

    public init(profile: Profile) {
        self.profile = profile
        self.random = SeededRandom(seed: profile.seed)
    }

    public struct Statistics: Equatable {
        public var sectionCount = 0
        public var sectionsWithDiagnostics = 0
        public var noticeCount = 0
        public var sectionTextBytes = 0
        public var colonBytes = 0
        public var distinctDetails = 0
        public var clangSections = 0
        public var errorCount = 0
        public var intermediateSections = 0

        public var clangSectionShare: Double {
            sectionCount == 0 ? 0 : Double(clangSections) / Double(sectionCount)
        }
        public var errorShare: Double {
            noticeCount == 0 ? 0 : Double(errorCount) / Double(noticeCount)
        }

        public var diagnosticDensity: Double {
            sectionCount == 0 ? 0 : Double(sectionsWithDiagnostics) / Double(sectionCount)
        }
        public var colonByteFrequency: Double {
            sectionTextBytes == 0 ? 0 : Double(colonBytes) / Double(sectionTextBytes)
        }
    }

    // MARK: - Building

    public mutating func build() -> (document: Data, statistics: Statistics) {
        var writer = SLFWriter()

        let leaves = (0..<profile.sectionCount).map { makeLeaf(index: $0) }
        stats.distinctDetails = Set(leaves.flatMap { $0.notices.map(\.detail) }).count

        // `isCommandLineLog` in the parser keys off the root's domain type, so this string is
        // load-bearing rather than cosmetic.
        writeSection(
            &writer,
            section: Section(
                domainType: "com.apple.dt.IDE.BuildLogSection",
                title: "Build target",
                signature: "Build target GeneratedApp",
                text: "",
                documentURL: "",
                commandDetailDesc: "",
                notices: [],
                subSections: group(leaves: leaves, depth: profile.nestingDepth)
            ),
            isRoot: true
        )

        return (writer.document(), stats)
    }

    /// Wraps `leaves` in `depth` levels of intermediate sections.
    ///
    /// Xcode does not emit a flat root-to-leaves tree, and the parser walks sections recursively
    /// while carrying parent state down - `getSwiftIndividualSteps` reads the *parent's*
    /// `commandDetailDesc` when the child's does not name the file. A flat log leaves that untested.
    private mutating func group(leaves: [Section], depth: Int) -> [Section] {
        guard depth > 1, leaves.count > 1 else { return leaves }

        // Split into as many groups as there are targets, so each intermediate section carries one
        // target's steps the way a real build groups them.
        let groups = max(1, min(profile.targetCount, leaves.count))
        let perGroup = (leaves.count + groups - 1) / groups
        var wrapped: [Section] = []
        wrapped.reserveCapacity(groups)
        for start in stride(from: 0, to: leaves.count, by: perGroup) {
            let slice = Array(leaves[start..<min(start + perGroup, leaves.count)])
            let target = targetName(for: start)
            wrapped.append(Section(
                domainType: "com.apple.dt.IDE.BuildLogSection",
                title: "Build target \(target)",
                signature: "Build target \(target)",
                text: "",
                documentURL: "",
                commandDetailDesc: "",
                notices: [],
                subSections: slice
            ))
            stats.intermediateSections += 1
        }
        return group(leaves: wrapped, depth: depth - 1)
    }

    private func targetName(for index: Int) -> String {
        return profile.targetCount <= 1 ? "GeneratedApp"
            : "Target\(index % profile.targetCount)"
    }

    // MARK: - Model

    /// The subset of a log section this generator varies. Everything else is emitted as a constant.
    struct Section {
        var domainType: String
        var title: String
        var signature: String
        var text: String
        var documentURL: String
        var commandDetailDesc: String
        var notices: [Notice]
        var subSections: [Section] = []
    }

    struct Notice {
        var title: String
        var detail: String
        var documentURL: String
        var line: Int
        var column: Int
        var isError: Bool
        /// The `-Wflag` this notice reports, for clang sections. Written into the section text as
        /// `[-Wflag]`, which is where `parseClangWarningFlags` finds it.
        var clangFlag: String?
    }

    // MARK: - Leaves

    private mutating func makeLeaf(index: Int) -> Section {
        let isClang = random.unitDouble() < profile.clangSectionShare
        let ext = isClang ? "m" : "swift"
        let file = "/project/Sources/Module\(index % 200)/File\(index).\(ext)"
        let documentURL = "file://\(file)"
        let target = targetName(for: index)
        let hasDiagnostics = random.unitDouble() < profile.diagnosticDensity

        var notices: [Notice] = []
        if hasDiagnostics {
            let bucketWeights = profile.noticesPerSection.buckets.map(\.weight)
            let count = profile.noticesPerSection.buckets[random.weightedIndex(weights: bucketWeights)].count
            notices = (0..<count).map { _ in
                makeNotice(file: file, documentURL: documentURL, isClang: isClang)
            }
        }

        let text = makeSectionText(notices: notices, isClang: isClang)

        stats.sectionCount += 1
        stats.noticeCount += notices.count
        if isClang { stats.clangSections += 1 }
        stats.errorCount += notices.filter { $0.isError }.count
        if hasDiagnostics && !notices.isEmpty { stats.sectionsWithDiagnostics += 1 }
        stats.sectionTextBytes += text.utf8.count
        stats.colonBytes += Self.colonCount(in: text)

        let command = isClang
            ? "CompileC /build/File\(index).o \(file) normal arm64 objective-c"
            : "CompileSwift normal arm64 \(file)"
        return Section(
            domainType: "com.apple.dt.IDE.BuildLogSection",
            title: "Compile \(file)",
            signature: "\(command) (in target '\(target)' from project 'GeneratedApp')",
            text: text,
            // Must match each notice's documentURL: `assignNoticesFrom` drops a notice whose
            // document differs from a non-empty section location, to avoid duplicate reports.
            documentURL: documentURL,
            // `groupedByTarget()` reads the target out of this string, so the "in target 'X' from
            // project 'Y'" spelling is what makes multiple targets appear in the output at all.
            commandDetailDesc: "\(command) (in target '\(target)' from project 'GeneratedApp')",
            notices: notices
        )
    }

    private mutating func makeNotice(file: String, documentURL: String, isClang: Bool) -> Notice {
        // `detailVariety` is the fraction of notices that get their own location. The rest are drawn
        // from a small fixed set of locations, so many notices resolve through the same key and end
        // up sharing one `detail` string - the copy-on-write behaviour that dominated reported
        // memory. Sharing cannot be written into the file directly: `detail` is derived by the
        // parser from the section text, so the only lever is how often a location repeats.
        let line: Int
        let column: Int
        if random.unitDouble() < profile.detailVariety {
            line = random.int(in: 1...4000)
            column = random.int(in: 1...120)
        } else {
            // A handful of hot locations, the way a warning in a widely-included header repeats
            // across every file that pulls it in.
            let hot = random.int(in: 0...7)
            line = 100 + hot * 10
            column = 5
        }
        let isError = random.unitDouble() < profile.errorShare
        let severity = isError ? "error" : "warning"
        let corpus = isClang ? Self.clangMessages : Self.warningMessages
        let message = corpus[(line + column) % corpus.count]
        let flag = isClang ? Self.clangFlags[(line + column) % Self.clangFlags.count] : nil

        // `parseClangWarnings` zips the section's messages against the flags found in its text, so a
        // clang notice's own flag has to appear in the text in the same order the messages do.
        let marker = flag.map { " [\($0)]" } ?? ""
        return Notice(
            title: message + marker,
            // The key `parseSwiftIssuesDetailsByLocation` builds is `path:line:column:`, so the
            // marker in the text has to be spelled exactly this way for the lookup to hit.
            detail: "\(file):\(line):\(column): \(severity): \(message)\(marker)",
            documentURL: documentURL,
            line: line,
            column: column,
            isError: isError,
            clangFlag: flag
        )
    }

    /// Section text: the diagnostic lines plus filler.
    ///
    /// Lines are joined with `\r`, because `parseSwiftIssuesDetailsByLocation` splits on `\r` and
    /// nothing else. Using `\n` produces text that looks right and parses as one single line.
    private mutating func makeSectionText(notices: [Notice], isClang: Bool) -> String {
        var lines: [String] = []
        for notice in notices {
            lines.append(notice.detail)
            // Xcode follows each diagnostic with the source line and a caret. These are the
            // continuation lines that get folded into the detail by the `\r` reducer.
            lines.append(isClang ? "    int value = compute(\(notice.line));"
                                 : "    let value = compute(\(notice.line))")
            lines.append(String(repeating: " ", count: min(notice.column, 40)) + "^")
        }

        let target = random.int(in: profile.sectionTextBytes.min...profile.sectionTextBytes.max)
        var text = lines.joined(separator: "\r")
        let written = text.utf8.count
        if written < target {
            if !text.isEmpty { text += "\r" }
            text += filler(bytes: target - written)
        }
        return text
    }

    /// Filler text for a section, tuned to hit the profile's `":"` frequency.
    ///
    /// Filler is not inert: the notice fast path is gated on how often `":"` appears, so filler with
    /// no colons makes that gate look free and filler full of them makes it look useless.
    private mutating func filler(bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        // Assembled as bytes with a running length, not by appending to a String and asking for
        // `utf8.count` each time round: that recounts the whole buffer per line, which is quadratic
        // in section size and was most of the generator's runtime. The corpus is pre-measured for the
        // same reason.
        var out: [UInt8] = []
        out.reserveCapacity(bytes + 64)
        var colons = 0
        while out.count < bytes {
            let index = random.int(in: 0...(Self.fillerLines.count - 1))
            let line = Self.fillerLineBytes[index]
            // Closed loop on the realised ratio rather than a fixed probability: the corpus lines
            // already contain colons of their own, and how many depends on which lines got picked,
            // so the only way to land on the target is to measure and correct as we go.
            if let target = profile.colonByteFrequency, !out.isEmpty,
               Double(colons) / Double(out.count) < target {
                out.append(contentsOf: line)
                out.append(contentsOf: Self.colonSuffix)
                colons += Self.fillerLineColons[index] + 1
            } else {
                out.append(contentsOf: line)
                out.append(UInt8(ascii: "\r"))
                colons += Self.fillerLineColons[index]
            }
        }
        // The corpus is ASCII, so cutting at a byte boundary cannot split a character.
        if out.count > bytes { out.removeLast(out.count - bytes) }
        // `String(decoding:)` rather than the failable initializer the rule prefers: the buffer is
        // built only from the ASCII corpus above, so there is no invalid sequence to report, and a
        // failable call here would add an error path that cannot be reached.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: out, as: UTF8.self)
    }
}
