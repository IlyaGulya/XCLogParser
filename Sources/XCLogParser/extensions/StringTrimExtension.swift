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
    /// # Why it also trims, instead of only detecting no-ops
    ///
    /// On a platform whose Foundation has no native `NSString`, `trimmingCharacters` routes through
    /// `NSString.substring` -> `String._slowFromCodeUnits` -> `UTF16.ForwardParser.parseScalar`,
    /// converting the string to UTF-16 one scalar at a time. On Linux that cost dominated the parse
    /// stage. So when both ends are ASCII the trim is done on the bytes here.
    ///
    /// Anything the byte logic cannot settle - non-ASCII at either end, or a non-ASCII whitespace
    /// member exposed once the ASCII run is removed - still falls through to Foundation. That keeps
    /// the correctness argument to "the fast path only fires when the answer is provable from the
    /// bytes", instead of reimplementing Unicode trimming.
    func trimmedIfNeeded() -> String {
        let trimmed: String? = utf8.withContiguousStorageIfAvailable { bytes -> String? in
            guard let first = bytes.first, let last = bytes.last else {
                // Empty: there is nothing to trim, so `self` is the answer. Reaching Foundation
                // for this was the single most common way into the slow path: on a real log, far
                // more string tokens are empty than need any trimming at all.
                return self
            }
            if Self.isAsciiNonTrimBoundary(first), Self.isAsciiNonTrimBoundary(last) {
                return self
            }
            // Both ends ASCII: narrow the byte range past the ASCII whitespace. This keeps the
            // string out of the UTF-16 round trip that `NSString.trimmingCharacters` performs on
            // platforms without a native NSString.
            guard first < 0x80, last < 0x80 else { return nil }
            var start = bytes.startIndex
            var end = bytes.endIndex
            while start < end, Self.isAsciiTrimByte(bytes[start]) { start += 1 }
            while end > start, Self.isAsciiTrimByte(bytes[end - 1]) { end -= 1 }
            // Removing the ASCII whitespace can expose a *non-ASCII* member of the set - U+00A0 and
            // the U+2000 block are whitespace too - and trimming has to continue through those.
            // Deciding that here would mean reimplementing Unicode trimming, so hand the whole
            // string back to Foundation instead. Only the new boundary needs checking: any
            // non-ASCII further in is interior either way.
            if start < end, bytes[start] >= 0x80 || bytes[end - 1] >= 0x80 { return nil }
            // The lint rule below wants a failable initializer, which is right for `Data` of
            // unknown encoding. This is a slice of `self.utf8`, so it is valid UTF-8 by
            // construction and the non-failable initializer cannot insert a replacement character.
            // swiftlint:disable:next optional_data_string_conversion
            return String(decoding: bytes[start..<end], as: UTF8.self)
        } ?? nil
        return trimmed ?? trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when `byte` is ASCII and is not one of the six ASCII members of
    /// `.whitespacesAndNewlines`, i.e. when it cannot take part in a trim.
    private static func isAsciiNonTrimBoundary(_ byte: UInt8) -> Bool {
        // 0x09...0x0D is tab, LF, VT, FF, CR - contiguous, so one range covers five of the six.
        byte < 0x80 && byte != 0x20 && !(0x09...0x0D).contains(byte)
    }

    /// True when `byte` is one of the six ASCII members of `.whitespacesAndNewlines`.
    ///
    /// Cutting on these bytes cannot split a multi-byte scalar: every byte of a multi-byte UTF-8
    /// sequence is >= 0x80, so a byte this returns true for is always a whole scalar. The interior
    /// of the string may be any UTF-8 at all - only the bytes actually removed have to be ASCII,
    /// and they are.
    private static func isAsciiTrimByte(_ byte: UInt8) -> Bool {
        byte == 0x20 || (0x09...0x0D).contains(byte)
    }

}
