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
import XCLogParser

/// A parser path that a given log may or may not exercise at all.
///
/// # Why the harness reports this
///
/// A benchmark that silently covers less than the reader assumes produces a false negative dressed as a
/// pass: a whole-log diff over a change touching one of these paths reports "identical", and identical
/// reads as verified. The harness already refuses to report a footprint it cannot falsify and a peak RSS
/// it cannot attribute; a code path that never ran is the same class of thing, and gets the same
/// treatment - named in the output rather than omitted from it.
enum ConditionalPath: String, CaseIterable {
    case wholeModuleSwiftSteps
    case swiftcTimes

    /// The library function that does not run when this path is absent.
    var function: String {
        switch self {
        case .wholeModuleSwiftSteps: return "assignNoticesFrom"
        case .swiftcTimes: return "addSwiftcTimesSteps"
        }
    }

    /// What a log needs for this path to be entered.
    var requirement: String {
        switch self {
        case .wholeModuleSwiftSteps: return "a whole-module build"
        case .swiftcTimes: return "swiftc timing flags (-debug-time-function-bodies)"
        }
    }
}

/// Which conditional paths a log actually exercises.
///
/// Determined by evaluating the library's own gates through public API rather than by instrumenting the
/// library: both functions are `private`, and adding a counter inside them to satisfy the benchmark would
/// put measurement scaffolding in shipping code. The gates are the honest thing to check anyway - a path
/// whose gate is closed cannot have run.
struct PathCoverage {
    private var executed: Set<ConditionalPath> = []

    func didExecute(_ path: ConditionalPath) -> Bool {
        executed.contains(path)
    }

    var unexecuted: [ConditionalPath] {
        ConditionalPath.allCases.filter { executed.contains($0) == false }
    }

    /// Evaluates every conditional path against a parsed log.
    ///
    /// Runs after the measured stages and is not itself timed: it re-walks the section tree, which would
    /// otherwise show up as parser cost that the shipped CLI does not pay.
    /// The flags `decorateWithSwiftcTimes`'s guard ultimately tests for.
    ///
    /// Checked as literals rather than by driving `SwiftCompilerParser`, whose initializer is internal.
    /// The alternative was to widen the library's API so the benchmark could construct one, and a
    /// measurement tool is not a good reason to make a type publicly constructible. These two strings are
    /// the whole gate: `SwiftCompilerFunctionTimeOptionParser` and `SwiftCompilerTypeCheckOptionParser`
    /// each look for exactly one of them in a section's `commandDetailDesc`.
    private static let swiftcTimingFlags = ["-debug-time-function-bodies",
                                            "-debug-time-expression-type-checking"]

    static func detect(activityLog: IDEActivityLog) -> PathCoverage {
        var coverage = PathCoverage()

        // Iterative rather than recursive: these trees reach tens of thousands of sections on a large
        // log, and the recursive walk is a stack overflow waiting for a big enough project.
        var pending = [activityLog.mainSection]
        while let section = pending.popLast() {
            if isWholeModuleCompile(section) {
                coverage.executed.insert(.wholeModuleSwiftSteps)
            }
            if swiftcTimingFlags.contains(where: section.commandDetailDesc.contains) {
                coverage.executed.insert(.swiftcTimes)
            }
            // Both found: nothing further in the tree can change the answer.
            if coverage.executed.count == ConditionalPath.allCases.count {
                return coverage
            }
            pending.append(contentsOf: section.subSections)
        }

        return coverage
    }

    /// Whether this section is a whole-module Swift compile, i.e. the case where
    /// `getSwiftIndividualSteps` returns steps and so `assignNoticesFrom` runs.
    ///
    /// The same two conditions that function applies, in the same order: it bails on a
    /// `CompileSwift <mode> <arch> <file>.swift` command because that is a per-file compile, and
    /// otherwise needs at least one Swift file named in the command to have anything to assign notices to.
    private static func isWholeModuleCompile(_ section: IDEActivityLogSection) -> Bool {
        let perFile = #"^CompileSwift\s\w+\s\w+\s.+\.swift\s"#
        guard section.commandDetailDesc.range(of: perFile, options: .regularExpression) == nil else {
            return false
        }
        return section.commandDetailDesc.range(of: #"\s([^\s]+\.swift)"#,
                                               options: .regularExpression) != nil
    }
}
