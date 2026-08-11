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

/// Allocation-free ASCII case-insensitive matching helpers shared by
/// `Prefix`, `Contains` and `Suffix`.
///
/// Do not implement these as `input.lowercased().starts(with: pattern)`. That
/// allocates a full lowercased copy of the input for *every* pattern tried, and
/// `DetailStepType.getDetailType` is a `switch` over 18 `Prefix` cases, so a
/// single signature allocates dozens of throwaway strings. It was one of the
/// largest allocation sources in a full parse.
///
/// The fast path below compares UTF-8 bytes with ASCII case folding and
/// allocates nothing.
///
/// # The fast path requires BOTH pattern and input to be pure ASCII
///
/// This is a deliberately conservative gate. Anything else falls back to the
/// original `lowercased()` implementation. Two independent hazards make a
/// looser rule (such as excluding a hand-picked list of "dangerous" scalars)
/// indefensible:
///
/// ## 1. Grapheme clusters
///
/// `starts(with:)`, `contains` and `hasSuffix` operate on **grapheme
/// clusters**, not bytes or scalars. A combining mark immediately after an
/// otherwise-matching region fuses into the same cluster and defeats the
/// match, so a byte-level search would report a match where Foundation does
/// not:
///
/// ```
/// "k\u{0301}".starts(with: "k")           // false - one grapheme cluster
/// "warning:\u{0345}".contains("warning:") // false
/// ```
///
/// All 112 combining marks in U+0300...U+036F behave this way, as do ZWJ
/// (U+200D), variation selectors, regional indicators and others. The set is
/// open-ended, so enumerating it is not viable. Note the asymmetry: a
/// combining mark *before* the matched region is harmless (`"x\u{0301}k"`
/// really does contain `"k"`); only one directly after it fuses.
///
/// ## 2. Unicode lowercasing that produces ASCII
///
/// `lowercased()` is full Unicode lowercasing, so ASCII-only folding can also
/// miss a non-ASCII scalar whose lowercase form *is* ASCII. An exhaustive
/// sweep of U+0080...U+10FFFF found exactly two:
///
/// - `U+212A` KELVIN SIGN, which lowercases to ASCII `"k"`.
/// - `U+0130` LATIN CAPITAL LETTER I WITH DOT ABOVE, which lowercases to
///   `"i" + U+0307`.
///
/// `U+212A` genuinely matters: the real pattern `Prefix("LinkStoryboards ")`
/// contains a `k`, so `"Lin\u{212A}Storyboards "` matches under Unicode
/// lowercasing but would not under ASCII folding.
///
/// # Why the pure-ASCII gate is correct by construction
///
/// In an all-ASCII string every byte is its own grapheme cluster (no ASCII
/// scalar combines with another), so byte offsets and cluster boundaries
/// coincide and hazard 1 cannot arise. No ASCII scalar lowercases to a
/// non-ASCII or multi-scalar form, and both scalars from hazard 2 are
/// non-ASCII and therefore already excluded. Real Xcode signatures and
/// diagnostics are ASCII, so the fast path still applies to essentially all
/// input we actually see - which is where the entire win comes from.
///
/// # The ASCII check must not be a separate pass
///
/// Do not gate these on a standalone "is this input ASCII?" scan. That is
/// O(input) work in front of every match, while a `Prefix` comparison only ever
/// reads pattern-length bytes - so a short prefix test would pay for a scan of
/// the whole section text, costing more than the fast path saves.
///
/// The functions below check ASCII-ness inline, one byte at a time, only for
/// bytes the comparison already has to read, and return `nil` to mean "hit a
/// non-ASCII byte, fall back to Unicode". `Prefix` is therefore O(pattern).
///
/// This is sound because a non-ASCII byte *beyond* the inspected region cannot
/// change the answer: hazard 1 needs a combining mark fused to the last cluster
/// compared, and hazard 2 a scalar folding to ASCII, both of which must sit
/// inside the region. See `asciiStarts`, which examines that boundary byte.
enum CaseFolding {

