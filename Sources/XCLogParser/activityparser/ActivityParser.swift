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

/// Parses an xcactivitylog into a Swift representation
/// Used by the Dump command
// swiftlint:disable type_body_length
// swiftlint:disable file_length
public class ActivityParser {

    /// Some IDEActivitlyLog have an extra int at the end
    /// This flag is turn on if is the case, so the parse will take
    /// that into account
    var isCommandLineLog = false

    /// The version of the parsed `IDEActivityLog`.
    /// Used to skip parsing of the `IDEActivityLogSectionAttachment` list on version less than 11.
    var logVersion: Int8?

    /// Reused across the whole parse instead of constructed per attachment.
    ///
    /// `parseAsJson` built a `JSONDecoder()` on every call, and it is called once per section
    /// attachment - 152,920 allocations on the flagged benchmark log came out of that function.
    ///
    /// Safe to store: this class already carries mutable parse state (`isCommandLineLog`,
    /// `logVersion`), so an instance was never usable from more than one thread, and nothing in the
    /// library parses concurrently - the only two call sites each own a fresh `ActivityParser`.
    private let jsonDecoder = JSONDecoder()

    public init() {}

    /// Upper bound on how much a list parser will reserve up front.
    ///
    /// The six list parsers below know their element count before they start, so they can size the
    /// array once instead of letting `append` rediscover it by doubling - which showed up as
    /// `_ArrayBuffer._consumeAndCreateNew` at 12.4% of allocations.
    ///
    /// The count is clamped because it comes straight out of the log file and is not trusted. The
    /// parse loop only fails when it runs out of tokens, i.e. *after* a reservation would already
    /// have happened, so a truncated or hostile log declaring a list of 2^60 elements would try to
    /// allocate before anything noticed. Clamping keeps a bad count to a bounded waste and lets the
    /// existing "unexpected EOF" error do the actual rejecting.
    ///
    /// One million is far above any real list: every element consumes at least one token, and the
    /// largest benchmark log has 1,453,770 tokens in total across the whole file. A legitimate list
    /// that hits this cap still parses correctly - the reservation is only a hint, and `append`
    /// grows past it as before.
    private static let maxReservedListCount = 1_000_000

    /// `count` clamped to something safe to reserve - see `maxReservedListCount`.
    private static func reservation(for count: Int) -> Int {
        min(max(count, 0), maxReservedListCount)
    }

    /// Class names used to dispatch the parsing of a serialized object.
    ///
    /// These are compile-time constants on purpose: they used to be built at runtime with
    /// `String(describing: SomeType.self)`, which allocates on every call and is not
    /// constant-folded. Each value has been verified to be identical to what
    /// `String(describing:)` produces for the corresponding type (a bare, non
    /// module-qualified type name).
    private enum ClassNames {
        static let dvtTextDocumentLocation = "DVTTextDocumentLocation"
        static let dvtDocumentLocation = "DVTDocumentLocation"
        static let xcode3ProjectDocumentLocation = "Xcode3ProjectDocumentLocation"
        static let ideLogDocumentLocation = "IDELogDocumentLocation"
        static let ibDocumentMemberLocation = "IBDocumentMemberLocation"
        static let dvtMemberDocumentLocation = "DVTMemberDocumentLocation"
        static let ideActivityLogMessage = "IDEActivityLogMessage"
        static let ideClangDiagnosticActivityLogMessage = "IDEClangDiagnosticActivityLogMessage"
        static let ideDiagnosticActivityLogMessage = "IDEDiagnosticActivityLogMessage"
        static let ideActivityLogAnalyzerResultMessage = "IDEActivityLogAnalyzerResultMessage"
        static let ideActivityLogAnalyzerControlFlowStepMessage = "IDEActivityLogAnalyzerControlFlowStepMessage"
        static let ideActivityLogAnalyzerEventStepMessage = "IDEActivityLogAnalyzerEventStepMessage"
        static let ideActivityLogActionMessage = "IDEActivityLogActionMessage"
        static let ideActivityLogSectionAttachment = "IDEFoundation.IDEActivityLogSectionAttachment"
        static let ideActivityLogSection = "IDEActivityLogSection"
        static let ideCommandLineBuildLog = "IDECommandLineBuildLog"
        static let ideActivityLogMajorGroupSection = "IDEActivityLogMajorGroupSection"
        static let ideActivityLogCommandInvocationSection = "IDEActivityLogCommandInvocationSection"
        static let ideActivityLogUnitTestSection = "IDEActivityLogUnitTestSection"
        static let dbgConsoleLog = "DBGConsoleLog"
        static let ideConsoleItem = "IDEConsoleItem"
        static let ideActivityLogAnalyzerControlFlowStepEdge = "IDEActivityLogAnalyzerControlFlowStepEdge"
        static let ibMemberID = "IBMemberID"
    }

