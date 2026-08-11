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

extension String {

    /// `trimmingCharacters(in: .whitespacesAndNewlines)`, skipping the copy when there is nothing
    /// to trim.
    ///
    /// # Why this exists
    ///
    /// `parseAsString` is the single largest allocation site in the parser, and almost every string
    /// it is handed is already trimmed, because log tokens are delimited rather than padded.
    ///
    /// Note the win is *half* of that share, not all of it: a no-op `trimmingCharacters` still
    /// allocates one object rather than zero, so the fast path removes one of the two allocations.
    /// Do not expect returning `self` to remove the whole share.
    ///
    /// # Why the byte test is sufficient
    ///
    /// `CharacterSet.whitespacesAndNewlines` has exactly 26 members. Six are ASCII - tab, LF, VT,
    /// FF, CR and space - and the other twenty are non-ASCII (U+0085, U+00A0, the U+2000 block,
    /// U+2028/U+2029, U+3000, ...). Every UTF-8 byte of those twenty is >= 0x80, which is a
    /// property of UTF-8 itself: only a single-byte encoding can produce a byte < 0x80, so no
    /// multi-byte scalar can contain one. This was verified by enumerating the whole set rather
    /// than assumed.
    ///
    /// Therefore, if the first and last UTF-8 bytes are both ASCII and neither is one of the six,
    /// no member of the set can begin or end the string, and the trim provably cannot remove
    /// anything. Returning `self` is then byte-identical to trimming - the report stays
    /// byte-for-byte the same, which is the project's regression check.
    ///
    /// Anything else - non-ASCII at either end, or an actual ASCII whitespace byte - falls through
    /// to Foundation. That keeps the correctness argument to "the fast path only fires when the
    /// answer is provably `self`", instead of reimplementing Unicode trimming.
    func trimmedIfNeeded() -> String {
        let trimmed: String? = utf8.withContiguousStorageIfAvailable { bytes -> String? in
            guard let first = bytes.first, let last = bytes.last else { return nil }
            guard Self.isAsciiNonTrimBoundary(first), Self.isAsciiNonTrimBoundary(last) else {
                return nil
            }
            return self
        } ?? nil
        return trimmed ?? trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when `byte` is ASCII and is not one of the six ASCII members of
    /// `.whitespacesAndNewlines`, i.e. when it cannot take part in a trim.
    private static func isAsciiNonTrimBoundary(_ byte: UInt8) -> Bool {
        // 0x09...0x0D is tab, LF, VT, FF, CR - contiguous, so one range covers five of the six.
        byte < 0x80 && byte != 0x20 && !(0x09...0x0D).contains(byte)
    }

}
