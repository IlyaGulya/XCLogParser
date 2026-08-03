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

/// A membership test over the 256 possible byte values, as a bitmap.
///
/// This replaces `Set<UInt8>` in the lexer's scanning loops. The sets involved are tiny and fixed
/// (`"abcdef0123456789"`, the SLF type delimiters), but `Set.contains` still hashes the element and
/// probes a heap-allocated buffer, and it ran once per byte over the whole log - `scanCharacters` was
/// the single hottest function in the lexer.
///
/// A byte can only take 256 values, so the entire domain fits in four `UInt64` words held inline in the
/// struct. Membership becomes a shift and a mask against a value already in registers, with no hashing
/// and no memory indirection.
struct ByteSet {

    /// Bit `n` of word `n / 64` is set when byte `n` is a member.
    ///
    /// A tuple rather than an array so the 32 bytes live inline in the struct: an array would put them
    /// behind a heap allocation and a retain/release, which is the indirection this type exists to
    /// avoid. The four members are homogeneous storage, not distinct values.
    private var words: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0) // swiftlint:disable:this large_tuple

    init(_ bytes: some Sequence<UInt8>) {
        for byte in bytes {
            insert(byte)
        }
    }

    private mutating func insert(_ byte: UInt8) {
        let bit = UInt64(1) << UInt64(byte % 64)
        switch byte / 64 {
        case 0: words.0 |= bit
        case 1: words.1 |= bit
        case 2: words.2 |= bit
        default: words.3 |= bit
        }
    }

    func contains(_ byte: UInt8) -> Bool {
        let bit = UInt64(1) << UInt64(byte % 64)
        let word: UInt64
        switch byte / 64 {
        case 0: word = words.0
        case 1: word = words.1
        case 2: word = words.2
        default: word = words.3
        }
        return word & bit != 0
    }
}