    /// Parses the xcacticitylog argument into a `IDEActivityLog`
    /// - parameter logURL: `URL` of the xcactivitylog
    /// - parameter redacted: If true, the username will be replaced
    /// in the file paths inside the logs for the word `redacted`.
    /// This flag is useful to preserve the privacy of the users.
    /// - parameter withoutBuildSpecificInformation: If true, build specific
    /// information will be removed from the logs (for example `bolnckhlbzxpxoeyfujluasoupft`
    /// will be removed from  `DerivedData/Product-bolnckhlbzxpxoeyfujluasoupft/Build`).
    /// This flag is useful for grouping logs by its content.
    /// - returns: An instance of `IDEActivityLog1
    /// - throws: An Error if the file is not valid.
    public func parseActivityLogInURL(_ logURL: URL,
                                      redacted: Bool,
                                      withoutBuildSpecificInformation: Bool) throws -> IDEActivityLog {
        let tokens = try getTokens(logURL, redacted: redacted,
                                   withoutBuildSpecificInformation: withoutBuildSpecificInformation)
        return try parseIDEActiviyLogFromTokens(tokens)
    }

    public func parseIDEActiviyLogFromTokens(_ tokens: [Token]) throws -> IDEActivityLog {
        var iterator = tokens.makeIterator()
        let logVersion = Int8(try parseAsInt(token: iterator.next()))
        self.logVersion = logVersion
        return IDEActivityLog(version: logVersion,
                              mainSection: try parseLogSection(iterator: &iterator))
    }

    public func parseDVTTextDocumentLocation(iterator: inout IndexingIterator<[Token]>)
        throws -> DVTTextDocumentLocation {
        return DVTTextDocumentLocation(documentURLString: try parseAsString(token: iterator.next()),
                                       timestamp: try parseAsDouble(token: iterator.next()),
                                       startingLineNumber: try parseAsInt(token: iterator.next()),
                                       startingColumnNumber: try parseAsInt(token: iterator.next()),
                                       endingLineNumber: try parseAsInt(token: iterator.next()),
                                       endingColumnNumber: try parseAsInt(token: iterator.next()),
                                       characterRangeEnd: try parseAsInt(token: iterator.next()),
                                       characterRangeStart: try parseAsInt(token: iterator.next()),
                                       locationEncoding: try parseAsInt(token: iterator.next()))
    }

    public func parseDVTDocumentLocation(iterator: inout IndexingIterator<[Token]>) throws -> DVTDocumentLocation {
        return DVTDocumentLocation(documentURLString: try parseAsString(token: iterator.next()),
                                       timestamp: try parseAsDouble(token: iterator.next()))
    }

    public func parseIDEActivityLogMessage(iterator: inout IndexingIterator<[Token]>) throws -> IDEActivityLogMessage {
        return IDEActivityLogMessage(title: try parseAsString(token: iterator.next()),
                                     shortTitle: try parseAsString(token: iterator.next()),
                                     timeEmitted: try Double(parseAsInt(token: iterator.next())),
                                     rangeEndInSectionText: try parseAsInt(token: iterator.next()),
                                     rangeStartInSectionText: try parseAsInt(token: iterator.next()),
                                     subMessages: try parseMessages(iterator: &iterator),
                                     severity: Int(try parseAsInt(token: iterator.next())),
                                     type: try parseAsString(token: iterator.next()),
                                     location: try parseDocumentLocation(iterator: &iterator),
                                     categoryIdent: try parseAsString(token: iterator.next()),
                                     secondaryLocations: try parseDocumentLocations(iterator: &iterator),
                                     additionalDescription: try parseAsString(token: iterator.next()))
    }

    // swiftlint:disable:next function_body_length
    public func parseIDEActivityLogSection(iterator: inout IndexingIterator<[Token]>) throws -> IDEActivityLogSection {
        let sectionType = Int8(try parseAsInt(token: iterator.next()))
        let domainType = try parseAsString(token: iterator.next())
        let title = try parseAsString(token: iterator.next())
        let signature = try parseAsString(token: iterator.next())
        let timeStartedRecording = try parseAsDouble(token: iterator.next())
        let timeStoppedRecording = try parseAsDouble(token: iterator.next())
        let subSections = try parseIDEActivityLogSections(iterator: &iterator)
        var textToken = iterator.next()
        // On Xcode 27.0+, an integer that most likely represents the ended status
        // appears before text. XCLogParser does not currently model it because
        // there is no use case for exposing it.
        if case .some(.int) = textToken {
            textToken = iterator.next()
        }
        // Not `parseAsString`: that decodes, and section text is 91% of all string-token bytes with
        // most of it never read. `deferredRange` hands the range straight through to the section,
        // which trims and decodes on first access. See `LazyString`.
        let sectionText: IDEActivityLogSection.SectionText
        if let (logBytes, range) = Self.deferredText(in: textToken) {
            sectionText = .range(range, logBytes: logBytes)
        } else {
            sectionText = .decoded(try parseAsString(token: textToken))
        }
        let messages = try parseMessages(iterator: &iterator)
        let wasCancelled = try parseBoolean(token: iterator.next())
        let isQuiet = try parseBoolean(token: iterator.next())
        let wasFetchedFromCache = try parseBoolean(token: iterator.next())
        let nextToken = iterator.next()
        var unknown: Int?
        let subtitle: String
        // On Xcode 26.2+, the unknown integer appears before subtitle
        switch nextToken {
        case let .some(.int(integer)):
            unknown = Int(integer)
            subtitle = try String(parseAsString(token: iterator.next()))
        default:
            subtitle = String(try parseAsString(token: nextToken))
        }
        let location = try parseDocumentLocation(iterator: &iterator)
        let commandDetailDesc = try parseAsString(token: iterator.next())
        let uniqueIdentifier = try parseAsString(token: iterator.next())
        let localizedResultString = try parseAsString(token: iterator.next())
        let xcbuildSignature = try parseAsString(token: iterator.next())
        let attachments = try parseIDEActivityLogSectionAttachments(iterator: &iterator)
        if unknown == nil {
            unknown = isCommandLineLog ? Int(try parseAsInt(token: iterator.next())) : 0
        }

        return IDEActivityLogSection(
            sectionType: sectionType,
            domainType: domainType,
            title: title,
            signature: signature,
            timeStartedRecording: timeStartedRecording,
            timeStoppedRecording: timeStoppedRecording,
            subSections: subSections,
            sectionText: sectionText,
            messages: messages,
            wasCancelled: wasCancelled,
            isQuiet: isQuiet,
            wasFetchedFromCache: wasFetchedFromCache,
            subtitle: subtitle,
            location: location,
            commandDetailDesc: commandDetailDesc,
            uniqueIdentifier: uniqueIdentifier,
            localizedResultString: localizedResultString,
            xcbuildSignature: xcbuildSignature,
            attachments: attachments,
            unknown: unknown ?? 0
        )
    }

