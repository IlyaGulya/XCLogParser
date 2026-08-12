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

/// The decompressed log, kept alive so byte ranges into it stay valid.
///
/// The lexer materialises a `String` for every string token, and `IDEActivityLogSection.text` is 91%
/// of those bytes on the baseline log - of which 93% belongs to sections whose `messages` is empty,
/// where `Notice.parseFromLogSection` returns before reading the text at all. Handing the section a
/// range into this object instead of a `String` means that text is never built.
///
/// A reference type on purpose: every section holding a range shares one buffer, and the log outlives
/// them all only because they retain it.
///
/// Internal, unlike the `LazyString` it backs: `LazyString` has to be public because it is what
/// `Token.string` carries, but this buffer is only ever produced by the lexer and consumed by the
/// parser. A public `LogBytes` would be a type a caller could construct and then find nothing to do
/// with, since resolving a range through it is a package-internal operation.
final class LogBytes {
    private let data: Data

    init(_ data: Data) {
        self.data = data
    }

    /// The UTF-8 in `range`, decoded.
    ///
    /// Invalid sequences become U+FFFD, matching `Scanner.string(in:)` - the two must agree, because
    /// which one produced a given section's text is an internal detail.
    func string(in range: Range<Int>) -> String {
        guard range.lowerBound >= 0, range.upperBound <= data.count, !range.isEmpty else {
            return ""
        }
        return data.withUnsafeBytes { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            let bytes = UnsafeRawBufferPointer(start: base + range.lowerBound, count: range.count)
            // The rule wants a failable initializer, but U+FFFD substitution is the behaviour we want -
            // `Scanner.string(in:)` does the same, and the two must agree.
            // swiftlint:disable:next optional_data_string_conversion
            return String(decoding: bytes.bindMemory(to: UInt8.self), as: UTF8.self)
        }
    }

    /// Whether `range` contains `needle`, without decoding anything.
    ///
    /// For asking a cheap question of a section's text before deciding to build it. `string(in:)`
    /// followed by `contains` answers the same question, but pays for the whole `String` first - and
    /// the callers here are looking for a marker that most sections do not have, so most of those
    /// strings would be built only to be thrown away.
    ///
    /// `needle` is bytes rather than a `String` so a caller can hold a `static let` of it and not
    /// re-encode per call. An empty needle is contained by definition, matching `String.contains("")`.
    func contains(_ needle: [UInt8], in range: Range<Int>) -> Bool {
        guard !needle.isEmpty else {
            return true
        }
        guard range.lowerBound >= 0, range.upperBound <= data.count, range.count >= needle.count else {
            return false
        }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            let bytes = UnsafeRawBufferPointer(start: base + range.lowerBound, count: range.count)
                .bindMemory(to: UInt8.self)
            let first = needle[0]
            // Walk to each occurrence of the first byte, then compare the rest. `memchr` does the
            // scanning, so the per-byte loop only runs where the needle could actually start.
            var offset = 0
            let last = bytes.count - needle.count
            while offset <= last {
                guard let hit = memchr(bytes.baseAddress! + offset, Int32(first), last - offset + 1) else {
                    return false
                }
                let index = UnsafeRawPointer(hit) - UnsafeRawPointer(bytes.baseAddress!)
                if memcmp(bytes.baseAddress! + index, needle, needle.count) == 0 {
                    return true
                }
                offset = index + 1
            }
            return false
        }
    }

    /// A hash of the bytes in `range`, for recognising two ranges that hold the same text.
    ///
    /// The point is to compare section texts without building them. The obvious spelling - use the
    /// `String` as a dictionary key - hashes and compares the whole text on every insert, and section
    /// texts here run to a megabyte each, so that cost lands once per section and dominates
    /// everything around it.
    ///
    /// FNV-1a: it is a few lines, it needs no allocation, and callers use it only to group ranges
    /// that they then confirm. Not for security, and not stable across releases - do not persist it.
    func hash(in range: Range<Int>) -> UInt64 {
        guard range.lowerBound >= 0, range.upperBound <= data.count, !range.isEmpty else {
            return Self.fnvOffsetBasis
        }
        return data.withUnsafeBytes { raw -> UInt64 in
            guard let base = raw.baseAddress else { return Self.fnvOffsetBasis }
            let bytes = UnsafeRawBufferPointer(start: base + range.lowerBound, count: range.count)
                .bindMemory(to: UInt8.self)
            var hash = Self.fnvOffsetBasis
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* Self.fnvPrime
            }
            return hash
        }
    }

    private static let fnvOffsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211
}