    /// Returns the UTF-8 bytes of `string` if it is pure ASCII, otherwise `nil`.
    static func asciiBytes(of string: String) -> [UInt8]? {
        var bytes = [UInt8]()
        bytes.reserveCapacity(string.utf8.count)
        for byte in string.utf8 {
            guard byte < 0x80 else {
                return nil
            }
            bytes.append(byte)
        }
        return bytes
    }

    /// ASCII-lowercases a single UTF-8 byte.
    private static func foldAscii(_ byte: UInt8) -> UInt8 {
        // 'A'...'Z' -> 'a'...'z'
        if byte >= 0x41 && byte <= 0x5A {
            return byte + 0x20
        }
        return byte
    }

    /// Case-insensitive `starts(with:)` over UTF-8 bytes, without allocating.
    ///
    /// Returns `nil` if a non-ASCII byte is reached, meaning the caller must fall
    /// back to Unicode comparison. Only `pattern.count + 1` bytes of `input` are
    /// ever examined, which is what makes this O(pattern) rather than O(input).
    static func asciiStarts(with pattern: [UInt8], input: String) -> Bool? {
        var patternIndex = 0
        for byte in input.utf8 {
            guard byte < 0x80 else {
                // A non-ASCII byte at the boundary can still change the answer via a
                // combining mark fusing into the final cluster, so this is a fallback
                // rather than a match - even when every pattern byte already matched.
                return nil
            }
            if patternIndex == pattern.count {
                // One byte past the pattern, and it is ASCII: it cannot combine with
                // the preceding cluster, so the prefix genuinely matches.
                return true
            }
            guard foldAscii(byte) == pattern[patternIndex] else {
                return false
            }
            patternIndex += 1
        }
        // Input ended. Matches only if the pattern was fully consumed.
        return patternIndex == pattern.count
    }

    /// Offset of the first occurrence of `pattern` in `bytes`, or `nil`.
    ///
    /// The shared core of `asciiContains`, `asciiContainsExact` and `asciiRange`,
    /// which differ only in whether they fold case and in what they return. Keeping
    /// one loop means one place to audit the bounds, rather than three that can
    /// drift apart.
    ///
    /// Naive O(n*m) on purpose: every needle here is a short compile-time constant,
    /// so a skip table would cost more to build than the scan it saves.
    private static func firstMatch(of pattern: [UInt8],
                                   in bytes: UnsafeBufferPointer<UInt8>,
                                   folding: Bool) -> Int? {
        guard bytes.count >= pattern.count else {
            return nil
        }
        for start in 0...(bytes.count - pattern.count) {
            var offset = 0
            while offset < pattern.count {
                let byte = bytes[start + offset]
                guard (folding ? foldAscii(byte) : byte) == pattern[offset] else {
                    break
                }
                offset += 1
            }
            if offset == pattern.count {
                return start
            }
        }
        return nil
    }

    /// Case-insensitive `contains` over UTF-8 bytes, without allocating.
    ///
    /// Returns `nil` if a non-ASCII byte is reached. Unlike `asciiStarts` this may
    /// have to scan the whole input, which is inherent to a substring search.
    static func asciiContains(_ pattern: [UInt8], input: String) -> Bool? {
        // `String.contains("")` is `false`, unlike `starts(with: "")`/`hasSuffix("")`
        // which are `true`. Preserve that asymmetry exactly.
        if pattern.isEmpty {
            return false
        }
        return withAsciiBytes(of: input) { bytes in
            firstMatch(of: pattern, in: bytes, folding: true) != nil
        }
    }

