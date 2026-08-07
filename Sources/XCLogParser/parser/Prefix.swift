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

/// A case-insensitive prefix pattern, usable as a `switch` case via `~=`.
///
/// The match is `CaseFolding.asciiStarts` where it applies and `lowercased().starts(with:)`
/// otherwise; see `CaseFolding` for why the fast path is gated on both sides being pure ASCII.
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