    public func parseIDEActivityLogUnitTestSection(iterator: inout IndexingIterator<[Token]>)
        throws -> IDEActivityLogUnitTestSection {
            return IDEActivityLogUnitTestSection(sectionType: Int8(try parseAsInt(token: iterator.next())),
                                         domainType: try parseAsString(token: iterator.next()),
                                         title: try parseAsString(token: iterator.next()),
                                         signature: try parseAsString(token: iterator.next()),
                                         timeStartedRecording: try parseAsDouble(token: iterator.next()),
                                         timeStoppedRecording: try parseAsDouble(token: iterator.next()),
                                         subSections: try parseIDEActivityLogSections(iterator: &iterator),
                                         text: try parseAsString(token: iterator.next()),
                                         messages: try parseMessages(iterator: &iterator),
                                         wasCancelled: try parseBoolean(token: iterator.next()),
                                         isQuiet: try parseBoolean(token: iterator.next()),
                                         wasFetchedFromCache: try parseBoolean(token: iterator.next()),
                                         subtitle: try parseAsString(token: iterator.next()),
                                         location: try parseDocumentLocation(iterator: &iterator),
                                         commandDetailDesc: try parseAsString(token: iterator.next()),
                                         uniqueIdentifier: try parseAsString(token: iterator.next()),
                                         localizedResultString: try parseAsString(token: iterator.next()),
                                         xcbuildSignature: try parseAsString(token: iterator.next()),
                                         attachments: try parseIDEActivityLogSectionAttachments(iterator: &iterator),
                                         unknown: isCommandLineLog ? Int(try parseAsInt(token: iterator.next())) : 0,
                                         testsPassedString: try parseAsString(token: iterator.next()),
                                         durationString: try parseAsString(token: iterator.next()),
                                         summaryString: try parseAsString(token: iterator.next()),
                                         suiteName: try parseAsString(token: iterator.next()),
                                         testName: try parseAsString(token: iterator.next()),
                                         performanceTestOutputString: try parseAsString(token: iterator.next()))
    }

    public func parseDBGConsoleLog(iterator: inout IndexingIterator<[Token]>)
        throws -> DBGConsoleLog {
            return DBGConsoleLog(sectionType: Int8(try parseAsInt(token: iterator.next())),
                                                 domainType: try parseAsString(token: iterator.next()),
                                                 title: try parseAsString(token: iterator.next()),
                                                 signature: try parseAsString(token: iterator.next()),
                                                 timeStartedRecording: try parseAsDouble(token: iterator.next()),
                                                 timeStoppedRecording: try parseAsDouble(token: iterator.next()),
                                                 subSections: try parseIDEActivityLogSections(iterator: &iterator),
                                                 text: try parseAsString(token: iterator.next()),
                                                 messages: try parseMessages(iterator: &iterator),
                                                 wasCancelled: try parseBoolean(token: iterator.next()),
                                                 isQuiet: try parseBoolean(token: iterator.next()),
                                                 wasFetchedFromCache: try parseBoolean(token: iterator.next()),
                                                 subtitle: try parseAsString(token: iterator.next()),
                                                 location: try parseDocumentLocation(iterator: &iterator),
                                                 commandDetailDesc: try parseAsString(token: iterator.next()),
                                                 uniqueIdentifier: try parseAsString(token: iterator.next()),
                                                 localizedResultString: try parseAsString(token: iterator.next()),
                                                 xcbuildSignature: try parseAsString(token: iterator.next()),
                                                 // swiftlint:disable:next line_length
                                                 attachments: try parseIDEActivityLogSectionAttachments(iterator: &iterator),
                                                 // swiftlint:disable:next line_length
                                                 unknown: isCommandLineLog ? Int(try parseAsInt(token: iterator.next())) : 0,
                                                 logConsoleItems: try parseIDEConsoleItems(iterator: &iterator)
                                                 )
    }

