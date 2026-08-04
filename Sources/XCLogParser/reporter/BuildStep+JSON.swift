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

/// Hand-written JSON emission for the reported model types, bypassing `Encodable`.
///
/// These mirror the compiler-synthesized `encode(to:)` field for field; see `JSONWriter` for why
/// they exist and what the two format differences are. The `Encodable` conformances are deliberately
/// left in place - they are public API, and the other reporters and any library consumer still use
/// them. Only `JsonReporter` takes this path.
///
/// **These must stay in sync with the stored properties of the types they serialize.** A field added
/// to `BuildStep` without a line here silently vanishes from the report, which no compiler check
/// will catch. `JSONWriterTests.testBuildStepWritesEveryEncodableField` guards against that by
/// diffing the key set against `JSONEncoder`'s.
extension BuildStep {

    /// Number of steps in this subtree, counting this one.
    ///
    /// Used to size the output buffer before writing. `[UInt8]` grows geometrically, and at report
    /// scale the final doubling overshoots by up to ~92 MB on a 180 MB buffer - which measured as
    /// +18.7 MB peak RSS against `JSONEncoder`, reproducible to the byte across five runs. One
    /// up-front reservation replaces that.
    func stepCount() -> Int {
        return 1 + subSteps.reduce(0) { $0 + $1.stepCount() }
    }

    /// Writes this step and its whole subtree.
    ///
    /// Recursive rather than an explicit stack: the tree is at most four levels deep (main → target
    /// → detail → sub-detail), so there is no stack-depth risk and the recursion reads better.
    func write(to writer: inout JSONWriter) {
        writer.beginObject()
        writer.field("type", type.rawValue)
        writer.field("machineName", machineName)
        writer.field("buildIdentifier", buildIdentifier)
        writer.field("identifier", identifier)
        writer.field("parentIdentifier", parentIdentifier)
        writer.field("domain", domain)
        writer.field("title", title)
        writer.field("signature", signature)
        writer.field("startDate", startDate)
        writer.field("endDate", endDate)
        writer.field("startTimestamp", startTimestamp)
        writer.field("endTimestamp", endTimestamp)
        writer.field("duration", duration)
        writer.field("detailStepType", detailStepType.rawValue)
        writer.field("buildStatus", buildStatus)
        writer.field("schema", schema)

        writer.key("subSteps")
        writer.beginArray()
        for subStep in subSteps {
            subStep.write(to: &writer)
        }
        writer.endArray()

        writer.field("warningCount", warningCount)
        writer.field("errorCount", errorCount)
        writer.field("architecture", architecture)
        writer.field("documentURL", documentURL)
        writer.writeNotices("warnings", warnings)
        writer.writeNotices("errors", errors)
        writer.writeNotices("notes", notes)
        writer.writeArray("swiftFunctionTimes", swiftFunctionTimes) { $1.write(to: &$0) }
        writer.field("fetchedFromCache", fetchedFromCache)
        writer.field("compilationEndTimestamp", compilationEndTimestamp)
        writer.field("compilationDuration", compilationDuration)
        writer.field("clangTimeTraceFile", clangTimeTraceFile)

        if let linkerStatistics = linkerStatistics {
            writer.key("linkerStatistics")
            linkerStatistics.write(to: &writer)
        }

        writer.writeArray("swiftTypeCheckTimes", swiftTypeCheckTimes) { $1.write(to: &$0) }
        writer.endObject()
    }
}

extension Notice {

    func write(to writer: inout JSONWriter) {
        writer.beginObject()
        writer.field("type", type.rawValue)
        writer.field("title", title)
        writer.field("clangFlag", clangFlag)
        writer.field("documentURL", documentURL)
        writer.field("severity", severity)
        writer.field("startingLineNumber", startingLineNumber)
        writer.field("endingLineNumber", endingLineNumber)
        writer.field("startingColumnNumber", startingColumnNumber)
        writer.field("endingColumnNumber", endingColumnNumber)
        writer.field("characterRangeEnd", characterRangeEnd)
        writer.field("characterRangeStart", characterRangeStart)
        writer.field("interfaceBuilderIdentifier", interfaceBuilderIdentifier)
        writer.field("detail", detail)
        writer.endObject()
    }
}

extension SwiftFunctionTime {

    func write(to writer: inout JSONWriter) {
        writer.beginObject()
        writer.field("file", file)
        writer.field("durationMS", durationMS)
        writer.field("startingLine", startingLine)
        writer.field("startingColumn", startingColumn)
        writer.field("signature", signature)
        writer.field("occurrences", occurrences)
        writer.endObject()
    }
}

extension SwiftTypeCheck {

    func write(to writer: inout JSONWriter) {
        writer.beginObject()
        writer.field("file", file)
        writer.field("durationMS", durationMS)
        writer.field("startingLine", startingLine)
        writer.field("startingColumn", startingColumn)
        writer.field("occurrences", occurrences)
        writer.endObject()
    }
}

extension LinkerStatistics {

    func write(to writer: inout JSONWriter) {
        writer.beginObject()
        writer.field("totalMS", totalMS)
        writer.field("optionParsingMS", optionParsingMS)
        writer.field("optionParsingPercent", optionParsingPercent)
        writer.field("objectFileProcessingMS", objectFileProcessingMS)
        writer.field("objectFileProcessingPercent", objectFileProcessingPercent)
        writer.field("resolveSymbolsMS", resolveSymbolsMS)
        writer.field("resolveSymbolsPercent", resolveSymbolsPercent)
        writer.field("buildAtomListMS", buildAtomListMS)
        writer.field("buildAtomListPercent", buildAtomListPercent)
        writer.field("runPassesMS", runPassesMS)
        writer.field("runPassesPercent", runPassesPercent)
        writer.field("writeOutputMS", writeOutputMS)
        writer.field("writeOutputPercent", writeOutputPercent)
        writer.field("pageins", pageins)
        writer.field("pageouts", pageouts)
        writer.field("faults", faults)
        writer.field("objectFiles", objectFiles)
        writer.field("objectFilesBytes", objectFilesBytes)
        writer.field("archiveFiles", archiveFiles)
        writer.field("archiveFilesBytes", archiveFilesBytes)
        writer.field("dylibFiles", dylibFiles)
        writer.field("wroteOutputFileBytes", wroteOutputFileBytes)
        writer.endObject()
    }
}

private extension JSONWriter {

    /// An optional array field. Absent when `nil` - see `JSONWriter.field(_:_:)` on why `nil` omits
    /// the key rather than writing `null`.
    mutating func writeArray<Element>(_ name: StaticString,
                                      _ elements: [Element]?,
                                      _ body: (inout JSONWriter, Element) -> Void) {
        guard let elements = elements else { return }
        key(name)
        beginArray()
        for element in elements {
            body(&self, element)
        }
        endArray()
    }

    /// `Notice` is a class, so it cannot use `writeArray`'s generic closure without the closure
    /// capturing `self` inout twice; a dedicated overload keeps it straightforward.
    mutating func writeNotices(_ name: StaticString, _ notices: [Notice]?) {
        guard let notices = notices else { return }
        key(name)
        beginArray()
        for notice in notices {
            notice.write(to: &self)
        }
        endArray()
    }
}
