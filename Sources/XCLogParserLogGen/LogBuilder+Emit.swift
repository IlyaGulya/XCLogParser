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

/// Writing a `Section` tree out as SLF tokens.
///
/// The field order here mirrors `ActivityParser.parseIDEActivityLogSection` exactly. That order is the
/// whole difficulty of writing SLF by hand: the format carries no field names, so one misplaced or
/// extra token shifts everything after it and surfaces as an unrelated parse error much later in the
/// document. Any change here has to be made against that function.
extension LogBuilder {

    // MARK: - Emitting

    /// Writes one section in `parseIDEActivityLogSection` field order.
    func writeSection(_ writer: inout SLFWriter, section: Section, isRoot: Bool) {
        if isRoot {
            // `parseLogSection` reads a classRef and, if it finds an int *in that position* instead,
            // sets `isCommandLineLog` and reads the classRef again. So the marker comes first and the
            // classRef follows it. Emitting the marker after the classRef instead means the check
            // never fires: the ref is returned as-is, `sectionType` then eats the marker, and every
            // later field is shifted by one.
            //
            // That flag is also what makes the trailing `unknown` int be read on every section, so
            // the marker and that int have to agree - one without the other desynchronises the
            // document.
            writer.int(2)
        }
        writer.classRef(isRoot ? "IDECommandLineBuildLog" : "IDEActivityLogSection")
        writer.int(isRoot ? 0 : 1)                  // sectionType
        writer.string(section.domainType)           // domainType
        writer.string(section.title)                // title
        writer.string(section.signature)            // signature
        writer.double(1.0)                          // timeStartedRecording
        writer.double(2.0)                          // timeStoppedRecording

        // subSections: a list header, then each nested section with its own classRef.
        if section.subSections.isEmpty {
            writer.null()
        } else {
            writer.list(section.subSections.count)
            for sub in section.subSections {
                writeSection(&writer, section: sub, isRoot: false)
            }
        }

        writer.string(section.text)                 // text

        // messages
        if section.notices.isEmpty {
            writer.null()
        } else {
            writer.list(section.notices.count)
            for notice in section.notices {
                writeMessage(&writer, notice: notice)
            }
        }

        writer.int(0)                               // wasCancelled
        writer.int(0)                               // isQuiet
        writer.int(0)                               // wasFetchedFromCache
        writer.string("")                           // subtitle
        writeDocumentLocation(&writer, url: section.documentURL)
        writer.string(section.commandDetailDesc)    // commandDetailDesc
        writer.string("00000000-0000-0000-0000-000000000000") // uniqueIdentifier
        writer.string("")                           // localizedResultString
        writer.string("")                           // xcbuildSignature
        // No attachments token: the list was introduced in log version 11 and
        // `parseIDEActivityLogSectionAttachments` returns early without reading anything below that.
        // Emitting one at version 10 leaves a stray token that desynchronises the next section.
        // `isCommandLineLog` is set from the root's domain type, and only then is this trailing int
        // read. Emitting it unconditionally would desynchronise every following section.
        writer.int(0)                               // unknown
    }

    private func writeMessage(_ writer: inout SLFWriter, notice: Notice) {
        // `NoticeType.fromTitle` maps these exact strings, and it reads `categoryIdent` when that is
        // non-empty. A clang notice deliberately carries no category: its type is decided by the
        // `[-Wflag]` found in the section text, and giving it a Swift category here would send it
        // down the Swift path instead.
        let category = notice.clangFlag == nil
            ? (notice.isError ? "Swift Compiler Error" : "Swift Compiler Warning")
            : ""
        writer.classRef("IDEActivityLogMessage")
        writer.string(notice.title)                 // title
        writer.string(notice.title)                 // shortTitle
        writer.int(0)                               // timeEmitted
        writer.int(0)                               // rangeEndInSectionText
        writer.int(0)                               // rangeStartInSectionText
        writer.null()                               // subMessages
        writer.int(notice.isError ? 2 : 1)          // severity
        writer.string(category)                     // type
        writeTextDocumentLocation(&writer, notice: notice)
        writer.string(category)                     // categoryIdent
        writer.null()                               // secondaryLocations
        writer.string("")                           // additionalDescription
    }

    private func writeDocumentLocation(_ writer: inout SLFWriter, url: String) {
        writer.classRef("DVTDocumentLocation")
        writer.string(url)                          // documentURLString
        writer.double(0)                            // timestamp
    }

    private func writeTextDocumentLocation(_ writer: inout SLFWriter, notice: Notice) {
        writer.classRef("DVTTextDocumentLocation")
        writer.string(notice.documentURL)           // documentURLString
        writer.double(0)                            // timestamp
        // Written 0-based, because `Notice.realLocationNumber` adds 1 to whatever is stored here.
        // The text markers carry the 1-based numbers, so storing them 1-based here shifts the
        // lookup key by one and every `detail` silently comes back nil - the log still parses and
        // the notice count is still right, so nothing reports a problem.
        writer.int(notice.line - 1)                 // startingLineNumber
        writer.int(notice.column - 1)               // startingColumnNumber
        writer.int(notice.line - 1)                 // endingLineNumber
        writer.int(notice.column - 1)               // endingColumnNumber
        writer.int(0)                               // characterRangeEnd
        writer.int(0)                               // characterRangeStart
        writer.int(0)                               // locationEncoding
    }
}
