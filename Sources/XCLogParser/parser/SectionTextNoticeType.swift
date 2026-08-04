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

/// `NoticeType.fromTitle(logSection.text)`, computed on first use and reused for the whole section.
///
/// A message with an empty `categoryIdent` is classified from the entire section text instead of its
/// own title, and that text is the same string for every message in the section - so the resulting
/// `NoticeType` is the same too. `fromTitle` is not free on such an input: one of its cases is a
/// `Contains("Command PhaseScriptExecution")` over the full text.
///
/// A class, so the memoised value is shared by every message in the section rather than copied per
/// message. It stays lazy because the empty-`categoryIdent` case is rare - 1 of 21,701 messages on
/// baseline-noflags, 2 of 12,888 on flagged-10x-fleet - so classifying every section eagerly would
/// add work to the common path in order to save it on a rare one.
final class SectionTextNoticeType {
    private let text: String
    private var computed = false
    private var value: NoticeType?

    init(text: String) {
        self.text = text
    }

    var noticeType: NoticeType? {
        if !computed {
            value = NoticeType.fromTitle(text)
            computed = true
        }
        return value
    }
}

extension String {
    private static let fileSchemeBytes = Array("file://".utf8)

    /// Self with the `file://` scheme removed, matching
    /// `replacingOccurrences(of: "file://", with: "")` exactly.
    ///
    /// `Notice.narrowedToOwnDiagnostic` builds a lookup key from this once per non-Swift notice -
    /// 11,561 and 18,985 times on the two benchmark logs - and 99.0% of `documentURL`s are a single
    /// leading `file://` over an ASCII path.
    ///
    /// The scan is byte-wise on purpose. An earlier version used `hasPrefix` plus `contains`, which
    /// are grapheme-cluster operations: two Unicode-aware walks of the whole path where Foundation
    /// did one optimised search. Measured interleaved on the BuildStep stage, that was **+34 to
    /// +48 ms against the Foundation call it replaced** - a regression, not a saving. Counting `f`
    /// bytes instead means a path with no second `f` after the scheme (the overwhelming majority)
    /// never pays a substring search at all.
    ///
    /// Any input this cannot decide byte-wise - a non-ASCII byte anywhere, or a further `file://`
    /// occurrence - falls back to Foundation, so every input keeps its old result. That matters for
    /// more than tidiness: `String` equality is by grapheme cluster, so a combining mark fused to the
    /// scheme's final `/` makes Foundation report no match where raw bytes would.
    var withoutFileScheme: String {
        let scheme = Self.fileSchemeBytes
        let decided: String? = utf8.withContiguousStorageIfAvailable { bytes in
            guard bytes.count >= scheme.count else { return nil }
            for index in 0..<scheme.count where bytes[index] != scheme[index] {
                return nil
            }
            // A second `f` after the scheme could start another occurrence, and a non-ASCII byte
            // could fuse a combining mark onto the scheme. Either way, let Foundation decide.
            for index in scheme.count..<bytes.count where bytes[index] >= 0x80
                || bytes[index] == UInt8(ascii: "f") {
                return nil
            }
            // swiftlint:disable:next optional_data_string_conversion
            return String(decoding: bytes[scheme.count...], as: UTF8.self)
        } ?? nil
        if let decided = decided {
            return decided
        }
        return replacingOccurrences(of: "file://", with: "")
    }
}
