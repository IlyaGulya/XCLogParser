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

/// A pretty-printing JSON byte buffer, written to directly instead of through `Encodable`.
///
/// # Why this exists
///
/// `JSONEncoder` was the largest single cost in the tool, and `BuildStep.encode(to:)` alone was a large share of
/// all allocations - 918,336 of them over 42,148 steps, about 22 per step for a type with ~26
/// fields. That is one allocation per field: the compiler-synthesized `encode(to:)` funnels every
/// field through `KeyedEncodingContainer`, which boxes each value in an existential. The ARC
/// traffic those allocations generate showed up independently as 19-21% of self time in a DTrace
/// profile.
///
/// The fix is to stop describing the data to a generic encoder and just write the bytes. Field
/// names are `StaticString`s copied straight from the binary, so no `CodingKey` metadata is
/// instantiated and no protocol conformance is looked up.
///
/// Note this is *not* the same problem as swiftlang/swift-foundation#1480, which is about
/// `swift_conformsToProtocol` being slow in apps with very many protocol conformances. That cost is
/// paid once per (type, protocol) pair and then cached; with ~30 `Codable` types and 42,148
/// same-typed values, it is not what this tool pays. The cost here is per-value boxing.
///
/// # Format compatibility
///
/// Output matches `JSONEncoder` with `.prettyPrinted` - two-space indent, `" : "` between key and
/// value - with two deliberate differences, both agreed with the user:
///
///   - **Key order is declaration order.** `JSONEncoder` emits hash-table order, which is unstable
///     between runs, so the old output could not be diffed byte-for-byte against itself. Fixing the
///     order makes it deterministic. JSON objects are unordered per spec, so no parser is affected.
///   - **Empty arrays are `[]`**, not Foundation's `[\n\n      ]` artifact.
///
/// Field names, types, nesting and `null` for optionals are unchanged.
struct JSONWriter {

    private(set) var bytes: [UInt8] = []

    /// How deep the current object/array nesting is, in indent levels.
    private var depth = 0

    /// Whether a value has already been written at the current nesting level, which is what decides
    /// whether the next one needs a leading comma.
    private var hasPrecedingValue = false

    /// Nesting state is a stack because closing a container has to restore the parent's comma flag.
    private var parentHadValue: [Bool] = []

    init(reservingCapacity capacity: Int = 0) {
        if capacity > 0 { bytes.reserveCapacity(capacity) }
    }

    /// Hands the written bytes over as `Data` without copying them.
    ///
    /// `Data(writer.bytes)` would copy, holding two full buffers alive at once - on a 170 MB report
    /// that measured as +17 MB baseline / +34 MB flagged in peak RSS. (Only *some* of the copy shows
    /// up because the report is written and released promptly; the same trap as in `Gunzip`, where
    /// `phys_footprint` missed a transient double that peak RSS saw plainly.)
    ///
    /// `Array` will not release its allocation to `Data`, so the bytes move once into `malloc`ed
    /// memory that `Data` then adopts with `.free`. That is one copy instead of one copy plus a
    /// second live 170 MB buffer, and the array is released immediately afterwards. `malloc` rather
    /// than `UnsafeMutableRawPointer.allocate` because `.free` calls `free()`.
    consuming func makeData() -> Data {
        let count = bytes.count
        guard count > 0 else { return Data() }
        guard let allocation = malloc(count) else { return Data(bytes) }
        bytes.withUnsafeBytes { source in
            _ = memcpy(allocation, source.baseAddress!, count)
        }
        bytes = []
        return Data(bytesNoCopy: allocation, count: count, deallocator: .free)
    }

    mutating func removeAll(keepingCapacity: Bool = true) {
        bytes.removeAll(keepingCapacity: keepingCapacity)
        depth = 0
        hasPrecedingValue = false
        parentHadValue.removeAll(keepingCapacity: true)
    }

    // MARK: - Containers

    mutating func beginObject() {
        writeSeparatorIfNeeded()
        bytes.append(UInt8(ascii: "{"))
        pushLevel()
    }

    mutating func endObject() {
        popLevel(closing: UInt8(ascii: "}"))
    }

    mutating func beginArray() {
        writeSeparatorIfNeeded()
        bytes.append(UInt8(ascii: "["))
        pushLevel()
    }

    mutating func endArray() {
        popLevel(closing: UInt8(ascii: "]"))
    }

