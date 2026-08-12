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

extension ParserBuildSteps {

    /// The signatures a SwiftDriver build uses for the sections that matter to `SwiftCompilerParser`.
    ///
    /// Xcode 12 moved Swift compilation behind `swift-driver`, and the sections changed shape with it.
    /// `DetailStepType` does not recognise these - it knows the older `CompileSwift ` prefix - so they
    /// arrive as `.other` and would otherwise never be offered to the swiftc-times parser at all.
    ///
    /// Three signatures, because the flag and the output are in different ones:
    ///
    /// - `SwiftDriver …` carries `-debug-time-*` in its `commandDetailDesc`, and its own text is empty.
    /// - `SwiftCompile …` holds the per-function timing text, and carries no flag.
    /// - `SwiftEmitModule …` also holds timing text for the module's own work.
    ///
    /// Registering all three is what lets the flag found in one vouch for the text in the others. The
    /// target they share is the scope - see `addLogSection(_:targetKey:)`.
    private static let swiftDriverPrefixes = [
        Prefix("SwiftDriver "),
        Prefix("SwiftCompile "),
        Prefix("SwiftEmitModule ")
    ]

    /// Whether this section is worth offering to `SwiftCompilerParser`.
    ///
    /// Deliberately cheap and deliberately generous: it matches on the signature alone and does not
    /// look at the text, because looking would mean building it. Everything that decides whether the
    /// text is actually wanted happens later, after the flag scan - a section registered here that
    /// holds nothing costs one array slot.
    static func mayHoldSwiftcTimes(step: BuildStep, section: IDEActivityLogSection) -> Bool {
        if step.detailStepType == .swiftCompilation {
            return true
        }
        // Only `.other` reaches the prefix test. The recognised detail types are the older layout,
        // where `.swiftCompilation` above is the whole story, and testing them again would be dead work
        // on every C compile and link step in the log.
        guard step.detailStepType == .other else {
            return false
        }
        // Every step in the log that is not a Swift compile reaches this line - links, C compiles,
        // script phases, copies - so it has to reject them without doing prefix work. All three
        // signatures start with `Swift`, and almost nothing else does, so one prefix test rejects
        // the whole rest of the log and only its survivors pay for the three specific ones.
        guard Self.swiftPrefix ~= section.signature else {
            return false
        }
        return swiftDriverPrefixes.contains { $0 ~= section.signature }
    }

    private static let swiftPrefix = Prefix("Swift")

    /// Parses the registered sections' times and hangs them on the tree.
    ///
    /// Two passes over the log by construction: a target's flag verdict is only known once its
    /// `SwiftDriver` section has been seen, and sections within a target arrive in no guaranteed order,
    /// so nothing can be attached while the tree is still being built. The pass is over `BuildStep`
    /// values that are already resident, not over section text - the text is released inside
    /// `SwiftCompilerParser.parse()` before this walk starts.
    func decorateWithSwiftcTimes(_ mainStep: BuildStep) -> BuildStep {
        swiftCompilerParser.parse()
        guard swiftCompilerParser.hasFunctionTimes() || swiftCompilerParser.hasTypeChecks() else {
            return mainStep
        }
        var mutableMainStep = mainStep
        mutableMainStep.subSteps = mainStep.subSteps.map { subStep -> BuildStep in
            var mutableTargetStep = subStep
            mutableTargetStep.subSteps = addSwiftcTimesSteps(mutableTargetStep.subSteps)
            return mutableTargetStep
        }
        return mutableMainStep
    }

    /// Attaches whatever times were found for this step's file.
    func attachSwiftcTimes(to step: BuildStep) -> BuildStep {
        var step = step
        if swiftCompilerParser.hasFunctionTimes() {
            step.swiftFunctionTimes = swiftCompilerParser.findFunctionTimesForFilePath(step.documentURL)
        }
        if swiftCompilerParser.hasTypeChecks() {
            step.swiftTypeCheckTimes = swiftCompilerParser.findTypeChecksForFilePath(step.documentURL)
        }
        return step
    }

    func addSwiftcTimesSteps(_ subSteps: [BuildStep]) -> [BuildStep] {
        return subSteps.map { subStep -> BuildStep in
            switch subStep.detailStepType {
            case .swiftCompilation:
                var mutableSubStep = attachSwiftcTimes(to: subStep)
                if mutableSubStep.subSteps.count > 0 {
                     mutableSubStep.subSteps = addSwiftcTimesSteps(subStep.subSteps)
                }
                return mutableSubStep
            case .other:
                // The SwiftDriver layout: `SwiftCompile` steps are `.other`, and the ones that name a
                // file are where times attach. A non-leaf is a batch, so recurse instead.
                var mutableSubStep = subStep
                if subStep.subSteps.isEmpty == false {
                    mutableSubStep.subSteps = addSwiftcTimesSteps(subStep.subSteps)
                } else if subStep.documentURL.isEmpty == false {
                    mutableSubStep = attachSwiftcTimes(to: mutableSubStep)
                }
                return mutableSubStep
            case .swiftAggregatedCompilation:
                var mutableSubStep = subStep
                mutableSubStep.subSteps = addSwiftcTimesSteps(subStep.subSteps)
                return mutableSubStep
            default:
                return subStep
            }
        }
    }

}
