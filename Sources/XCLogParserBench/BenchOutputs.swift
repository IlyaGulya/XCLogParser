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
import XCLogParser

// The two `ReporterOutput`s the encode stages measure through. Both paths are timed because the
// library supports both: `MemoryOutput` takes the buffer-everything fallback that a consumer with
// its own `ReporterOutput` still pays, `CountingStreamOutput` takes the path the CLI takes.

/// A `ReporterOutput` that keeps the report in memory instead of writing it.
///
/// The stage exists to measure encoding, not the filesystem: the JSON for a large log is 1-2 GB, so
/// writing it once per iteration would make the benchmark I/O-bound and measure the disk instead.
/// Retaining it is also the point of the memory reading - the report's size is the figure being
/// reported, and `/dev/null` would hide it.
final class MemoryOutput: ReporterOutput {
    var byteCount = 0
    private var report: Data?

    func write(report: Any) throws {
        guard let data = report as? Data else {
            // Never reached with the JSON reporter, which always produces `Data`. Left as a trap rather
            // than a silent zero, since a zero byte count would read as "encoding is free".
            throw BenchError.unsupportedReport(String(describing: type(of: report)))
        }
        self.byteCount = data.count
        self.report = data
    }
}

/// A `StreamingReporterOutput` that counts the bytes and drops them.
///
/// The counterpart to `MemoryOutput`: this one takes the path the CLI takes. It deliberately does
/// *not* retain the chunks, because not holding the whole report is the entire point of streaming -
/// keeping them would make this stage measure the buffered path with extra steps.
final class CountingStreamOutput: StreamingReporterOutput {
    var byteCount = 0
    var chunkCount = 0

    /// Set when the reporter buffered the whole report instead of streaming it.
    ///
    /// No reporter streams yet - `JsonReporter` gains that later in this branch - so this is the path
    /// taken today, and it must not be an error: a sweep measuring every commit would then die on
    /// every point before streaming lands. It must not be recorded as a streaming measurement either,
    /// since what ran was the buffered path. The caller checks this and leaves the stage unmeasured.
    private(set) var fellBackToBuffering = false

    func write(report: Any) throws {
        fellBackToBuffering = true
        byteCount = (report as? Data)?.count ?? 0
        chunkCount = 0
    }

    func beginStreaming() throws {
        byteCount = 0
        chunkCount = 0
    }

    func write(chunk: Data) throws {
        byteCount += chunk.count
        chunkCount += 1
    }

    func endStreaming() throws {}
}
