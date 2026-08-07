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

/// Materialising a byte range of a scanned buffer back into a `String`.
///
/// The byte-wise scanners in this directory all share one shape: walk the section's UTF-8 once
/// recording `Range<Int>`, then build a `String` for the few ranges that turned out to matter. Each
/// of them had grown its own copy of this conversion, which is the only part of that shape they
/// have in common.
///
/// # `parseSwiftIssues` deliberately does not call `string(in:)`
///
/// It keeps its own private copy, as a `static` on `Notice`. Routing its two calls through this
/// extension instead costs **+14,225 allocations** on the baseline log and **+35,303** on the
/// flagged fleet log, measured in the BuildStep stage where every other counter stays identical to
/// the event.
///
/// The cause is the receiver, not the file or the call syntax. Three things were tried and none
/// recovered the count: `@inline(__always)`, `@inlinable`, and moving the method next to its caller.
/// What does recover it exactly - to 1,682,277, matching the commit before - is making it a `static`
/// on a concrete type in this module again. A method on `UnsafeBufferPointer<UInt8>`, a generic
/// standard-library type, does not optimise the same way for a call made once per section.
///
/// `append(range:to:)` is a different story and is shared: it is called only for continuation lines,
/// which are rare, and moving it changes nothing. The two cold scanners
/// (`ClangWarningFlagScanner`, `SwiftIssueMarkerScanner`) likewise use `string(in:)` for free -
/// measured, not assumed.
///
/// So the rule this file embodies is narrower than "share the helper": share it everywhere except
/// the one path that runs per section.
extension UnsafeBufferPointer where Element == UInt8 {

    /// The UTF-8 in `range`, decoded.
    ///
    /// Every caller slices a buffer that already holds the log's own UTF-8. `parseSwiftIssues` and
    /// `ClangWarningFlagScanner` cut only at ASCII boundaries - line breaks, `:` markers, flag
    /// delimiters - so no scalar is split and the non-failable initializer is exact.
    /// `SwiftIssueMarkerScanner` is the exception and says so at its call site: it takes a fixed
    /// 4-byte window that may end mid-scalar, which is harmless because it reads only the first one.
    ///
    /// An empty buffer has no base address, which is why the range is not simply subscripted.
    func string(in range: Range<Int>) -> String {
        guard let base = baseAddress else {
            return ""
        }
        // The rule wants a failable initializer, but the slices here are exact by construction - see
        // above - so there is nothing for it to report.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: UnsafeBufferPointer(start: base + range.lowerBound,
                                                    count: range.count), as: UTF8.self)
    }

    /// Copies `self[range]` onto the end of `out`.
    func append(range: Range<Int>, to out: inout [UInt8]) {
        guard let base = baseAddress else {
            return
        }
        out.append(contentsOf: UnsafeBufferPointer(start: base + range.lowerBound,
                                                   count: range.count))
    }
}