    public func parseIDEActivityLogAnalyzerResultMessage(iterator: inout IndexingIterator<[Token]>) throws
        -> IDEActivityLogAnalyzerResultMessage {
        return IDEActivityLogAnalyzerResultMessage(
                                     title: try parseAsString(token: iterator.next()),
                                     shortTitle: try parseAsString(token: iterator.next()),
                                     timeEmitted: try Double(parseAsInt(token: iterator.next())),
                                     rangeEndInSectionText: try parseAsInt(token: iterator.next()),
                                     rangeStartInSectionText: try parseAsInt(token: iterator.next()),
                                     subMessages: try parseMessages(iterator: &iterator),
                                     severity: Int(try parseAsInt(token: iterator.next())),
                                     type: try parseAsString(token: iterator.next()),
                                     location: try parseDocumentLocation(iterator: &iterator),
                                     categoryIdent: try parseAsString(token: iterator.next()),
                                     secondaryLocations: try parseDocumentLocations(iterator: &iterator),
                                     additionalDescription: try parseAsString(token: iterator.next()),
                                     resultType: try parseAsString(token: iterator.next()),
                                     keyEventIndex: try parseAsInt(token: iterator.next()))
    }

    public func parseIDEActivityLogAnalyzerEventStepMessage(iterator: inout IndexingIterator<[Token]>) throws
        -> IDEActivityLogAnalyzerEventStepMessage {
        return IDEActivityLogAnalyzerEventStepMessage(
                                     title: try parseAsString(token: iterator.next()),
                                     shortTitle: try parseAsString(token: iterator.next()),
                                     timeEmitted: try Double(parseAsInt(token: iterator.next())),
                                     rangeEndInSectionText: try parseAsInt(token: iterator.next()),
                                     rangeStartInSectionText: try parseAsInt(token: iterator.next()),
                                     subMessages: try parseMessages(iterator: &iterator),
                                     severity: Int(try parseAsInt(token: iterator.next())),
                                     type: try parseAsString(token: iterator.next()),
                                     location: try parseDocumentLocation(iterator: &iterator),
                                     categoryIdent: try parseAsString(token: iterator.next()),
                                     secondaryLocations: try parseDocumentLocations(iterator: &iterator),
                                     additionalDescription: try parseAsString(token: iterator.next()),
                                     parentIndex: try parseAsInt(token: iterator.next()),
                                     description: try parseAsString(token: iterator.next()),
                                     callDepth: try parseAsInt(token: iterator.next()))
    }

    public func parseIDEActivityLogAnalyzerControlFlowStepMessage(iterator: inout IndexingIterator<[Token]>) throws
        -> IDEActivityLogAnalyzerControlFlowStepMessage {
        return IDEActivityLogAnalyzerControlFlowStepMessage(
                                     title: try parseAsString(token: iterator.next()),
                                     shortTitle: try parseAsString(token: iterator.next()),
                                     timeEmitted: try Double(parseAsInt(token: iterator.next())),
                                     rangeEndInSectionText: try parseAsInt(token: iterator.next()),
                                     rangeStartInSectionText: try parseAsInt(token: iterator.next()),
                                     subMessages: try parseMessages(iterator: &iterator),
                                     severity: Int(try parseAsInt(token: iterator.next())),
                                     type: try parseAsString(token: iterator.next()),
                                     location: try parseDocumentLocation(iterator: &iterator),
                                     categoryIdent: try parseAsString(token: iterator.next()),
                                     secondaryLocations: try parseDocumentLocations(iterator: &iterator),
                                     additionalDescription: try parseAsString(token: iterator.next()),
                                     parentIndex: try parseAsInt(token: iterator.next()),
                                     endLocation: try parseDocumentLocation(iterator: &iterator),
                                     edges: try parseStepEdges(iterator: &iterator))
    }

    public func parseIDEActivityLogAnalyzerControlFlowStepEdge(iterator: inout IndexingIterator<[Token]>) throws
        -> IDEActivityLogAnalyzerControlFlowStepEdge {
        return IDEActivityLogAnalyzerControlFlowStepEdge(
                                     startLocation: try parseDocumentLocation(iterator: &iterator),
                                     endLocation: try parseDocumentLocation(iterator: &iterator))
    }

    public func parseIDEActivityLogActionMessage(iterator: inout IndexingIterator<[Token]>) throws
        -> IDEActivityLogActionMessage {
        return IDEActivityLogActionMessage(
                                     title: try parseAsString(token: iterator.next()),
                                     shortTitle: try parseAsString(token: iterator.next()),
                                     timeEmitted: try Double(parseAsInt(token: iterator.next())),
                                     rangeEndInSectionText: try parseAsInt(token: iterator.next()),
                                     rangeStartInSectionText: try parseAsInt(token: iterator.next()),
                                     subMessages: try parseMessages(iterator: &iterator),
                                     severity: Int(try parseAsInt(token: iterator.next())),
                                     type: try parseAsString(token: iterator.next()),
                                     location: try parseDocumentLocation(iterator: &iterator),
                                     categoryIdent: try parseAsString(token: iterator.next()),
                                     secondaryLocations: try parseDocumentLocations(iterator: &iterator),
                                     additionalDescription: try parseAsString(token: iterator.next()),
                                     action: try parseAsString(token: iterator.next()))
    }

