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

public struct JsonReporter: LogReporter {

    public init() {}

    public func report(build: Any, output: ReporterOutput, rootOutput: String) throws {
        switch build {
        case let steps as BuildStep:
            if let streaming = output as? StreamingReporterOutput {
                try write(steps: steps, to: streaming)
                return
            }
            // Fallback for an output that cannot take chunks - a `ReporterOutput` from before
            // `StreamingReporterOutput` existed, or one written by a library consumer. Builds the
            // whole report in one buffer, exactly as this did before streaming was added.
            //
            // The build-step tree is the large report - 96-166 MB, tens of thousands of steps - and
            // the only one where encoding dominates the runtime, so it is written directly rather
            // than through `JSONEncoder`. See `JSONWriter`. The two cases below are small and keep
            // using `Encodable`.
            // Sizing the buffer up front rather than letting `[UInt8]` find the size by doubling:
            // at report scale the last doubling overshoots by up to ~92 MB, which measured as
            // +18.7 MB peak RSS against `JSONEncoder`. Both benchmark logs come out just under
            // 2.4 KB per step (2438 and 2356), so 2.5 KB covers them without much slack. It is only
            // a hint - a wider report just grows the array as before.
            var writer = JSONWriter(reservingCapacity: steps.stepCount() * 2560)
            steps.write(to: &writer)
            try output.write(report: writer.makeData())
        case let logEntries as [LogManifestEntry]:
            try report(encodable: logEntries, output: output)
        case let activityLog as IDEActivityLog:
            try report(encodable: activityLog, output: output)
        default:
            throw XCLogParserError.errorCreatingReport("Type not supported \(type(of: build))")
        }
    }

    /// Writes the build-step tree straight to the output in chunks, never holding the whole report.
    ///
    /// The report is 94-171 MB on the benchmark logs and nothing reads it twice, so materialising it
    /// only to hand it over in one call cost its full size in peak RSS. Streaming replaces that with
    /// one chunk-sized buffer.
    ///
    /// 1 MB per chunk: large enough that the per-`write` syscall overhead is negligible against the
    /// bytes moved, small enough to be a rounding error next to the ~1 GB peak. The exact figure is
    /// not delicate - anything from a few hundred KB up behaves the same.
    private func write(steps: BuildStep, to output: StreamingReporterOutput) throws {
        let chunkSize = 1024 * 1024
        try output.beginStreaming()
        var writer = JSONWriter(flushThreshold: chunkSize) { chunk in
            try output.write(chunk: chunk)
        }
        steps.write(to: &writer)
        writer.flush()
        // The walk itself cannot throw, so a sink failure is surfaced here. Rethrown before
        // `endStreaming()` so a failed write does not get reported as a file successfully written.
        if let error = writer.sinkError {
            throw error
        }
        try output.endStreaming()
    }

    private func report<T: Encodable>(encodable: T, output: ReporterOutput) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let json = try encoder.encode(encodable)
        try output.write(report: json)
    }

}
