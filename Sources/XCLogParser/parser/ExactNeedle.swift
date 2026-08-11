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

/// A literal needle for case-sensitive substring search, with its UTF-8 bytes
/// precomputed.
///
/// Declare one as a `static let` per needle so the bytes are encoded once rather
/// than per call, then use `matches(_:)` in place of
/// `haystack.range(of: needle) != nil` or `haystack.contains(needle)`.
struct ExactNeedle {

    private let text: String

    /// The needle's UTF-8 bytes, or `nil` if it is not pure ASCII - in which case
    /// every search falls back to Foundation.
    private let asciiBytes: [UInt8]?

    init(_ text: String) {
        self.text = text
        self.asciiBytes = CaseFolding.asciiBytes(of: text)
    }

    /// Whether `haystack` contains this needle. Equivalent to
    /// `haystack.contains(text)`, including for non-ASCII input.
    func matches(_ haystack: String) -> Bool {
        if let asciiBytes = asciiBytes,
           let fast = CaseFolding.asciiContainsExact(asciiBytes, input: haystack) {
            return fast
        }
        return haystack.contains(text)
    }
}
