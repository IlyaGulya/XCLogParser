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

/// Allocation-free ASCII case-insensitive matching helpers shared by
/// `Prefix`, `Contains` and `Suffix`.
///
/// These pattern-matching types were previously implemented as
/// `input.lowercased().starts(with: pattern)`. That allocates a full lowercased
/// copy of the input for *every* pattern tried. `DetailStepType.getDetailType`
/// is a `switch` over 18 `Prefix` cases, so a single signature could allocate
/// dozens of throwaway strings; DTrace attributed 1,768,517 allocations
/// (16.2% of all allocations in a full parse) to that one function.
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
/// An earlier version of this code gated on a standalone `isAsciiFoldable(input)`
/// that scanned the whole input before comparing anything. That is O(input) work
/// added in front of every match, and for `Prefix` the comparison itself only
/// ever looks at pattern-length bytes - so a 16-byte prefix test paid for a scan
/// of the entire section text. DTrace time profiling put that single function at
/// **14.7% of all samples**, more than twice the 7.4% -> 2.0% it saved in
/// `DetailStepType.getDetailType`: a net loss.
///
/// The functions below instead check ASCII-ness inline, one byte at a time, only
/// for bytes the comparison already has to read. They return `nil` to mean "hit a
/// non-ASCII byte, fall back to Unicode", which keeps the pure-ASCII guarantee
/// while touching the same bytes the match needed anyway. `Prefix` therefore
/// becomes O(pattern) instead of O(input).
///
/// A subtlety this relies on: a non-ASCII byte *beyond* the region the
/// comparison inspects cannot change the answer. For a prefix match, hazard 1
/// needs a combining mark fused to the *last* cluster compared, which is inside
/// the inspected region and so is still seen; hazard 2 needs a non-ASCII scalar
/// that folds to ASCII, which likewise must sit inside the region to affect it.
/// See `asciiStarts` for where that boundary byte is deliberately examined.
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
            guard bytes.count >= pattern.count else {
                return false
            }
            for start in 0...(bytes.count - pattern.count) {
                var offset = 0
                while offset < pattern.count && foldAscii(bytes[start + offset]) == pattern[offset] {
                    offset += 1
                }
                if offset == pattern.count {
                    return true
                }
            }
            return false
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

public struct Prefix {

    let prefix: String

    /// The lowercased pattern's UTF-8 bytes, when the pattern is pure ASCII.
    /// `nil` for non-ASCII patterns, which always take the Unicode slow path.
    private let asciiPrefix: [UInt8]?

    public init(_ prefix: String) {
        self.prefix = prefix.lowercased()
        self.asciiPrefix = CaseFolding.asciiBytes(of: self.prefix)
    }

    private func match(_ input: String) -> Bool {
        if let asciiPrefix = asciiPrefix,
           let fast = CaseFolding.asciiStarts(with: asciiPrefix, input: input) {
            return fast
        }
        return input.lowercased().starts(with: prefix)
    }
}

extension Prefix {
    static func ~= (prefix: Prefix, input: String) -> Bool {
        return prefix.match(input)
    }
}
