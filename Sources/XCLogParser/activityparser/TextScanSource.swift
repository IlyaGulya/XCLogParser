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

/// A section's text as it is stored, so it can be examined before it is built.
///
/// `IDEActivityLogSection.textForScanning` returns this. The two cases mirror the section's own
/// storage: text that has already been decoded, and a range into the log that has not. Which one a
/// given section is in depends on how the log was read - the eager entry points and the rewriting
/// lexer flags produce `materialized`, `tokenize(data:)` produces `deferred` - and a caller asking a
/// question of the text should not have to care.
///
/// So the questions live here rather than on the cases. Both are answered without allocating: the
/// deferred case goes to `LogBytes`, and the materialized case reads the string's own UTF-8 in place.
enum TextScanSource {
    case materialized(String)
    case deferred(LogBytes, Range<Int>)

    /// Whether the text contains `needle`, without building it.
    ///
    /// `needle` is UTF-8 bytes, which is what the deferred case can compare directly. For the
    /// materialized case that is still the right shape: a `String` holds its own UTF-8, so the
    /// comparison is the same one, and passing bytes keeps callers from re-encoding a literal per call.
    func contains(_ needle: [UInt8]) -> Bool {
        switch self {
        case .materialized(let text):
            guard !needle.isEmpty else {
                return true
            }
            let found: Bool? = text.utf8.withContiguousStorageIfAvailable { bytes -> Bool in
                guard bytes.count >= needle.count, let base = bytes.baseAddress else { return false }
                var offset = 0
                let last = bytes.count - needle.count
                while offset <= last {
                    guard let hit = memchr(base + offset, Int32(needle[0]), last - offset + 1) else {
                        return false
                    }
                    let index = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
                    if memcmp(base + index, needle, needle.count) == 0 {
                        return true
                    }
                    offset = index + 1
                }
                return false
            }
            if let found = found {
                return found
            }
            // No contiguous UTF-8 to borrow. A native Swift string always has some, so this is the
            // bridged-NSString case; going through `String.contains` keeps it correct there.
            return Self.slowContains(text, needle)
        case .deferred(let bytes, let range):
            return bytes.contains(needle, in: range)
        }
    }

    /// A hash of the text, for grouping sections whose text is the same.
    ///
    /// Both cases hash the same bytes with the same function, so a deferred range and the string it
    /// would decode to agree. See `LogBytes.hash(in:)` for why this exists instead of using the
    /// `String` as a dictionary key.
    func hashOfBytes() -> UInt64 {
        switch self {
        case .materialized(let text):
            var hash = Self.fnvOffsetBasis
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* Self.fnvPrime
            }
            return hash
        case .deferred(let bytes, let range):
            return bytes.hash(in: range)
        }
    }

    /// The text itself, decoded if it has to be.
    ///
    /// Does not trim and does not memoise, so this is not a substitute for
    /// `IDEActivityLogSection.text` - it is what a caller uses once a scan has already decided the
    /// text is worth building. Apply `trimmedIfNeeded()` to match what `text` would have returned.
    func decoded() -> String {
        switch self {
        case .materialized(let text):
            return text
        case .deferred(let bytes, let range):
            return bytes.string(in: range)
        }
    }

    /// How many bytes the text is, without building it.
    var byteCount: Int {
        switch self {
        case .materialized(let text):
            return text.utf8.count
        case .deferred(_, let range):
            return range.count
        }
    }

    private static func slowContains(_ text: String, _ needle: [UInt8]) -> Bool {
        guard let needleString = String(bytes: needle, encoding: .utf8) else {
            return false
        }
        return text.contains(needleString)
    }

    private static let fnvOffsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211
}