    private func getTokens(_ logURL: URL,
                           redacted: Bool,
                           withoutBuildSpecificInformation: Bool) throws -> [Token] {
        let logLoader = LogLoader()
        var tokens: [Token] = []
        // `loadBytesFromURL`/`tokenize(data:)` rather than the `String` pair: the log is `Data` on disk
        // and the lexer scans that `Data` where it lies. Decoding to a `String` in between cost a full
        // extra copy of the log, and copying into an `[UInt8]` cost another. See
        // `LogLoader.loadBytesFromURL` for the one behaviour difference, on invalid UTF-8.
        #if os(Linux)
        let content = try logLoader.loadBytesFromURL(logURL)
        let lexer = Lexer(filePath: logURL.path)
        tokens = try lexer.tokenize(data: content,
                                        redacted: redacted,
                                        withoutBuildSpecificInformation: withoutBuildSpecificInformation)
        #else
        try autoreleasepool {
            let content = try logLoader.loadBytesFromURL(logURL)
            let lexer = Lexer(filePath: logURL.path)
            tokens = try lexer.tokenize(data: content,
                                            redacted: redacted,
                                            withoutBuildSpecificInformation: withoutBuildSpecificInformation)
        }
        #endif
        return tokens
    }

    private func parseMessages(iterator: inout IndexingIterator<[Token]>) throws -> [IDEActivityLogMessage] {
        guard let listToken = iterator.next() else {
            throw XCLogParserError.parseError("Parsing [IDEActivityLogMessage]")
        }
        switch listToken {
        case .null:
            return []
        case .list(let count):
            var messages = [IDEActivityLogMessage]()
            messages.reserveCapacity(Self.reservation(for: count))
            for _ in 0..<count {
                let message = try parseLogMessage(iterator: &iterator)
                messages.append(message)
            }
            return messages
        default:
            throw XCLogParserError.parseError("Unexpected token parsing array of IDEActivityLogMessage \(listToken)")
        }
    }

    private func parseDocumentLocations(iterator: inout IndexingIterator<[Token]>) throws -> [DVTDocumentLocation] {
        guard let listToken = iterator.next() else {
            throw XCLogParserError.parseError("Unexpected EOF parsing [DocumentLocation]")
        }
        switch listToken {
        case .null:
            return []
        case .list(let count):
            var locations = [DVTDocumentLocation]()
            locations.reserveCapacity(Self.reservation(for: count))
            for _ in 0..<count {
                let location = try parseDocumentLocation(iterator: &iterator)
                locations.append(location)
            }
            return locations
        default:
            throw XCLogParserError.parseError("Unexpected token parsing array of DocumentLocation \(listToken)")
        }
    }

    public func parseDocumentLocation(iterator: inout IndexingIterator<[Token]>) throws -> DVTDocumentLocation {
        let classRefToken = try getClassRefToken(iterator: &iterator)
        if case Token.null = classRefToken {
            return DVTDocumentLocation(documentURLString: "", timestamp: 0.0)
        }
        guard case Token.classNameRef(let className) = classRefToken else {
            throw XCLogParserError.parseError("Unexpected token found parsing DocumentLocation \(classRefToken)")
        }
        switch className {
        case ClassNames.dvtTextDocumentLocation:
            return try parseDVTTextDocumentLocation(iterator: &iterator)
        case ClassNames.dvtDocumentLocation,
             ClassNames.xcode3ProjectDocumentLocation,
             ClassNames.ideLogDocumentLocation:
            return try parseDVTDocumentLocation(iterator: &iterator)
        case ClassNames.ibDocumentMemberLocation:
            return try parseIBDocumentMemberLocation(iterator: &iterator)
        case ClassNames.dvtMemberDocumentLocation:
            return try parseDVTMemberDocumentLocation(iterator: &iterator)
        default:
            throw XCLogParserError.parseError("Unexpected className found parsing DocumentLocation \(className)")
        }
    }

    private func parseLogMessage(iterator: inout IndexingIterator<[Token]>) throws -> IDEActivityLogMessage {
        let classRefToken = try getClassRefToken(iterator: &iterator)
        guard
            case Token.classNameRef(let className) = classRefToken
        else {
            throw XCLogParserError.parseError("Unexpected token found parsing IDEActivityLogMessage \(classRefToken)")
        }
        switch className {
        case ClassNames.ideActivityLogMessage,
             ClassNames.ideClangDiagnosticActivityLogMessage,
             ClassNames.ideDiagnosticActivityLogMessage:
            return try parseIDEActivityLogMessage(iterator: &iterator)
        case ClassNames.ideActivityLogAnalyzerResultMessage:
            return try parseIDEActivityLogAnalyzerResultMessage(iterator: &iterator)
        case ClassNames.ideActivityLogAnalyzerControlFlowStepMessage:
            return try parseIDEActivityLogAnalyzerControlFlowStepMessage(iterator: &iterator)
        case ClassNames.ideActivityLogAnalyzerEventStepMessage:
            return try parseIDEActivityLogAnalyzerEventStepMessage(iterator: &iterator)
        case ClassNames.ideActivityLogActionMessage:
            return try parseIDEActivityLogActionMessage(iterator: &iterator)
        default:
            throw XCLogParserError.parseError("Unexpected className found parsing IDEActivityLogMessage \(className)")
        }
    }

