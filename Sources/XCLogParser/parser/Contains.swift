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

public struct Contains {

    let str: String

    /// The lowercased pattern's UTF-8 bytes, when the pattern is pure ASCII.
    /// `nil` for non-ASCII patterns, which always take the Unicode slow path.
    private let asciiStr: [UInt8]?

    public init(_ str: String) {
        self.str = str.lowercased()
        self.asciiStr = CaseFolding.asciiBytes(of: self.str)
    }

    /// See `CaseFolding` for why the ASCII fast path is behaviour-preserving.
    private func match(_ input: String) -> Bool {
        if let asciiStr = asciiStr,
           let fast = CaseFolding.asciiContains(asciiStr, input: input) {
            return fast
        }
        return input.lowercased().contains(str)
    }
}

extension Contains {
    static func ~= (contains: Contains, input: String) -> Bool {
        return contains.match(input)
    }
}
