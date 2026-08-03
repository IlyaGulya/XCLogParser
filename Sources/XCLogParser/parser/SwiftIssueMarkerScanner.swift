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

extension Notice {

    /// The two diagnostic markers, as UTF-8 bytes. Both are pure ASCII.
    private static let errorMarker = Array(": error:".utf8)
    private static let warningMarker = Array(": warning:".utf8)

    /// Returns the offset at which a diagnostic marker starts within `line`, or `nil` if the line
    /// holds no marker.
    ///
    /// `": error:"` takes precedence over `": warning:"` when both are present, matching the previous
    /// `range(of: ": error:") ?? range(of: ": warning:")`. Note that this precedence is by *marker*,
    /// not by position: an earlier `": warning:"` loses to a later `": error:"`.
    ///
    /// The "cluster safe" part: `String.contains` compares grapheme clusters, so a combining scalar
    /// immediately after the marker's final `":"` fuses into that cluster and makes Foundation report
    /// no match. A naive byte search would disagree. Such a match is rejected here so the byte-wise
    /// implementation keeps the original behaviour exactly.
    ///
    /// # Why this is one anchored pass rather than two searches
    ///
    /// The obvious shape - `find(errorMarker) ?? find(warningMarker)` - walks every line twice, and
    /// each walk compares the marker's first byte at every offset. On a real fleet log that is close to
    /// worst case: `": error:"` does not occur *at all*, so the error pass always ran to the end of
    /// every line and always failed, doubling the byte count for nothing.
    ///
    /// Both markers begin with `":"`, and only 0.78% of bytes in that log are `":"`. So this anchors on
    /// that one byte and tries both markers only at those few positions, turning two dense passes into
    /// one sparse one. The `??` precedence is preserved by continuing to the end of the line once a
    /// warning is found, so a later `": error:"` still wins.
    static func clusterSafeMarkerRange(in bytes: UnsafeBufferPointer<UInt8>,
                                       line: Range<Int>) -> Int? {
        var firstWarning: Int?
        var index = line.lowerBound
        // The shorter marker sets the bound; `matches` re-checks room for the longer one.
        let limit = line.upperBound - min(errorMarker.count, warningMarker.count)
        while index <= limit {
            guard bytes[index] == UInt8(ascii: ":") else {
                index += 1
                continue
            }
            if matches(errorMarker, in: bytes, at: index, limit: line.upperBound) {
                return index
            }
            if firstWarning == nil,
               matches(warningMarker, in: bytes, at: index, limit: line.upperBound) {
                firstWarning = index
            }
            index += 1
        }
        return firstWarning
    }

    /// Whether `pattern` occurs at exactly `index`, and its trailing byte is not fused into a following
    /// grapheme cluster. See `clusterSafeMarkerRange`.
    private static func matches(_ pattern: [UInt8],
                                in bytes: UnsafeBufferPointer<UInt8>,
                                at index: Int,
                                limit: Int) -> Bool {
        guard index + pattern.count <= limit else {
            return false
        }
        var offset = 0
        while offset < pattern.count {
            guard bytes[index + offset] == pattern[offset] else {
                return false
            }
            offset += 1
        }
        return !isFusedWithNextCluster(bytes: bytes, at: index + pattern.count, limit: limit)
    }

    /// Whether the scalar starting at `index` fuses into the preceding grapheme cluster, which would
    /// make `String.contains` reject a match that a byte comparison accepts.
    ///
    /// Only a non-ASCII scalar can fuse, so an ASCII byte (or end of line) is immediately safe - and
    /// that is the path every real Xcode diagnostic takes. Beyond that, being non-ASCII is *not*
    /// sufficient: `"a: error:é x"` really does contain `": error:"` because `é` starts a new cluster,
    /// whereas `"a: error:\u{0301} x"` does not. Distinguishing the two requires actually asking
    /// Unicode, so the rare non-ASCII case decodes the scalar and consults its grapheme-break
    /// property rather than guessing.
    private static func isFusedWithNextCluster(bytes: UnsafeBufferPointer<UInt8>,
                                               at index: Int,
                                               limit: Int) -> Bool {
        guard index < limit, bytes[index] >= 0x80, let base = bytes.baseAddress else {
            return false
        }
        // A UTF-8 scalar is at most 4 bytes, so decoding that much is enough to recover the first one.
        let width = min(4, limit - index)
        let scalarBytes = UnsafeBufferPointer(start: base + index, count: width)
        // swiftlint:disable:next optional_data_string_conversion
        guard let scalar = String(decoding: scalarBytes, as: UTF8.self).unicodeScalars.first else {
            return false
        }
        // "x" is a stand-in for the marker's trailing ":" - any single ASCII cluster behaves the same.
        // If appending the scalar still measures one grapheme cluster, it fused.
        return "x\(scalar)".count == 1
    }
}