    private func parseLogSectionAttachment(iterator: inout IndexingIterator<[Token]>)
        throws -> IDEActivityLogSectionAttachment {
            let classRefToken = try getClassRefToken(iterator: &iterator)
            guard case Token.classNameRef(let className) = classRefToken else {
                throw XCLogParserError.parseError("Unexpected token found parsing " +
                                                  "IDEActivityLogSectionAttachment \(classRefToken)")
            }

            if className == ClassNames.ideActivityLogSectionAttachment {
                let identifier = try parseAsString(token: iterator.next())
                switch Self.attachmentKind(of: identifier) {
                case "TaskMetrics":
                    let jsonType = IDEActivityLogSectionAttachment.BuildOperationTaskMetrics.self
                    return try IDEActivityLogSectionAttachment(identifier: identifier,
                                                               majorVersion: try parseAsInt(token: iterator.next()),
                                                               minorVersion: try parseAsInt(token: iterator.next()),
                                                               metrics: try parseAsJson(token: iterator.next(),
                                                                                         type: jsonType),
                                                               buildOperationMetrics: nil,
                                                                backtrace: nil)
                case "TaskBacktrace":
                    let jsonType = IDEActivityLogSectionAttachment.BuildOperationTaskBacktrace.self
                    return try IDEActivityLogSectionAttachment(identifier: identifier,
                                                               majorVersion: try parseAsInt(token: iterator.next()),
                                                               minorVersion: try parseAsInt(token: iterator.next()),
                                                               metrics: nil,
                                                               buildOperationMetrics: nil,
                                                               backtrace: try parseAsJson(token: iterator.next(),
                                                                                         type: jsonType))
                case "BuildOperationMetrics":
                    return try IDEActivityLogSectionAttachment(identifier: identifier,
                                                               majorVersion: try parseAsInt(token: iterator.next()),
                                                               minorVersion: try parseAsInt(token: iterator.next()),
                                                               metrics: nil,
                                                               buildOperationMetrics: try parseBuildOperationMetrics(
                                                                   token: iterator.next()
                                                               ),
                                                               backtrace: nil)
                default:
                    throw XCLogParserError.parseError("Unexpected attachment identifier \(identifier)")
                }
            }
            throw XCLogParserError.parseError("Unexpected className found parsing IDEConsoleItem \(className)")
    }

    /// The attachment kind at the end of a section-attachment identifier.
    ///
    /// This is exactly `identifier.components(separatedBy: separator).last`, minus the array that
    /// call allocated to hand back only its final element - one allocation per attachment, and
    /// attachments are the bulk of a large log. Both edge cases of that expression are preserved
    /// deliberately, because neither it nor a plain `hasSuffix` is a superset of the other:
    ///
    /// - separator absent: the whole string is the single component, so a bare `"TaskMetrics"`
    ///   matches. `hasSuffix(separator + "TaskMetrics")` would reject it. Kept via the `guard`'s
    ///   fallthrough to `identifier[...]`.
    /// - separator present: only the text *after the last* occurrence counts, so `"FooTaskMetrics"`
    ///   does not match `"TaskMetrics"`. A bare `hasSuffix("TaskMetrics")` would accept it.
    ///
    /// Measured 2026-08-04 over both benchmark logs (`Benchmarks/Logs`): 12,731 attachments in
    /// baseline-noflags-14mb and 11,762 in flagged-10x-fleet, and every one of them carried the
    /// identifier `com.apple.dt.ActivityLogSectionAttachment.TaskMetrics`. All test fixtures use
    /// the same fully-qualified `com.apple.dt.ActivityLogSectionAttachment.<Kind>` form. So no
    /// observed identifier exercises either edge case - they are retained to keep this a pure
    /// rewrite rather than because real logs are known to need them.
    private static func attachmentKind(of identifier: String) -> Substring {
        let separator = "ActivityLogSectionAttachment."
        guard let range = identifier.range(of: separator, options: .backwards) else {
            return identifier[...]
        }
        return identifier[range.upperBound...]
    }

    private func parseLogSection(iterator: inout IndexingIterator<[Token]>)
        throws -> IDEActivityLogSection {
        var classRefToken = try getClassRefToken(iterator: &iterator)
        // if we found and extra int field, we should treat this as an commandLineLog
        if case Token.int(_) = classRefToken {
            isCommandLineLog = true
            classRefToken = try getClassRefToken(iterator: &iterator)
        }
        guard
            case Token.classNameRef(let className) = classRefToken
            else {
                throw XCLogParserError.parseError("Unexpected token found parsing " +
                                                  "IDEActivityLogSection \(classRefToken)")
        }
        switch className {
        case ClassNames.ideActivityLogSection,
             ClassNames.ideCommandLineBuildLog,
             ClassNames.ideActivityLogMajorGroupSection,
             ClassNames.ideActivityLogCommandInvocationSection:
            return try parseIDEActivityLogSection(iterator: &iterator)
        case ClassNames.ideActivityLogUnitTestSection:
            return try parseIDEActivityLogUnitTestSection(iterator: &iterator)
        case ClassNames.dbgConsoleLog:
            return try parseDBGConsoleLog(iterator: &iterator)
        default:
            throw XCLogParserError.parseError("Unexpected className found parsing IDEActivityLogSection \(className)")
        }
    }

    private func getClassRefToken(iterator: inout IndexingIterator<[Token]>) throws -> Token {
        guard let classRefToken = iterator.next() else {
            throw XCLogParserError.parseError("Unexpected EOF parsing ClassRef")
        }
        // The first time there is a classRef of an specific Type,
        // There is a className before that defines the Type
        if case Token.className = classRefToken {
            guard let classRefToken = iterator.next() else {
                throw XCLogParserError.parseError("Unexpected EOF parsing ClassRef")
            }
            if case Token.classNameRef = classRefToken {
                return classRefToken
            } else {
                throw XCLogParserError.parseError("Unexpected EOF parsing ClassRef: \(classRefToken)")
            }

        }
        return classRefToken
    }

