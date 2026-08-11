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
}
