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

/// Handing the report out in pieces instead of accumulating all of it.
///
/// A report is 94-171 MB on the benchmark logs, and it exists in one buffer only because
/// `ReporterOutput.write(report:)` takes it in a single call. Draining the buffer as it fills trades
/// that for one chunk-sized allocation - measured at **-158 MB / -189 MB peak RSS** on the two
/// benchmark logs, on both the file and stdout paths.
///
/// This lives in its own file purely to keep `JSONWriter.swift` under the 400-line lint limit; the
/// stored properties it uses are declared there, next to the rest of the writer's state.
extension JSONWriter {

    /// A writer that hands the report to `sink` in pieces of roughly `flushThreshold` bytes.
    ///
    /// The buffer is reserved at the threshold plus slack rather than at the report size, which is the
    /// entire point: peak memory becomes the chunk size instead of the whole report.
    init(flushThreshold: Int, sink: @escaping (Data) throws -> Void) {
        self.init()
        self.flushThreshold = flushThreshold
        self.sink = sink
        reserve(flushThreshold + flushThreshold / 8)
    }

    /// Hands the buffer to the sink if it has grown past the threshold.
    ///
    /// Called only where the buffer holds a whole number of syntactic units - never inside a string,
    /// number, or key/value pair. The output is a flat byte stream, so any boundary would in fact be
    /// safe; this only keeps the chunks tidy and the check off the per-field path.
    ///
    /// With no sink the threshold is `Int.max`, so this is one comparison against a stored constant
    /// and nothing else - which is what the non-streaming path pays.
    mutating func flushIfNeeded() {
        guard sink != nil, sinkError == nil, bytes.count >= flushThreshold else { return }
        flush()
    }

    /// Hands whatever is buffered to the sink and empties the buffer, keeping its capacity.
    ///
    /// A sink failure is recorded rather than thrown: `BuildStep.write(to:)` recurses through ~30
    /// field writes per step and making all of it `throws` would put a `try` on every one for an error
    /// that can only originate here. The first failure suppresses later flushes, and `JsonReporter`
    /// rethrows `sinkError` once the walk is done - before it reports the file as written.
    mutating func flush() {
        guard let sink = sink, sinkError == nil, bytes.isEmpty == false else { return }
        do {
            // `Data(raw)` copies the chunk. At ~1 MB that is a rounding error against the report, and
            // it is what lets the sink outlive the borrow of `bytes`.
            try bytes.withUnsafeBytes { raw in
                try sink(Data(raw))
            }
            discardBufferKeepingCapacity()
        } catch {
            sinkError = error
        }
    }
}