    /// Names the next value. `JSONEncoder`'s pretty printer puts spaces around the colon.
    ///
    /// Keys are `StaticString` so the bytes are memcpy'd from the binary's constant data - no
    /// `String` is created and no `CodingKey` metadata is instantiated.
    mutating func key(_ name: StaticString) {
        writeSeparatorIfNeeded()
        bytes.append(UInt8(ascii: "\""))
        append(name)
        bytes.append(contentsOf: [UInt8(ascii: "\""), UInt8(ascii: " "),
                                 UInt8(ascii: ":"), UInt8(ascii: " ")])
        // The key already counts as this level's entry - `writeSeparatorIfNeeded` above set the flag
        // and emitted any comma. The value that follows belongs to the same entry, so it must not
        // emit a second separator or indent.
        suppressSeparator = true
    }

    /// Set by `key(_:)` so the value it names is not treated as a new comma-separated entry.
    private var suppressSeparator = false

    private mutating func writeSeparatorIfNeeded() {
        if suppressSeparator {
            suppressSeparator = false
            return
        }
        if hasPrecedingValue {
            bytes.append(UInt8(ascii: ","))
        }
        hasPrecedingValue = true
        if depth > 0 {
            newlineAndIndent(depth)
        }
    }

    private mutating func pushLevel() {
        parentHadValue.append(hasPrecedingValue)
        depth += 1
        hasPrecedingValue = false
    }

    private mutating func popLevel(closing terminator: UInt8) {
        depth -= 1
        // An empty container closes immediately: `[]`, not Foundation's `[\n\n  ]`.
        if hasPrecedingValue {
            newlineAndIndent(depth)
        }
        bytes.append(terminator)
        hasPrecedingValue = parentHadValue.popLast() ?? false
    }

    private mutating func newlineAndIndent(_ levels: Int) {
        bytes.append(UInt8(ascii: "\n"))
        for _ in 0..<levels {
            bytes.append(contentsOf: [UInt8(ascii: " "), UInt8(ascii: " ")])
        }
    }

    private mutating func append(_ text: StaticString) {
        text.withUTF8Buffer { bytes.append(contentsOf: $0) }
    }

    // MARK: - Scalars

    mutating func value(_ flag: Bool) {
        writeSeparatorIfNeeded()
        append(flag ? "true" : "false")
    }

    mutating func value(_ number: Int) {
        writeSeparatorIfNeeded()
        appendInteger(number)
    }

    mutating func value(_ number: UInt64) {
        writeSeparatorIfNeeded()
        appendUnsigned(number)
    }

    /// Writes a `Double` the way `JSONEncoder` does.
    ///
    /// Foundation prints shortest-round-trip and drops a trailing `.0`, so it writes `3` where
    /// Swift's `description` writes `3.0`. Verified against `JSONEncoder` over 400,000 values
    /// (every finite one from a xorshift bit-pattern sweep plus hand-picked edge cases): Foundation's
    /// output is exactly `description` with a trailing `.0` removed, with zero mismatches. That
    /// matters here because integral durations - `0` on every non-compilation step - are common in
    /// real logs, so getting this wrong would change most steps.
    ///
    /// Non-finite values cannot occur in this model (durations are differences of finite timestamps)
    /// and `JSONEncoder` throws on them; they are written as `null` rather than emitting the invalid
    /// JSON `inf`.
    mutating func value(_ number: Double) {
        writeSeparatorIfNeeded()
        guard number.isFinite else {
            append("null")
            return
        }
        var text = number.description
        if text.hasSuffix(".0") {
            text.removeLast(2)
        }
        bytes.append(contentsOf: text.utf8)
    }

    mutating func value(_ text: String) {
        writeSeparatorIfNeeded()
        appendQuoted(text)
    }

    mutating func value(_ text: StaticString) {
        writeSeparatorIfNeeded()
        bytes.append(UInt8(ascii: "\""))
        append(text)
        bytes.append(UInt8(ascii: "\""))
    }

    mutating func null() {
        writeSeparatorIfNeeded()
        append("null")
    }

    // MARK: - Keyed convenience

    mutating func field(_ name: StaticString, _ value: String) {
        key(name)
        self.value(value)
    }

    mutating func field(_ name: StaticString, _ value: Double) {
        key(name)
        self.value(value)
    }

    mutating func field(_ name: StaticString, _ value: Int) {
        key(name)
        self.value(value)
    }

    mutating func field(_ name: StaticString, _ value: UInt64) {
        key(name)
        self.value(value)
    }

    mutating func field(_ name: StaticString, _ value: Bool) {
        key(name)
        self.value(value)
    }

    /// An optional field. A `nil` writes **no key at all**, which is what `JSONEncoder` does for a
    /// synthesized `encode(to:)`: it calls `encodeIfPresent`, so an absent optional is an absent key
    /// rather than an explicit `null`. Emitting `null` here would have added a key to every step that
    /// has no warnings - a schema change, and the schema is meant to be untouched.
    mutating func field(_ name: StaticString, _ value: String?) {
        guard let value = value else { return }
        key(name)
        self.value(value)
    }

