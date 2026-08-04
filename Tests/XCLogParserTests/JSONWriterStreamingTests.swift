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
@testable import XCLogParser

/// Streaming the report out in chunks instead of buffering all of it. See `JSONWriter+Streaming`.
///
/// Separate from `JSONWriterTests` because that class is already at the type-body-length limit; the
/// step fixture is shared, so the two cannot disagree about what a step looks like.
class JSONWriterStreamingTests: XCTestCase {

    /// The guarantee streaming rests on: the concatenated chunks are the same bytes as the buffered
    /// report. Checked across thresholds from "smaller than one field" to "larger than the whole
    /// report", so both the flush-constantly and the never-flush cases go through this assertion.
    func testStreamedChunksConcatenateToTheBufferedReport() {
        let root = Self.tree()
        var buffered = JSONWriter()
        root.write(to: &buffered)
        let expected = Array(buffered.bytes)

        for threshold in [1, 64, 512, 4096, expected.count, expected.count * 2] {
            var streamed = [UInt8]()
            var writer = JSONWriter(flushThreshold: threshold) { chunk in
                streamed.append(contentsOf: chunk)
            }
            root.write(to: &writer)
            writer.flush()
            XCTAssertNil(writer.sinkError, "threshold \(threshold)")
            XCTAssertEqual(streamed, expected, "threshold \(threshold)")
        }
    }

    /// A small threshold must actually produce many chunks - without this, the test above would pass
    /// just as happily on a writer that never flushed until the final `flush()`.
    func testSmallThresholdProducesManyChunks() {
        var chunkCount = 0
        var writer = JSONWriter(flushThreshold: 64) { _ in chunkCount += 1 }
        Self.tree().write(to: &writer)
        writer.flush()
        XCTAssertGreaterThan(chunkCount, 10)
    }

    /// A sink failure is recorded rather than thrown, and suppresses later flushes. `JsonReporter`
    /// depends on `sinkError` surviving until the non-throwing tree walk has finished.
    func testSinkErrorIsRecordedAndStopsFurtherFlushes() {
        enum Failure: Error { case sink }
        var calls = 0
        var writer = JSONWriter(flushThreshold: 64) { _ in
            calls += 1
            throw Failure.sink
        }
        Self.tree().write(to: &writer)
        writer.flush()
        XCTAssertEqual(calls, 1, "the sink must not be called again after it fails")
        XCTAssertNotNil(writer.sinkError)
    }

    /// Without a sink the writer must behave exactly as before: accumulate everything, flush nothing.
    func testWriterWithoutSinkNeverFlushes() {
        var writer = JSONWriter()
        Self.tree().write(to: &writer)
        writer.flush()
        XCTAssertNil(writer.sinkError)
        XCTAssertFalse(writer.bytes.isEmpty, "the buffer must still hold the whole report")
    }

    /// Deep enough that objects close at several nesting levels, which is where `flushIfNeeded` runs.
    private static func tree() -> BuildStep {
        let leaves = (0..<10).map { JSONWriterTests.step(identifier: "leaf-\($0)") }
        let middles = (0..<4).map {
            JSONWriterTests.step(identifier: "mid-\($0)", subSteps: leaves)
        }
        return JSONWriterTests.step(identifier: "root", subSteps: middles)
    }
}
