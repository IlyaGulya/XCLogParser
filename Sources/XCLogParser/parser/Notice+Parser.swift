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

/// Functions to parser Notices from `IDELogSection` and `IDELogMessage`
extension Notice {

    /// Parses an `IDEActivityLogSection` looking for Warnings, Errors and Notes in its `IDEActivityLogMessage`.
    /// Uses the `categoryIdent` of `IDEActivityLogMessage` to categorize them.
    /// For CLANG warnings, it parses the `IDEActivityLogSection` text property looking for a *-W-warning-name* pattern
    /// - parameter logSection: An `IDEActivityLogSection`
    /// - parameter forType: The `DetailStepType` of the logSection
    /// - parameter truncLargeIssues: If true, if a task have more than 100 `Notice`, will be truncated to 100
    /// - returns: An Array of `Notice`
    public static func parseFromLogSection(_ logSection: IDEActivityLogSection,
                                           forType type: DetailStepType,
                                           truncLargeIssues: Bool)
        -> [Notice] {
        var logSection = logSection
        if truncLargeIssues && logSection.messages.count > 100 {
            logSection = self.logSectionWithTruncatedIssues(logSection: logSection)
        }
        // we look for clangWarnings parsing the text of the logSection
        let clangWarningsFlags = self.parseClangWarningFlags(text: logSection.text)
        let clangWarnings = self.parseClangWarnings(clangFlags: clangWarningsFlags, logSection: logSection)

        // Remove the messages that were categorized as clangWarnings
        let remainingLogMessages = logSection.messages.filter { message in
            return clangWarnings.contains { $0.title == message.title } == false
        }
        // parse details for Swift issues
        let swiftErrorDetails = parseSwiftIssuesDetailsByLocation(logSection.text)
        // we look for analyzer warnings, swift warnings, notes and errors
        return clangWarnings + remainingLogMessages.compactMap { message -> [Notice]? in
            if let resultMessage = message as? IDEActivityLogAnalyzerResultMessage {
                return resultMessage.subMessages.compactMap {
                    if let stepMessage = $0 as? IDEActivityLogAnalyzerEventStepMessage {
                        return Notice(withType: .analyzerWarning, logMessage: stepMessage)
                    }
                    return nil
                }
            }
            // Special case, Interface builder warning can only be spotted by checking the whole text of the
            // log section
            let noticeTypeTitle = message.categoryIdent.isEmpty ? logSection.text : message.categoryIdent
            if var notice = Notice(withType: NoticeType.fromTitle(noticeTypeTitle),
                                   logMessage: message,
                                   detail: logSection.text) {
                // Add the right details to Swift errors
                if notice.type == NoticeType.swiftError || notice.type == .swiftWarning {
                    // Special case, if Swiftc fails for a whole module,
                    // we don't have location and the detail already has
                    // enough information
                    let noticeDetail = notice.detail ?? ""
                    if noticeDetail.starts(with: "error:") == false {
                        var errorLocation = notice.documentURL.replacingOccurrences(of: "file://", with: "")
                        errorLocation += ":\(notice.startingLineNumber):\(notice.startingColumnNumber):"
                        // do not report error in a file that it does not belong to (we'll ended
                        // up having duplicated errors)
                        if !logSection.location.documentURLString.isEmpty
                            && logSection.location.documentURLString != notice.documentURL {
                            return nil
                        }
                        notice = notice.with(detail: swiftErrorDetails[errorLocation])
                    }
                }

                // Handle special cases

                if isDeprecatedWarning(type: notice.type, text: notice.title, clangFlags: notice.clangFlag) {
                    return [notice.with(type: .deprecatedWarning)]
                }
                // Ld command errors
                if notice.type == .error && type == .linker {
                    return [notice.with(type: .linkerError)]
                }
                // Build phase's script errors
                if notice.type == .scriptPhaseError {
                    // Decorate script phase error with the signature that contains the name of the
                    // phase and the target
                    return [notice.with(detail: "\(notice.detail ?? "") \(logSection.signature)")]
                }
                return [notice]
            }
            return nil
        }.flatMap { $0 }
    }

    /// Xcode reports the details of Swift errors and warnings as a mixed text with all the errors in a
    /// compilation unit in the same Text. This functions parses.
    /// - parameter text: The LogSection.text with the error details
    /// - returns: A Dictionary where the keys are the error location in the form pathToFile:line:column:
    /// and the values are the error details for that location
    public static func parseSwiftIssuesDetailsByLocation(_ text: String) -> [String: String] {
        // This was the hottest function in the whole parse - time profiling attributed a third of
        // all samples to it. The previous implementation made up to four passes over the same bytes:
        // two `contains` scans to decide whether to bail out, a `split` that materialised every line
        // as a `Substring`, a `contains` per line, and a `range(of:)` on each matching line.
        //
        // It is now a single forward pass over the UTF-8 bytes. Lines are delimited by locating "\r"
        // byte-wise, and the marker search happens in the same visit, so each byte is inspected once
        // (plus the short backtrack inherent in substring matching). Strings are only materialised for
        // lines that actually belong to a diagnostic, which on real logs is a small fraction of the
        // text - the bail-out win of the previous version is preserved implicitly, without needing a
        // separate scan to decide it.
        //
        // Byte-wise search is behaviour-preserving *here*, unlike in the `CaseFolding` matchers, for a
        // reason specific to this function: both markers (": error:" / ": warning:") are pure ASCII and
        // end in ":". A combining mark following the marker fuses into the ":" cluster and would defeat
        // `String.contains`, but the captured key is `detail[...lowerBound]` - everything up to the
        // marker's *start* - so such an input differs only in whether a line is treated as a
        // diagnostic. That is a genuine behaviour difference, so it is preserved: see
        // `clusterSafeMarkerRange`, which rejects a match fused to a following combining scalar.
        //
        // The bytes are reached through `withContiguousStorageIfAvailable` rather than `withCString`.
        // An earlier version used the latter and derived the length by scanning to the first NUL, which
        // silently truncated the text at an embedded NUL byte and dropped every diagnostic after it -
        // section text really can contain them, which is why `LogLoaderTests` and `LexerTests` have
        // tests named for preserving them. A differential sweep against the original Foundation
        // implementation failed on 3,678 generated inputs, every one of them containing a NUL.
        if let result = text.utf8.withContiguousStorageIfAvailable({ bytes in
            parseSwiftIssues(bytes: bytes)
        }) {
            return result
        }
        // Non-contiguous UTF-8 (a lazily-bridged NSString): make it contiguous and retry.
        var contiguous = text
        contiguous.makeContiguousUTF8()
        return contiguous.utf8.withContiguousStorageIfAvailable { bytes in
            parseSwiftIssues(bytes: bytes)
        } ?? [:]
    }

