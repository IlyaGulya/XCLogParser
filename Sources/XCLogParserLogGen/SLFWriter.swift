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

/// Writes the SLF token stream that `Lexer` reads.
///
/// SLF is a flat, self-delimiting text format: every token is a payload followed by a one-byte
/// type delimiter. There is no framing around a "section" - a section is simply the fields of
/// `ActivityParser.parseIDEActivityLogSection` emitted back to back, so the writer cannot validate
/// structure on its own. What it does guarantee is that each individual token is well formed and
/// that class-name references stay consistent, which is where hand-written SLF goes wrong.
///
/// The delimiters, and the payload each one expects:
///
/// | token          | syntax        | payload                                   |
/// |----------------|---------------|-------------------------------------------|
/// | int            | `123#`        | decimal digits                            |
/// | className      | `4%Name`      | byte count, then that many bytes          |
/// | classNameRef   | `2@`          | 1-based index into the class-name table   |
/// | string         | `5"hello`     | byte count, then that many bytes          |
/// | double         | `...^`        | big-endian bit pattern, lowercase hex     |
/// | list           | `3(`          | element count                             |
/// | json           | `12*{"a":1}`  | byte count, then that many bytes          |
/// | null           | `-`           | nothing                                   |
///
/// String and class-name lengths are **byte** counts, not character counts, so a multi-byte
/// character must not be counted as one. Every length here comes from `.utf8.count`.
public struct SLFWriter {

    /// The declared class names, in declaration order. `classNameRef` is a 1-based index into this.
    private var classNames: [String] = []
    private var out: [UInt8] = []

    public init() {}

    // MARK: - Scalars

    public mutating func int<T: BinaryInteger>(_ value: T) {
        out.append(contentsOf: Array(String(value).utf8))
        out.append(UInt8(ascii: "#"))
    }

    public mutating func string(_ value: String) {
        let bytes = Array(value.utf8)
        out.append(contentsOf: Array(String(bytes.count).utf8))
        out.append(UInt8(ascii: "\""))
        out.append(contentsOf: bytes)
    }

    public mutating func json(_ value: String) {
        let bytes = Array(value.utf8)
        out.append(contentsOf: Array(String(bytes.count).utf8))
        out.append(UInt8(ascii: "*"))
        out.append(contentsOf: bytes)
    }

    /// The lexer reads this as a hex integer and then byte-swaps it, so the digits are the
    /// big-endian bit pattern of the double.
    ///
    /// Zero-padded to all 16 digits. `String(_:radix:)` drops leading zeros, and after the byte swap
    /// the significant bytes sit at the end - so 1.0 renders as "f03f" instead of
    /// "000000000000f03f", and the lexer byte-swaps those 4 digits into a completely different
    /// number. Nothing rejects it, the timestamps just come out as garbage.
    public mutating func double(_ value: Double) {
        let swapped = value.bitPattern.byteSwapped
        let digits = String(swapped, radix: 16)
        out.append(contentsOf: Array(String(repeating: "0", count: 16 - digits.count).utf8))
        out.append(contentsOf: Array(digits.utf8))
        out.append(UInt8(ascii: "^"))
    }

    public mutating func null() {
        out.append(UInt8(ascii: "-"))
    }

    /// A count-prefixed list header. The elements follow as ordinary tokens.
    public mutating func list(_ count: Int) {
        out.append(contentsOf: Array(String(count).utf8))
        out.append(UInt8(ascii: "("))
    }

    // MARK: - Class names

    /// Emits a reference to `name`, declaring it first if this is its first use.
    ///
    /// A declaration does not double as a reference. `getClassRefToken` requires that a `className`
    /// token be *immediately followed* by a `classNameRef`, so a first use emits both - the
    /// declaration and then a ref to it. Emitting only the declaration reads as a missing classRef
    /// and fails at the following token, which is what "Unexpected EOF parsing ClassRef" means here.
    ///
    /// Callers never index the table by hand. The table is append-ordered and shared across the whole
    /// document, so an index is only meaningful relative to every declaration emitted before it -
    /// which is why getting this wrong by hand surfaces as an error in an unrelated later section.
    public mutating func classRef(_ name: String) {
        if let existing = classNames.firstIndex(of: name) {
            reference(to: existing + 1)
            return
        }
        classNames.append(name)
        let bytes = Array(name.utf8)
        out.append(contentsOf: Array(String(bytes.count).utf8))
        out.append(UInt8(ascii: "%"))
        out.append(contentsOf: bytes)
        reference(to: classNames.count)
    }

    private mutating func reference(to index: Int) {
        out.append(contentsOf: Array(String(index).utf8))
        out.append(UInt8(ascii: "@"))
    }

    // MARK: - Output

    /// The token stream, with the `SLF` magic and the log version prepended.
    ///
    /// Only `SLF` is magic; the version that follows is an ordinary int token, and it is the first
    /// thing `parseIDEActiviyLogFromTokens` reads. 10 is what Xcode writes.
    public func document(logVersion: Int = 10) -> Data {
        var header = Array("SLF".utf8)
        header.append(contentsOf: Array(String(logVersion).utf8))
        header.append(UInt8(ascii: "#"))
        return Data(header + out)
    }

    /// Byte count of the token stream so far, excluding the header. Used to report realised sizes.
    public var byteCount: Int { out.count }
}