    /// Runs `body` over `input`'s UTF-8 bytes as a contiguous buffer, or returns
    /// `nil` if any byte is non-ASCII.
    ///
    /// `withContiguousStorageIfAvailable` succeeds for native Swift strings, which
    /// is the case for everything parsed out of a log, so no copy is made. The
    /// fallback path exists for bridged `NSString` storage.
    private static func withAsciiBytes(of input: String,
                                       _ body: (UnsafeBufferPointer<UInt8>) -> Bool) -> Bool? {
        let utf8 = input.utf8
        if let result = utf8.withContiguousStorageIfAvailable({ buffer -> Bool? in
            for byte in buffer where byte >= 0x80 {
                return nil
            }
            return body(buffer)
        }) {
            return result
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(utf8.count)
        for byte in utf8 {
            guard byte < 0x80 else {
                return nil
            }
            bytes.append(byte)
        }
        return bytes.withUnsafeBufferPointer { body($0) }
    }

    /// Case-**sensitive** `contains` over UTF-8 bytes, without allocating.
    ///
    /// Returns `nil` if a non-ASCII byte is reached, meaning the caller must fall
    /// back to `String.range(of:)`/`contains`.
    ///
    /// Distinct from `asciiContains`, which folds case. The call sites this exists
    /// for - compiler flag detection and the deprecation-message checks - use
    /// `range(of:)`/`contains` without options, which does not fold, so folding
    /// here would widen what they match.
    ///
    /// `range(of:)` was a significant share of samples across its call sites. Those
    /// sites test several needles against the same haystack in sequence, so each
    /// one paid a fresh Foundation search over the whole string.
    static func asciiContainsExact(_ pattern: [UInt8], input: String) -> Bool? {
        // `String.contains("")` is `false`; `range(of: "")` is `nil`. Same answer.
        if pattern.isEmpty {
            return false
        }
        return withAsciiBytes(of: input) { bytes in
            firstMatch(of: pattern, in: bytes, folding: false) != nil
        }
    }

    /// The outcome of `asciiRange(of:input:)`.
    ///
    /// Three cases rather than an optional range, because "no match" and "cannot
    /// use the fast path" must not collapse into the same value.
    enum ByteRangeResult {
        /// The pattern was found at this **byte** range.
        case found(Range<Int>)
        /// The input is pure ASCII and does not contain the pattern.
        case notFound
        /// The input is not pure ASCII; fall back to `String.range(of:)`.
        case notAscii
    }

    /// Case-sensitive substring search returning the match's **byte** range.
    ///
    /// For pure-ASCII input a byte offset is also a valid UTF-8 view offset into
    /// the string, because every ASCII byte is its own grapheme cluster - see this
    /// type's doc comment for why that property is what makes byte indexing safe.
    static func asciiRange(of pattern: [UInt8], input: String) -> ByteRangeResult {
        guard !pattern.isEmpty else {
            return .notFound
        }
        // `withAsciiBytes` reports ASCII-ness through its `Bool?` return, which cannot
        // also carry an offset, so the match escapes through this variable. Its `nil`
        // and the closure's are different questions: no match versus not ASCII.
        var found: Range<Int>?
        let isAscii = withAsciiBytes(of: input) { bytes in
            if let start = firstMatch(of: pattern, in: bytes, folding: false) {
                found = start..<(start + pattern.count)
            }
            return true
        }
        guard isAscii != nil else {
            return .notAscii
        }
        return found.map { ByteRangeResult.found($0) } ?? .notFound
    }

    /// Case-insensitive `hasSuffix` over UTF-8 bytes, without allocating.
    ///
    /// Returns `nil` if a non-ASCII byte is reached anywhere in `input`. A
    /// non-ASCII byte before the suffix region still forces the Unicode path,
    /// because it may lowercase into something that shifts cluster boundaries.
    static func asciiHasSuffix(_ pattern: [UInt8], input: String) -> Bool? {
        return withAsciiBytes(of: input) { bytes in
            guard bytes.count >= pattern.count else {
                return false
            }
            let start = bytes.count - pattern.count
            for offset in 0..<pattern.count {
                guard foldAscii(bytes[start + offset]) == pattern[offset] else {
                    return false
                }
            }
            return true
        }
    }
}