    /// Parses the text of a IDELogSection looking for the pattern [-Wwarning-type]
    /// that means there was a clang warning.
    /// - parameter text: IDELogSection text property
    /// - returns: A list of clang warning flags found in the text, like -Wunused-function
    private static func parseClangWarningFlags(text: String) -> [String]? {
        if let fast = asciiClangWarningFlags(text: text) {
            return fast
        }
        guard let clangWarningRegexp = Notice.clangWarningRegexp else {
            return nil
        }
        let range = NSRange(location: 0, length: text.utf16.count)
        let matches = clangWarningRegexp.matches(in: text, options: .reportCompletion, range: range)
        return matches.map { result -> String in
            String(text.substring(result.range))
        }
    }

    private static func parseClangWarnings(clangFlags: [String]?, logSection: IDEActivityLogSection) -> [Notice] {
        guard let clangFlags = clangFlags else {
            return [Notice]()
        }
        return zip(logSection.messages, clangFlags)
            .compactMap { (message, warningFlag) -> Notice? in
                // If the warning is treated as error, we marked the issue as error
                let type: NoticeType = warningFlag.contains("-Werror") ? .clangError : .clangWarning
                let notice = Notice(withType: type, logMessage: message, clangFlag: warningFlag)

                if let notice = notice,
                    isDeprecatedWarning(type: type, text: notice.title, clangFlags: warningFlag) {
                    // Fixes a bug where Xcode logs add more than one message to report one
                    // deprecation warning. Only one has the right documentURL
                    if notice.documentURL != logSection.location.documentURLString {
                        return nil
                    }
                    return notice.with(type: .deprecatedWarning)
                }
                return notice
        }
    }

    private static let deprecatedFlagNeedle = ExactNeedle("-Wdeprecated")

    /// The deprecation phrases, in the original order. `deprecated` is the byte
    /// every one of them shares, which is what makes the pre-check below sound.
    private static let deprecatedNeedles = [
        ExactNeedle(" deprecated:"),
        ExactNeedle("was deprecated in"),
        ExactNeedle("has been deprecated"),
        ExactNeedle("is deprecated")
    ]

    /// The substring common to all four phrases above.
    private static let deprecatedSubstringNeedle = ExactNeedle("deprecated")

    private static func isDeprecatedWarning(type: NoticeType, text: String, clangFlags: String?) -> Bool {
        // Mark clang deprecated flags (https://clang.llvm.org/docs/DiagnosticsReference.html)
        if let clangFlags = clangFlags, deprecatedFlagNeedle.matches(clangFlags) {
            return true
        }
        // Support for Swift and ObjC code marked as deprecated
        if type == .swiftError || type == .swiftWarning || type == .projectWarning || type == .clangWarning
            || type == .note {
            // Every phrase contains "deprecated", so a single scan for it rules out
            // all four at once. Almost no diagnostic mentions deprecation, so this
            // replaces four whole-string searches with one on the common path.

            guard deprecatedSubstringNeedle.matches(text) else {
                return false
            }
            return deprecatedNeedles.contains { $0.matches(text) }
        }
        return false
    }

    private static func logSectionWithTruncatedIssues(logSection: IDEActivityLogSection) -> IDEActivityLogSection {
        let issuesKept = min(99, logSection.messages.count)
        var truncatedMessages = Array(logSection.messages[0..<issuesKept])
        truncatedMessages.append(getTruncatedIssuesWarning(logSection: logSection, issuesKept: issuesKept))
        return logSection.with(messages: truncatedMessages)
    }

    private static func getTruncatedIssuesWarning(logSection: IDEActivityLogSection, issuesKept: Int)
    -> IDEActivityLogMessage {
        let title = "Warning: \(logSection.messages.count - issuesKept) issues were truncated"
        return IDEActivityLogMessage(title: title,
                                     shortTitle: "",
                                     timeEmitted: 0,
                                     rangeEndInSectionText: 0,
                                     rangeStartInSectionText: 0,
                                     subMessages: [],
                                     severity: 0,
                                     type: "",
                                     location: DVTDocumentLocation(documentURLString: "", timestamp: 0),
                                     categoryIdent: "Warning",
                                     secondaryLocations: [],
                                     additionalDescription: "")
    }
}
