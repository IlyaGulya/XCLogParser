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

import XCTest
import Foundation
@testable import XCLogParser

/// Tests for examining a section's text without building it - see `TextScanSource` and the byte
/// methods on `LogBytes`.
///
/// Every question is asked of both cases and the answers compared, because which case a section is in
/// depends only on how the log was read: the same log through `tokenize(data:)` and through
/// `tokenize(contents:)` must agree.
class TextScanSourceTests: XCTestCase {

    /// The same text as a decoded string and as a range into a buffer, with padding either side so a
    /// wrong range shows up as a wrong answer rather than an accident.
    private func bothForms(_ text: String) -> (materialized: TextScanSource, deferred: TextScanSource) {
        let prefix = "<<<PREFIX>>>"
        let suffix = "<<<SUFFIX>>>"
        let padded = prefix + text + suffix
        let bytes = LogBytes(Data(padded.utf8))
        let start = prefix.utf8.count
        let range = start..<(start + text.utf8.count)
        return (.materialized(text), .deferred(bytes, range))
    }

    private func assertBothContain(_ text: String,
                                   _ needle: String,
                                   _ expected: Bool,
                                   _ message: String = "",
                                   file: StaticString = #file,
                                   line: UInt = #line) {
        let forms = bothForms(text)
        let needleBytes = Array(needle.utf8)
        XCTAssertEqual(forms.materialized.contains(needleBytes), expected,
                       "materialized: \(message)", file: file, line: line)
        XCTAssertEqual(forms.deferred.contains(needleBytes), expected,
                       "deferred: \(message)", file: file, line: line)
    }

    func testFindsNeedleAtEachPosition() {
        assertBothContain("123.4ms\t/path/File.swift:1:2\tfoo()", "ms\t", true, "in the middle")
        assertBothContain("ms\ttrailing", "ms\t", true, "at the start")
        assertBothContain("leading ms\t", "ms\t", true, "at the end")
        assertBothContain("ms\t", "ms\t", true, "the whole text")
    }

    func testRejectsNeedleThatIsNotThere() {
        assertBothContain("1.5ms /path/File.swift", "ms\t", false, "space where the tab should be")
        assertBothContain("", "ms\t", false, "empty text")
        assertBothContain("m", "ms\t", false, "text shorter than the needle")
        assertBothContain("msms", "ms\t", false, "first byte repeats without ever matching")
    }

    /// A false start must not stop the scan: `memchr` finds the `m` of the first `ms` and the compare
    /// fails, so the walk has to resume rather than give up.
    func testResumesAfterAPartialMatch() {
        assertBothContain("ms ms ms\t", "ms\t", true, "two false starts before the real one")
        assertBothContain("aaab", "aab", true, "overlapping candidates")
    }

    func testEmptyNeedleIsContainedByDefinition() {
        assertBothContain("anything", "", true, "matching String.contains(\"\")")
        assertBothContain("", "", true, "even in empty text")
    }

    func testHandlesNonAsciiWithoutSplittingScalars() {
        assertBothContain("файл.swift 1.0ms\tтест", "ms\t", true, "multi-byte text around the needle")
        assertBothContain("日本語", "本", true, "needle is a whole multi-byte scalar")
        // The middle byte of a 3-byte scalar. Byte-level containment says yes, and that is the
        // contract: callers use this to pre-filter, then decode and parse properly.
        let continuation = Array("日".utf8)[1...1]
        let forms = bothForms("日本語")
        XCTAssertEqual(forms.materialized.contains(Array(continuation)),
                       forms.deferred.contains(Array(continuation)),
                       "both forms agree even on a partial scalar")
    }

    func testHashAgreesBetweenBothForms() {
        let texts = ["", "a", "ms\t", "123.4ms\t/path/File.swift:1:2\tfoo()", "файл",
                     String(repeating: "x", count: 5_000)]
        for text in texts {
            let forms = bothForms(text)
            XCTAssertEqual(forms.materialized.hashOfBytes(), forms.deferred.hashOfBytes(),
                           "the two forms of \(text.prefix(20)) must hash alike")
        }
    }

    func testHashDistinguishesDifferentText() {
        let first = bothForms("1.0ms\t/path/A.swift:1:1\tfoo()")
        let second = bothForms("1.0ms\t/path/B.swift:1:1\tfoo()")
        XCTAssertNotEqual(first.deferred.hashOfBytes(), second.deferred.hashOfBytes())
        // Order matters, or transposed lines would collide.
        XCTAssertNotEqual(bothForms("ab").deferred.hashOfBytes(),
                          bothForms("ba").deferred.hashOfBytes())
    }

    func testDecodedAgreesBetweenBothFormsAndDoesNotTrim() {
        let text = "  1.0ms\t/path/File.swift:1:1\tfoo()  \n"
        let forms = bothForms(text)
        XCTAssertEqual(forms.materialized.decoded(), text)
        XCTAssertEqual(forms.deferred.decoded(), text, "the deferred form hands back the raw range")
        // The parity that matters for output: `text` trims, this does not, so a caller that wants
        // what `text` would have given must trim after decoding.
        XCTAssertEqual(forms.deferred.decoded().trimmedIfNeeded(), text.trimmedIfNeeded())
    }