    // MARK: - Number formatting

    private mutating func appendInteger(_ number: Int) {
        if number < 0 {
            bytes.append(UInt8(ascii: "-"))
            // Negating `Int.min` overflows, so widen through the magnitude instead.
            appendUnsigned(UInt64(number.magnitude))
        } else {
            appendUnsigned(UInt64(number))
        }
    }

    /// Writes the decimal digits of `number` without going through `String`.
    ///
    /// Digits go into a fixed-size stack buffer, not a `[UInt8]`. The array version allocated once
    /// per number wider than a single digit, which was a measurable share of the
    /// total - on the flagged benchmark log, all of it scratch space discarded immediately. This is
    /// the same trade `ISO8601DateString.format` makes for the same reason.
    ///
    /// `UInt64.max` is 20 digits, so the 24-byte buffer cannot overflow and the loop needs no
    /// bounds check beyond `remaining > 0`.
    private mutating func appendUnsigned(_ number: UInt64) {
        if number < 10 {
            bytes.append(UInt8(ascii: "0") + UInt8(number))
            return
        }
        var buffer = (UInt64(0), UInt64(0), UInt64(0))
        withUnsafeMutableBytes(of: &buffer) { raw in
            let digits = raw.bindMemory(to: UInt8.self)
            var index = 20
            var remaining = number
            while remaining > 0 {
                index -= 1
                digits[index] = UInt8(ascii: "0") + UInt8(remaining % 10)
                remaining /= 10
            }
            bytes.append(contentsOf: UnsafeBufferPointer(rebasing: digits[index..<20]))
        }
    }

    // MARK: - String escaping

    /// Escapes and quotes `text` per RFC 8259, matching `JSONEncoder`'s choices.
    ///
    /// The exact set was read off `JSONEncoder` rather than from the spec, by encoding every ASCII
    /// scalar plus `/`, DEL, U+2028, U+2029 and non-ASCII and dumping the bytes:
    ///
    ///   - `"` and `\` escape, as required
    ///   - the five named control characters use their short forms (`\b \t \n \f \r`)
    ///   - the rest of C0 uses `\u00xx` with **lowercase** hex
    ///   - **`/` escapes to `\/`.** RFC 8259 makes this optional and most encoders skip it, but
    ///     Foundation does it, and a build log is almost entirely paths - so omitting it would have
    ///     changed nearly every string in the report.
    ///   - DEL, U+2028, U+2029 and all non-ASCII pass through, so multi-byte UTF-8 is copied as-is
    ///
    /// The common case in a build log is a path or a message with nothing to escape, so the scan
    /// copies runs of clean bytes in bulk rather than byte at a time.
    private mutating func appendQuoted(_ text: String) {
        bytes.append(UInt8(ascii: "\""))
        let utf8 = text.utf8
        // Native Swift strings expose contiguous UTF-8, so this is the path real data takes. A
        // bridged `NSString` may not, hence the copy fallback.
        if utf8.withContiguousStorageIfAvailable({ appendQuotedBody($0) }) == nil {
            appendQuotedBody(ContiguousArray(utf8))
        }
        bytes.append(UInt8(ascii: "\""))
    }

    private mutating func appendQuotedBody<Bytes: Collection>(_ buffer: Bytes)
        where Bytes.Element == UInt8, Bytes.Index == Int {
        var runStart = buffer.startIndex
        var index = runStart
        while index < buffer.endIndex {
            let byte = buffer[index]
            guard byte < 0x20 || byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\")
                    || byte == UInt8(ascii: "/") else {
                index += 1
                continue
            }
            if runStart < index {
                bytes.append(contentsOf: buffer[runStart..<index])
            }
            appendEscape(byte)
            index += 1
            runStart = index
        }
        if runStart < buffer.endIndex {
            bytes.append(contentsOf: buffer[runStart..<buffer.endIndex])
        }
    }

    private mutating func appendEscape(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "\""): append("\\\"")
        case UInt8(ascii: "\\"): append("\\\\")
        case UInt8(ascii: "/"): append("\\/")
        case 0x08: append("\\b")
        case 0x09: append("\\t")
        case 0x0A: append("\\n")
        case 0x0C: append("\\f")
        case 0x0D: append("\\r")
        default:
            append("\\u00")
            let hex: StaticString = "0123456789abcdef"
            hex.withUTF8Buffer { digits in
                bytes.append(digits[Int(byte >> 4)])
                bytes.append(digits[Int(byte & 0x0F)])
            }
        }
    }
}
