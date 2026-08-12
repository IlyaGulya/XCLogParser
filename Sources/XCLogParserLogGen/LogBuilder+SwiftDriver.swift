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

/// The SwiftDriver section layout, as Xcode 12 and later emit it.
///
/// The older layout is one section per file, carrying both the command and the output. This one splits
/// them across siblings that share a target:
///
/// - `SwiftDriver -- …swift-frontend… -Xfrontend -debug-time-function-bodies …` — the flags are here,
///   in a long `swift-frontend` invocation, and this section's own `text` is **empty**.
/// - `SwiftCompile normal arm64 <file>` — the per-function timing output is here, and there is no flag
///   anywhere in its command.
/// - `SwiftEmitModule normal arm64 Emitting\ module\ for\ <target>` — the module's own timing output.
///
/// All three carry `(in target 'X' from project 'Y')`, which is the only thing tying the flag to the
/// output. The signatures and the escaped-space spelling are copied from a real Xcode 26 log rather
/// than invented; see `Benchmarks/Profiles/README.md`.
extension LogBuilder {

    /// Builds every target, each wrapped in the `Build target` section the parser groups by.
    ///
    /// `sectionCount` counts the compile sections, as it does on the older layout, so a profile means
    /// the same thing on both. The `SwiftDriver` and `SwiftEmitModule` sections are per target and
    /// come on top of it, and the report states them separately rather than folding them in.
    mutating func makeSwiftDriverTargets(layout: Profile.SwiftDriverLayout) -> [Section] {
        let targetCount = max(1, profile.targetCount)
        let flagged = Self.flaggedTargets(count: targetCount, share: layout.flaggedTargetShare)

        // Files dealt out round-robin, so every target gets a comparable share rather than the last
        // one taking a remainder that skews its text volume.
        var filesByTarget: [[Int]] = Array(repeating: [], count: targetCount)
        for index in 0..<profile.sectionCount {
            filesByTarget[index % targetCount].append(index)
        }

        var wrapped: [Section] = []
        wrapped.reserveCapacity(targetCount)
        for targetIndex in 0..<targetCount {
            let target = swiftDriverTargetName(targetIndex)
            let sections = makeSwiftDriverTarget(target: target,
                                                 fileIndices: filesByTarget[targetIndex],
                                                 isFlagged: flagged.contains(targetIndex),
                                                 layout: layout)
            wrapped.append(Section(
                domainType: "com.apple.dt.IDE.BuildLogSection",
                title: "Build target \(target)",
                signature: "Build target \(target)",
                text: "",
                documentURL: "",
                commandDetailDesc: "",
                notices: [],
                subSections: sections
            ))
            stats.intermediateSections += 1
        }
        return wrapped
    }

    /// Distinct target names even at `targetCount: 1`, since the flag scope is the target and two
    /// targets sharing a name would be one scope.
    private func swiftDriverTargetName(_ index: Int) -> String {
        return "Target\(index)"
    }

    /// Builds one target's worth of sections in the SwiftDriver layout.
    ///
    /// Returns the whole group rather than one section per file, because the arrangement *is* the
    /// point: a `SwiftDriver` section holding the flag and no text, alongside the `SwiftCompile`
    /// sections holding text and no flag.
    mutating func makeSwiftDriverTarget(target: String,
                                        fileIndices: [Int],
                                        isFlagged: Bool,
                                        layout: Profile.SwiftDriverLayout) -> [Section] {
        var sections: [Section] = []
        sections.reserveCapacity(fileIndices.count + 2)

        sections.append(makeSwiftDriverSection(target: target, isFlagged: isFlagged))

        for index in fileIndices {
            sections.append(makeSwiftCompileSection(index: index,
                                                    target: target,
                                                    isFlagged: isFlagged,
                                                    layout: layout))
        }

        sections.append(makeSwiftEmitModuleSection(target: target,
                                                   isFlagged: isFlagged,
                                                   layout: layout))
        return sections
    }

    /// The section that carries the flags and no text.
    ///
    /// Its `text` is empty on purpose, and that emptiness is the whole difficulty of the layout: a
    /// parser looking for timing output in the section whose command asked for it finds nothing here.
    private mutating func makeSwiftDriverSection(target: String, isFlagged: Bool) -> Section {
        let command = swiftDriverCommand(target: target, isFlagged: isFlagged)
        let scoped = "\(command) (in target '\(target)' from project 'GeneratedApp')"
        stats.swiftDriverSections += 1
        if isFlagged { stats.flaggedTargets += 1 }
        return Section(
            domainType: "com.apple.dt.IDE.BuildLogSection",
            title: "Compile Swift source files",
            signature: scoped,
            text: "",
            documentURL: "",
            commandDetailDesc: scoped,
            notices: []
        )
    }

