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
    private static let fileSchemeBytes = Array("file://".utf8)

    /// Self with the `file://` scheme removed, matching
    /// `replacingOccurrences(of: "file://", with: "")` exactly.
    ///
    /// `Notice.narrowedToOwnDiagnostic` builds a lookup key from this once per non-Swift notice, and
    /// nearly every `documentURL` is a single leading `file://` over an ASCII path.
    ///
    /// The scan is byte-wise on purpose. Do not simplify it to `hasPrefix` plus `contains`: those
    /// are grapheme-cluster operations, so they replace Foundation's one optimised search with two
    /// Unicode-aware walks of the whole path, which measured slower than the call it replaced.
    /// Counting `f` bytes instead means a path with no second `f` after the scheme (the
    /// overwhelming majority) never pays a substring search at all.
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
