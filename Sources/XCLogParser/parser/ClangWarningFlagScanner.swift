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
    /// Byte-level equivalent of `Notice.clangWarningRegexp` (`\[(-W[\w-,]*)\]+`) for all-ASCII text,
    /// or `nil` when the text needs the real regex.
    ///
    /// This runs on the full text of every log section that reaches `parseFromLogSection`, and ICU
    /// dominated it: time profiling put `parseClangWarningFlags` among the hottest functions in
    /// a full parse, essentially all of it inside `NSRegularExpression.matches`. The pattern itself is
    /// simple enough to match with a single forward pass over the UTF-8 bytes, so the ICU cost buys
    /// nothing here.
    ///
    /// Deliberately kept general rather than tuned to any particular set of flags - it recognises
    /// whatever the regex recognises, including flags that are not real clang warnings.
    ///
    /// # Why it can bail out
    ///
    /// `\w` is Unicode-aware, so `[-Wдлина]` is a match for the regex. Rather than reimplement
    /// Unicode word-character classification, this returns `nil` when a non-ASCII byte turns up where
    /// it could extend a flag body - immediately after `[-W` and its ASCII body bytes - and lets the
    /// regex handle the whole string.
    ///
    /// Note the narrowness of that test: it deliberately does **not** bail on non-ASCII anywhere in
    /// the text, and widening it that way makes the scanner close to useless. Real logs are
    /// overwhelmingly ASCII but not entirely, and the few non-ASCII bytes are spread widely enough
    /// that almost every section contains one - so a whole-text test sends almost every section
    /// through ICU anyway. Elsewhere in the text a non-ASCII byte cannot affect the result, because
    /// no match can begin on one.
    ///
    /// Two details of the pattern are easy to get wrong, and both are covered by
    /// `ClangWarningFlagsTests`:
    ///
    /// - The returned strings are the *whole* match, not the capture group, so they keep the brackets
    ///   and **every** trailing `]`: `"[[-Wx]]"` yields `"[-Wx]]"`.
    /// - The flag body may be empty and may be punctuation only, because `[\w-,]*` accepts zero
    ///   characters and includes `-` and `,`: `"[-W]"` and `"[-W-,,-]"` both match.
    ///
    /// Unlike `parseSwiftIssuesDetailsByLocation`, this reaches the bytes through
    /// `withContiguousStorageIfAvailable` rather than `withCString`: section text can contain embedded
    /// NUL bytes, which `withCString`'s length scan would treat as the end of the string. The regex
    /// looks past a NUL, so stopping there would drop flags.
    static func asciiClangWarningFlags(text: String) -> [String]? {
        var flags: [String]? = []
        let completed = text.utf8.withContiguousStorageIfAvailable { bytes -> Bool in
            var index = 0
            while index < bytes.count {
                // A match must start with the literal "[-W". Non-ASCII bytes outside a candidate need
                // no special handling: no match can start on one, and a leading byte of a multi-byte
                // scalar is never "[", so skipping them one byte at a time is correct.
                guard bytes[index] == UInt8(ascii: "["), index + 2 < bytes.count,
                      bytes[index + 1] == UInt8(ascii: "-"), bytes[index + 2] == UInt8(ascii: "W") else {
                    index += 1
                    continue
                }
                var cursor = index + 3
                while cursor < bytes.count, isFlagBodyByte(bytes[cursor]) {
                    cursor += 1
                }
                if cursor < bytes.count, bytes[cursor] >= 0x80 {
                    return false
                }
                // `\]+` is greedy but requires at least one bracket; without it there is no match and
                // scanning resumes just past the "[", exactly as the regex engine would.
                guard cursor < bytes.count, bytes[cursor] == UInt8(ascii: "]") else {
                    index += 1
                    continue
                }
                while cursor < bytes.count, bytes[cursor] == UInt8(ascii: "]") {
                    cursor += 1
                }
                flags?.append(flagString(from: bytes, range: index..<cursor))
                index = cursor
            }
            return true
        }
        // A non-contiguous UTF-8 string gives `nil` from `withContiguousStorageIfAvailable`, which is
        // indistinguishable here from the non-ASCII bail-out - both mean "let the regex handle it".
        guard completed == true else {
            return nil
        }
        return flags
    }

    /// Whether `byte` is in the regex's `[\w-,]` class, restricted to ASCII.
    private static func isFlagBodyByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: ","):
            return true
        default:
            return false
        }
    }

    /// Materialises `bytes[range]` as a `String`.
    private static func flagString(from bytes: UnsafeBufferPointer<UInt8>,
                                   range: Range<Int>) -> String {
        guard let base = bytes.baseAddress else {
            return ""
        }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: UnsafeBufferPointer(start: base + range.lowerBound,
                                                    count: range.count), as: UTF8.self)
    }
}
