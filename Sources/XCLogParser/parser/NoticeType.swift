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

/// The type of a Notice
public enum NoticeType: String, Codable {

    /// Notes
    case note

    /// A warning thrown by the Swift compiler
    case swiftWarning

    /// A warning thrown by the C compiler
    case clangWarning

    /// A warning at a project level. For instance:
    /// "Warning Swift 3 mode has been deprecated and will be removed in a later version of Xcode"
    case projectWarning

    /// An error in a non-compilation step. For instance creating a directory or running a shell script phase
    case error

    /// An error thrown by the Swift compiler
    case swiftError

    /// An error thrown by the C compiler
    case clangError

    /// A warning returned by Xcode static analyzer
    case analyzerWarning

    /// A warning inside an Interface Builder file
    case interfaceBuilderWarning

    /// A warning about the usage of a deprecated API
    case deprecatedWarning

    /// Error thrown by the Linker
    case linkerError

    /// Error loading Swift Packages
    case packageLoadingError

    /// Error running a Build Phase's script
    case scriptPhaseError

    /// Failed command error (e.g. ValidateEmbeddedBinary, CodeSign)
    case failedCommandError

    /// The `Prefix`/`Suffix`/`Contains` matchers used by `fromTitle`, built once.
    ///
    /// Do not inline these back into the `switch` as `case Prefix("Lexical"):`. That reads well but
    /// constructs the struct *on every call*, and each initializer lowercases its pattern into a
    /// fresh `[UInt8]`. Since every pattern is a string literal that never changes, inlining them
    /// made `CaseFolding.asciiBytes` one of the largest sources of array growth in the parse.
    ///
    /// Hoisting them changes nothing about matching: `~=` still does the comparison against values
    /// identical to the ones the inline expressions produced.
    private enum Patterns {
        static let lexical = Prefix("Lexical")
        static let semanticIssue = Suffix("Semantic Issue")
        static let deprecations = Suffix("Deprecations")
        static let error = Suffix("Error")
        static let notice = Suffix("Notice")
        static let ibtoolWarnings = Prefix("/* com.apple.ibtool.document.warnings */")
        static let phaseScriptExecution = Contains("Command PhaseScriptExecution")
        static let swiftc = Prefix("error: Swiftc")
        static let nonzeroExit = Suffix("failed with a nonzero exit code")
    }

    // swiftlint:disable:next cyclomatic_complexity
    public static func fromTitle(_ title: String) -> NoticeType? {
        switch title {
        case "Swift Compiler Warning":
            return .swiftWarning
        case "Notice":
            return .note
        case "Swift Compiler Error":
            return .swiftError
        case Patterns.lexical, Patterns.semanticIssue, "Parse Issue", "Uncategorized":
            return .clangError
        case Patterns.deprecations:
            return .deprecatedWarning
        case "Warning", "Apple Mach-O Linker Warning", "Target Integrity":
            return .projectWarning
        case Patterns.error:
            return .error
        case Patterns.notice:
            return .note
        case Patterns.ibtoolWarnings:
            return .interfaceBuilderWarning
        case "Package Loading":
            return .packageLoadingError
        case Patterns.phaseScriptExecution:
            return .scriptPhaseError
        case Patterns.swiftc:
            return .swiftError
        case Patterns.nonzeroExit:
            return .failedCommandError
        default:
            return .note
        }
    }
}
