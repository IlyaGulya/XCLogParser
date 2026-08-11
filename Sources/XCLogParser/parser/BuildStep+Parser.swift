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

import Foundation

public extension BuildStep {

    /// Flattens a group of swift compilations steps.
    ///
    /// When a Swift module is compiled with `whole module` option
    /// The parsed log looks like:
    /// - CompileSwiftTarget
    ///     - CompileSwift
    ///         - CompileSwift file1.swift
    ///         - CompileSwift file2.swift
    /// This tasks removes the intermediate CompileSwift step and moves the substeps
    /// to the root:
    /// - CompileSwiftTarget
    ///     - CompileSwift file1.swift
    ///     - CompileSwift file2.swift
    /// - Returns: The build step with its swift substeps at the root level, and intermediate CompileSwift step removed.
    func moveSwiftStepsToRoot() -> BuildStep {
        var updatedSubSteps = subSteps
        for (index, subStep) in subSteps.enumerated() {
            if subStep.detailStepType == .swiftCompilation && subStep.subSteps.count > 0 {
                updatedSubSteps.remove(at: index)
                updatedSubSteps.append(contentsOf: subStep.subSteps)
            }
        }
        // Assigning the one field that changes, rather than `with(subSteps:)`, which rebuilds all
        // 32 fields of a 360-byte struct and retains every reference in it. This is called once per
        // detail step, and was one of the largest sources of retains in the parse. The loop above is
        // untouched, including its index-shifting behaviour, so the result is unchanged.
        var updated = self
        updated.subSteps = updatedSubSteps
        return updated
    }

}

extension BuildStep {

    /// Returns a copy with the two compilation-time fields set.
    ///
    /// `with(newCompilationEndTimestamp:andCompilationDuration:)` rebuilds all 32 fields of a
    /// 360-byte struct to write two `Double`s, retaining every reference on the way. Both fields
    /// are already `var`, so one copy and two stores do the same job. A DTrace `swift_retain`
    /// count keyed by caller put `addCompilationTimes` at 249,485 retains on flagged-10x-fleet.
    ///
    /// Internal on purpose: the public `with(...)` builder stays the supported API for clients.
    func settingCompilationTimes(endTimestamp: Double, duration: Double) -> BuildStep {
        var updated = self
        updated.compilationEndTimestamp = endTimestamp
        updated.compilationDuration = duration
        return updated
    }

}