    func testByteCountAgreesWithoutDecoding() {
        for text in ["", "ascii", "файл.swift", "日本語"] {
            let forms = bothForms(text)
            XCTAssertEqual(forms.deferred.byteCount, text.utf8.count)
            XCTAssertEqual(forms.materialized.byteCount, forms.deferred.byteCount)
        }
    }

    // MARK: - LogBytes range guards

    func testOutOfBoundsRangesAreRejectedRatherThanTrapping() {
        let bytes = LogBytes(Data("0123456789".utf8))
        let needle = Array("5".utf8)
        XCTAssertFalse(bytes.contains(needle, in: 0..<99), "upper bound past the end")
        XCTAssertFalse(bytes.contains(needle, in: -5..<5), "negative lower bound")
        XCTAssertFalse(bytes.contains(needle, in: 3..<3), "empty range")
        XCTAssertTrue(bytes.contains(needle, in: 0..<10), "the whole buffer still works")
    }

    func testRangeConfinesTheSearch() {
        let bytes = LogBytes(Data("aaaXbbb".utf8))
        let needle = Array("X".utf8)
        XCTAssertTrue(bytes.contains(needle, in: 0..<7))
        XCTAssertFalse(bytes.contains(needle, in: 0..<3), "before the X")
        XCTAssertFalse(bytes.contains(needle, in: 4..<7), "after the X")
        XCTAssertTrue(bytes.contains(needle, in: 3..<4), "exactly the X")
    }

    func testHashOfAnInvalidRangeIsStableRatherThanTrapping() {
        let bytes = LogBytes(Data("0123456789".utf8))
        let empty = bytes.hash(in: 5..<5)
        XCTAssertEqual(bytes.hash(in: -1..<3), empty, "invalid ranges fall back to the empty hash")
        XCTAssertEqual(bytes.hash(in: 0..<99), empty)
        XCTAssertNotEqual(bytes.hash(in: 0..<10), empty, "a valid range hashes its bytes")
    }

    /// The same bytes at different offsets are the same text, so they must hash the same - otherwise
    /// grouping identical section texts would depend on where they sat in the log.
    func testHashIsOffsetIndependent() {
        let bytes = LogBytes(Data("XXfooXXfoo".utf8))
        XCTAssertEqual(bytes.hash(in: 2..<5), bytes.hash(in: 7..<10))
    }

    // MARK: - The section projection

    private func deferredSection(text: String) -> (IDEActivityLogSection, LogBytes) {
        let prefix = "pad"
        let bytes = LogBytes(Data((prefix + text).utf8))
        let range = prefix.utf8.count..<(prefix.utf8.count + text.utf8.count)
        let section = IDEActivityLogSection(sectionType: 1,
                                           domainType: "",
                                           title: "title",
                                           signature: "SwiftCompile normal arm64 File.swift",
                                           timeStartedRecording: 0,
                                           timeStoppedRecording: 1,
                                           subSections: [],
                                           sectionText: .range(range, logBytes: bytes),
                                           messages: [],
                                           wasCancelled: false,
                                           isQuiet: false,
                                           wasFetchedFromCache: false,
                                           subtitle: "",
                                           location: DVTDocumentLocation(documentURLString: "", timestamp: 0),
                                           commandDetailDesc: "",
                                           uniqueIdentifier: "id",
                                           localizedResultString: "",
                                           xcbuildSignature: "",
                                           attachments: [],
                                           unknown: 0)
        return (section, bytes)
    }

    /// The point of the projection: scanning must not decode, so a section nothing wants stays
    /// deferred. If `textForScanning` reached for `text`, this would report `materialized`.
    func testScanningDoesNotMaterialiseTheSection() {
        let (section, _) = deferredSection(text: "1.0ms\t/path/File.swift:1:1\tfoo()")
        guard case .deferred = section.textForScanning else {
            return XCTFail("a freshly built section should still be deferred")
        }
        XCTAssertTrue(section.textForScanning.contains(Array("ms\t".utf8)))
        _ = section.textForScanning.hashOfBytes()
        guard case .deferred = section.textForScanning else {
            return XCTFail("scanning must not have materialised the text")
        }
    }

    /// And once something does read `text`, the projection follows the storage over to the decoded
    /// case - still answering the same questions, so a caller cannot tell the difference.
    func testProjectionFollowsTheStorageAfterTextIsRead() {
        let raw = "  1.0ms\t/path/File.swift:1:1\tfoo()  "
        let (section, _) = deferredSection(text: raw)
        let beforeHash = section.textForScanning.hashOfBytes()
        XCTAssertEqual(section.text, raw.trimmedIfNeeded(), "text trims when it decodes")
        guard case .materialized = section.textForScanning else {
            return XCTFail("reading text should have memoised it")
        }
        XCTAssertTrue(section.textForScanning.contains(Array("ms\t".utf8)),
                      "the same question still answers the same way")
        // The hash changes, because `text` trimmed and the deferred range did not. Worth pinning: a
        // caller that mixes hashes taken before and after a read would be grouping different bytes.
        XCTAssertNotEqual(beforeHash, section.textForScanning.hashOfBytes(),
                          "trimming changes the bytes, so it changes the hash")
    }
}