    private func parseIDEActivityLogSections(iterator: inout IndexingIterator<[Token]>)
        throws -> [IDEActivityLogSection] {
            guard let listToken = iterator.next() else {
                throw XCLogParserError.parseError("Unexpected EOF parsing array of IDEActivityLogSection")
            }
            switch listToken {
            case .null:
                return []
            case .list(let count):
                var sections = [IDEActivityLogSection]()
                sections.reserveCapacity(Self.reservation(for: count))
                for _ in 0..<count {
                    let section = try parseLogSection(iterator: &iterator)
                    sections.append(section)
                }
                return sections
            default:
                throw XCLogParserError.parseError("Unexpected token parsing array of " +
                                                  "IDEActivityLogSection: \(listToken)")
            }
    }

    private func parseIDEActivityLogSectionAttachments(iterator: inout IndexingIterator<[Token]>)
        throws -> [IDEActivityLogSectionAttachment] {
            guard let logVersion else {
                throw XCLogParserError.parseError("Log version not parsed before parsing " +
                                                  "array of IDEActivityLogSectionAttachment")
            }
            /// The list of IDEActivityLogSectionAttachment was introduced with version 11
            guard logVersion >= 11 else {
                return []
            }
            guard let listToken = iterator.next() else {
                throw XCLogParserError.parseError("Unexpected EOF parsing array of IDEActivityLogSectionAttachment")
            }
            switch listToken {
            case .null:
                return []
            case .list(let count):
                var sections = [IDEActivityLogSectionAttachment]()
                sections.reserveCapacity(Self.reservation(for: count))
                for _ in 0..<count {
                    let section = try parseLogSectionAttachment(iterator: &iterator)
                    sections.append(section)
                }
                return sections
            default:
                throw XCLogParserError.parseError("Unexpected token parsing array of " +
                                                  "IDEActivityLogSectionAttachment: \(listToken)")
            }
    }

    private func parseIDEConsoleItem(iterator: inout IndexingIterator<[Token]>)
        throws -> IDEConsoleItem? {
            let classRefToken = try getClassRefToken(iterator: &iterator)
            if case Token.null = classRefToken {
               return nil
            }
            guard case Token.classNameRef(let className) = classRefToken else {
                throw XCLogParserError.parseError("Unexpected token found parsing IDEConsoleItem \(classRefToken)")
            }

            if className == ClassNames.ideConsoleItem {
                return IDEConsoleItem(adaptorType: try parseAsInt(token: iterator.next()),
                                      content: try parseAsString(token: iterator.next()),
                                      kind: try parseAsInt(token: iterator.next()),
                                      timestamp: try parseAsDouble(token: iterator.next()))
            }
            throw XCLogParserError.parseError("Unexpected className found parsing IDEConsoleItem \(className)")
    }

    private func parseIDEConsoleItems(iterator: inout IndexingIterator<[Token]>) throws -> [IDEConsoleItem] {
        guard let listToken = iterator.next() else {
            throw XCLogParserError.parseError("Unexpected EOF parsing array of IDEConsoleItem")
        }
        switch listToken {
        case .null:
            return []
        case .list(let count):
            var items = [IDEConsoleItem]()
            items.reserveCapacity(Self.reservation(for: count))
            for _ in 0..<count {
                if let item = try parseIDEConsoleItem(iterator: &iterator) {
                    items.append(item)
                }
            }
            return items
        default:
            throw XCLogParserError.parseError("Unexpected token parsing array of IDEConsoleItem: \(listToken)")
        }
    }

    private func parseStepEdge(iterator: inout IndexingIterator<[Token]>)
        throws -> IDEActivityLogAnalyzerControlFlowStepEdge {
        let classRefToken = try getClassRefToken(iterator: &iterator)
        guard case Token.classNameRef(let className) = classRefToken else {
            throw XCLogParserError.parseError("Unexpected token found parsing " +
                "IDEActivityLogAnalyzerControlFlowStepEdge \(classRefToken)")
        }

        if className == ClassNames.ideActivityLogAnalyzerControlFlowStepEdge {
            return try parseIDEActivityLogAnalyzerControlFlowStepEdge(iterator: &iterator)
        }
        throw XCLogParserError.parseError("Unexpected className found parsing " +
            "IDEActivityLogAnalyzerControlFlowStepEdge \(className)")
    }

    private func parseStepEdges(iterator: inout IndexingIterator<[Token]>)
        throws -> [IDEActivityLogAnalyzerControlFlowStepEdge] {
        guard let listToken = iterator.next() else {
            throw XCLogParserError.parseError("Unexpected EOF parsing array of IDEConsoleItem")
        }
        switch listToken {
        case .null:
            return []
        case .list(let count):
            var items = [IDEActivityLogAnalyzerControlFlowStepEdge]()
            items.reserveCapacity(Self.reservation(for: count))
            for _ in 0..<count {
                items.append(try parseStepEdge(iterator: &iterator))
            }
            return items
        default:
            throw XCLogParserError.parseError("Unexpected token parsing array of IDEConsoleItem: \(listToken)")
        }
    }