    /// One file's compile section: timing text, and no flag in its command.
    private mutating func makeSwiftCompileSection(index: Int,
                                                  target: String,
                                                  isFlagged: Bool,
                                                  layout: Profile.SwiftDriverLayout) -> Section {
        let file = "/project/Sources/Module\(index % 200)/File\(index).swift"
        let documentURL = "file://\(file)"
        // The escaped space is how Xcode spells this, and `getSwiftIndividualSteps` relies on the
        // command's shape, so it is copied rather than tidied.
        let command = "SwiftCompile normal arm64 Compiling\\ File\(index).swift \(file)"
        let scoped = "\(command) (in target '\(target)' from project 'GeneratedApp')"

        let wantsText = isFlagged || layout.decoyTimingText
        let text = wantsText
            ? timingText(file: file, lines: layout.timingLinesPerFile, isFlagged: isFlagged)
            : ""

        stats.sectionCount += 1
        stats.sectionTextBytes += text.utf8.count
        stats.colonBytes += Self.colonCount(in: text)

        return Section(
            domainType: "com.apple.dt.IDE.BuildLogSection",
            title: "Compile \(file)",
            signature: scoped,
            text: text,
            documentURL: documentURL,
            commandDetailDesc: scoped,
            notices: []
        )
    }

    /// The module-level section, which also holds timing output and also carries no flag.
    private mutating func makeSwiftEmitModuleSection(target: String,
                                                     isFlagged: Bool,
                                                     layout: Profile.SwiftDriverLayout) -> Section {
        let file = "/project/Sources/\(target)/\(target)Module.swift"
        let command = "SwiftEmitModule normal arm64 Emitting\\ module\\ for\\ \(target)"
        let scoped = "\(command) (in target '\(target)' from project 'GeneratedApp')"

        let wantsText = isFlagged || layout.decoyTimingText
        // Fewer lines than a compile section: a module emit reports its own work, not every file's.
        let lines = max(1, layout.timingLinesPerFile / 4)
        let text = wantsText ? timingText(file: file, lines: lines, isFlagged: isFlagged) : ""

        // Not counted in `sectionCount`: that field means "compile sections" on the older layout, and
        // a profile's `sectionCount` should mean the same thing on both. This one is reported
        // separately.
        stats.sectionTextBytes += text.utf8.count
        stats.colonBytes += Self.colonCount(in: text)
        stats.swiftEmitModuleSections += 1

        return Section(
            domainType: "com.apple.dt.IDE.BuildLogSection",
            title: "Emit Swift module (arm64)",
            signature: scoped,
            text: text,
            documentURL: "file://\(file)",
            commandDetailDesc: scoped,
            notices: []
        )
    }

    /// The `swift-frontend` invocation, with the timing flags when the target is flagged.
    ///
    /// Long and full of paths because the real one is, and the flag scan reads this string on every
    /// registered section - a short stand-in would make that scan look cheaper than it is.
    private func swiftDriverCommand(target: String, isFlagged: Bool) -> String {
        let flags = isFlagged
            ? " -Xfrontend -debug-time-function-bodies -Xfrontend -debug-time-expression-type-checking"
            : ""
        return "SwiftDriver -- /Applications/Xcode.app/Contents/Developer/Toolchains/"
            + "XcodeDefault.xctoolchain/usr/bin/swift-frontend -module-name \(target) "
            + "-Onone -enforce-exclusivity=checked @/project/Build/Intermediates.noindex/"
            + "\(target).build/Debug-iphonesimulator/\(target).build/Objects-normal/arm64/"
            + "\(target).SwiftFileList -DDEBUG\(flags) -target arm64-apple-ios15.0-simulator"
    }

    /// `swiftc`'s timing output: `<ms>\t<path>:<line>:<col>\t<signature>` for function bodies, and the
    /// same without the trailing field for expression type checking.
    ///
    /// Lines are joined with `\r`, because that is what the parser splits on. The two kinds are
    /// interleaved in one text, the way `swiftc` emits them when both flags are passed, so a parser
    /// that split the text once per kind rather than once in total is doing twice the work.
    ///
    /// Unflagged targets get the same shape, which is the point of `decoyTimingText`: nothing about
    /// these bytes says whether they should be parsed. Only the target's flag does.
    private mutating func timingText(file: String, lines: Int, isFlagged: Bool) -> String {
        guard lines > 0 else { return "" }
        var out: [String] = []
        out.reserveCapacity(lines)
        for _ in 0..<lines {
            let line = random.int(in: 1...4000)
            let column = random.int(in: 1...120)
            let milliseconds = Double(random.int(in: 1...99_999)) / 100
            let duration = String(format: "%.2f", milliseconds)
            if random.unitDouble() < 0.9 {
                let name = Self.functionSignatures[
                    (line + column) % Self.functionSignatures.count]
                out.append("\(duration)ms\t\(file):\(line):\(column)\t\(name)")
                if isFlagged { stats.functionTimingLines += 1 }
            } else {
                out.append("\(duration)ms\t\(file):\(line):\(column)")
                if isFlagged { stats.typeCheckTimingLines += 1 }
            }
        }
        return out.joined(separator: "\r")
    }

    /// Which targets carry the flags.
    ///
    /// Assigned by index rather than by a coin flip per target, so a profile asking for half of six
    /// targets gets exactly three - a sampled share would land near it and make the fixture's
    /// expected counts approximate.
    static func flaggedTargets(count: Int, share: Double) -> Set<Int> {
        let flagged = Int((Double(count) * share).rounded())
        return Set(0..<max(0, min(count, flagged)))
    }
}
