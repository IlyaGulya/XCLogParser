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

extension Array where Element: Hashable {

    func removingDuplicates() -> [Element] {
        var addedDict = [Element: Bool]()
        return filter {
            addedDict.updateValue(true, forKey: $0) == nil
        }
    }

}

/// The three notice buckets a log section's notices are split into.
///
/// This used to be a `[String: [Notice]]` built with a dictionary literal, which allocated once
/// per section and made the caller hash the same three keys back to read the values out. A struct
/// carries the same three arrays with no allocation and no hashing.
struct PartitionedNotices {
    var warnings: [Notice] = []
    var errors: [Notice] = []
    var notes: [Notice] = []
}

extension Array where Element: Notice {

    /// Splits the notices into warnings, errors and notes in a single pass.
    ///
    /// Replaces three `filter` passes that each re-tested 6-7 enum cases per element. A notice's
    /// type puts it in at most one bucket, so one `switch` per element decides it.
    func partitionedByNoticeType() -> PartitionedNotices {
        var result = PartitionedNotices()
        for notice in self {
            switch notice.type {
            case .swiftWarning, .clangWarning, .projectWarning,
                 .analyzerWarning, .interfaceBuilderWarning, .deprecatedWarning:
                result.warnings.append(notice)
            case .swiftError, .error, .clangError, .linkerError,
                 .packageLoadingError, .scriptPhaseError, .failedCommandError:
                result.errors.append(notice)
            case .note:
                result.notes.append(notice)
            }
        }
        return result
    }
}
