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

/// The byte-level scan for Swift diagnostics, and the conversion of what it finds back to `String`.
///
/// `parseSwiftIssues` walks a section's UTF-8 once, recording the lines that form each diagnostic as
/// `Range<Int>` and materialising only those - a section's text is large and most of it is not part of
/// any diagnostic. It lives here rather than beside its caller in `Notice+Parser.swift` to keep that
/// file within the file-length limit.
extension Notice {

    /// Copies `bytes[range]` onto the end of `out`.
    static func append(range: Range<Int>,
                       of bytes: UnsafeBufferPointer<UInt8>,
                       to out: inout [UInt8]) {
        guard let base = bytes.baseAddress else {
            return
        }
        out.append(contentsOf: UnsafeBufferPointer(start: base + range.lowerBound,
                                                   count: range.count))
    }

    /// Materialises `bytes[range]` as a `String`.
    static func string(from bytes: UnsafeBufferPointer<UInt8>,
                       range: Range<Int>) -> String {
        guard let base = bytes.baseAddress else {
            return ""
        }
        // Slices of the log's own UTF-8 cut at scalar boundaries, so the non-failable initializer is
        // exact and cannot insert a replacement character.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: UnsafeBufferPointer(start: base + range.lowerBound,
                                                    count: range.count), as: UTF8.self)
    }

    /// Single-pass core of `parseSwiftIssuesDetailsByLocation`.
    ///
    /// Ranges found in `bytes` are converted back to `String` only for the lines that form part of a
    /// diagnostic.
    static func parseSwiftIssues(bytes: UnsafeBufferPointer<UInt8>) -> [String: String] {
        var detailsByLocation = [String: String]()

        // The diagnostic line currently being accumulated, and the exclusive end offset of its
        // dictionary key.
        //
        // The original built the key as `detail[...range.lowerBound]`, a *closed* range, so the key
        // includes the marker's own leading ":" - for "a: error: x" the key is "a:", not "a". The key
        // therefore ends one byte past the marker's start.
        var currentLine: Range<Int>?
        var currentKeyEnd = 0
        var continuations: [Range<Int>] = []
        // Scratch buffer for joining continuation lines, reused across flushes. The previous
        // `detail += "\n" + string(...)` allocated three Strings per continuation line - piece,
        // concatenation, grown result - 494,108 of the run's allocations. One exactly-sized buffer
        // costs one String per detail instead of n.
        var joined: [UInt8] = []

        func flush() {
            guard let line = currentLine else {
                return
            }
            let detail: String
            if continuations.isEmpty {
                // The common case: the line is the whole detail and the join is pure overhead.
                detail = string(from: bytes, range: line)
            } else {
                joined.removeAll(keepingCapacity: true)
                joined.reserveCapacity(line.count + continuations.reduce(0) { $0 + $1.count + 1 })
                append(range: line, of: bytes, to: &joined)
                for continuation in continuations {
                    joined.append(UInt8(ascii: "\n"))
                    append(range: continuation, of: bytes, to: &joined)
                }
                // Slices of the log's own UTF-8, cut only at "\r", so no scalar is split and the
                // non-failable initializer is exact.
                // swiftlint:disable:next optional_data_string_conversion
                detail = String(decoding: joined, as: UTF8.self)
            }
            detailsByLocation[string(from: bytes,
                                     range: line.lowerBound..<currentKeyEnd)] = detail
            currentLine = nil
            continuations.removeAll(keepingCapacity: true)
        }

        // `split(separator: "\r")` drops empty subsequences, so an empty line - whether from "\r\r" or
        // from a trailing "\r" - is never offered as a continuation. Skipping empty ranges here
        // reproduces that exactly.
        var lineStart = 0
        var index = 0
        while index <= bytes.count {
            // Treat end-of-input as a line terminator so the final line is not dropped.
            guard index == bytes.count || bytes[index] == UInt8(ascii: "\r") else {
                index += 1
                continue
            }
            let line = lineStart..<index
            if !line.isEmpty {
                if let markerStart = clusterSafeMarkerRange(in: bytes, line: line) {
                    flush()
                    currentLine = line
                    currentKeyEnd = markerStart + 1
                } else if currentLine != nil {
                    continuations.append(line)
                }
            }
            index += 1
            lineStart = index
        }
        flush()

        return detailsByLocation
    }

}