    private func parseIBDocumentMemberLocation(iterator: inout IndexingIterator<[Token]>)
        throws -> IBDocumentMemberLocation {
            return IBDocumentMemberLocation(documentURLString: try parseAsString(token: iterator.next()),
                                            timestamp: try parseAsDouble(token: iterator.next()),
                                            memberIdentifier: try parseIBMemberID(iterator: &iterator),
                                            attributeSearchLocation:
                                                try parseIBAttributeSearchLocation(iterator: &iterator))
    }

    private func parseIBMemberID(iterator: inout IndexingIterator<[Token]>)
        throws -> IBMemberID {
        let classRefToken = try getClassRefToken(iterator: &iterator)
        guard case Token.classNameRef(let className) = classRefToken else {
            throw XCLogParserError.parseError("Unexpected token found parsing " +
                "IBMemberID \(classRefToken)")
        }

        if className == ClassNames.ibMemberID {
            return IBMemberID(memberIdentifier: try parseAsString(token: iterator.next()))
        }
        throw XCLogParserError.parseError("Unexpected className found parsing " +
            "IBMemberID \(className)")
    }

    private func parseIBAttributeSearchLocation(iterator: inout IndexingIterator<[Token]>)
        throws -> IBAttributeSearchLocation? {
            guard let nextToken = iterator.next() else {
                throw XCLogParserError.parseError("Unexpected EOF parsing IBAttributeSearchLocation")
            }
            if case Token.null = nextToken {
                return nil
            }
            throw XCLogParserError.parseError("Unexpected Token parsing IBAttributeSearchLocation: \(nextToken)")
    }

    /// The log bytes and range behind `token`, when it is a string the lexer left undecoded.
    ///
    /// `nil` for anything else - a materialized string, `.null`, or a non-string token - and the caller
    /// falls back to `parseAsString`, which also raises the parse error for a wrong token type.
    private static func deferredText(in token: Token?) -> (LogBytes, Range<Int>)? {
        guard case .some(.string(let string)) = token else { return nil }
        return string.deferredRange
    }

    private func parseAsString(token: Token?) throws -> String {
        guard let token = token else {
            throw XCLogParserError.parseError("Unexpected EOF parsing String")
        }
        switch token {
        case .string(let string):
            return string.value.trimmedIfNeeded()
        case .null:
            return ""
        default:
            throw XCLogParserError.parseError("Unexpected token parsing String: \(token)")
        }
    }

    private func parseAsJson<T: Decodable>(token: Token?, type: T.Type) throws -> T? {
        guard let token = token else {
            throw XCLogParserError.parseError("Unexpected EOF parsing JSON String")
        }
        switch token {
        case .json(let string):
            // `Data(string.utf8)` rather than `string.data(using: .utf8)`: the latter returns an
            // optional that cannot actually be nil for UTF-8 (every String is representable) and
            // went through an extra copy to find that out. The decoder is reused - see `jsonDecoder`.
            return try jsonDecoder.decode(type, from: Data(string.utf8))
        case .null:
            return nil
        default:
            throw XCLogParserError.parseError("Unexpected token parsing JSON String: \(token)")
        }
    }

    private func parseBuildOperationMetrics(
        token: Token?
    ) throws -> IDEActivityLogSectionAttachment.BuildOperationMetrics? {
        guard let token = token else {
            throw XCLogParserError.parseError("Unexpected EOF parsing BuildOperationMetrics")
        }
        switch token {
        case .json(let string):
            // See `parseAsJson` for why this is `Data(string.utf8)` and not `data(using:)`.
            return try IDEActivityLogSectionAttachment.BuildOperationMetrics(from: Data(string.utf8))
        case .null:
            return nil
        default:
            throw XCLogParserError.parseError("Unexpected token parsing BuildOperationMetrics: \(token)")
        }
    }

    private func parseAsInt(token: Token?) throws -> UInt64 {
        guard let token = token else {
            throw XCLogParserError.parseError("Unexpected EOF parsing Int")
        }
        if case Token.int(let value) = token {
            return value
        }
        throw XCLogParserError.parseError("Unexpected token parsing Int: \(token))")
    }

    private func parseAsDouble(token: Token?) throws -> Double {
        guard let token = token else {
            throw XCLogParserError.parseError("Unexpected EOF parsing Double")
        }
        if case Token.double(let value) = token {
            return value
        }
        throw XCLogParserError.parseError("Unexpected token parsing Double: \(token)")
    }

    private func parseBoolean(token: Token?) throws -> Bool {
        guard let token = token else {
            throw XCLogParserError.parseError("Unexpected EOF parsing Bool")
        }
        if case Token.int(let value) = token {
            if value > 1 {
                throw XCLogParserError.parseError("Unexpected value parsing Bool: \(value)")
            }
            return value == 1
        }
        throw XCLogParserError.parseError("Unexpected token parsing Bool: \(token)")
    }

    private func parseDVTMemberDocumentLocation(iterator: inout IndexingIterator<[Token]>)
    throws -> DVTMemberDocumentLocation {
        return DVTMemberDocumentLocation(documentURLString: try parseAsString(token: iterator.next()),
                                         timestamp: try parseAsDouble(token: iterator.next()),
                                         member: try parseAsString(token: iterator.next()))
    }

}
