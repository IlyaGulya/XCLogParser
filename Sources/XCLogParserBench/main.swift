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

// MARK: - Timing primitives

/// Wall-clock duration of `body`, in seconds, using the monotonic clock.
func measure<T>(_ body: () throws -> T) rethrows -> (value: T, seconds: Double) {
    let start = DispatchTime.now().uptimeNanoseconds
    let value = try body()
    let end = DispatchTime.now().uptimeNanoseconds
    return (value, Double(end - start) / 1_000_000_000)
}

/// Wall-clock duration of `body` plus the allocation events it caused.
///
/// The counters cost +1.2% on a real log, which is below the noise this harness reports against, so the
/// two are gathered together rather than in separate runs - the reason the DTrace recipe cannot: its
/// `ustack()` slows the process ~20x, making any timing from such a run meaningless.
///
/// `counts` is `nil` when the runtime hooks are unavailable, never zero, so an unmeasurable stage cannot
/// be read as a stage that allocated nothing.
struct Measured<T> {
    let value: T
    let seconds: Double
    let counts: AllocationCounts?
}

func measureWithCounts<T>(_ body: () throws -> T) rethrows -> Measured<T> {
    var seconds: Double = 0
    let (value, counts) = try AllocationCounters.measuring { () throws -> T in
        let start = DispatchTime.now().uptimeNanoseconds
        let inner = try body()
        let end = DispatchTime.now().uptimeNanoseconds
        seconds = Double(end - start) / 1_000_000_000
        return inner
    }
    return Measured(value: value, seconds: seconds, counts: counts)
}

// `Stats` and `Percentile` live in Stats.swift.

// MARK: - Stages

/// The pipeline stages we time independently. Each stage consumes the previous stage's output,
/// so a single iteration walks the whole pipeline and records a sample for every stage.
enum Stage: String, CaseIterable {
    case read = "read"
    case gunzip = "gunzip"
    case tokenize = "tokenize"
    case activityParse = "activity-parse"
    case buildStepParse = "buildstep-parse"
    case encode = "encode"
    case encodeStreaming = "encode-streaming"

    var label: String {
        switch self {
        case .read: return "Read file"
        case .gunzip: return "Gunzip"
        case .tokenize: return "Tokenize (Lexer)"
        case .activityParse: return "Parse IDEActivityLog"
        case .buildStepParse: return "Parse BuildStep tree"
        case .encode: return "Encode JSON (buffered)"
        case .encodeStreaming: return "Encode JSON (streaming)"
        }
    }
}

struct IterationResult {
    var timings: [Stage: Double] = [:]
    /// Phys footprint immediately after each stage, while that stage's output is still alive.
    var footprints: [Stage: UInt64] = [:]
    /// The process-wide peak RSS as of the end of each stage.
    ///
    /// Cumulative by nature - the kernel's high-water mark cannot be reset - so the useful figure is
    /// the *rise* from one stage to the next, which is what the report prints. Unlike `footprints`,
    /// this catches memory a stage allocated and released before it returned.
    var residentPeaks: [Stage: UInt64] = [:]
    /// Allocation and retain/release events per stage. A stage is absent here when the runtime hooks
    /// are unavailable - distinct from a stage present with zeros, which means it genuinely allocated
    /// nothing.
    var counts: [Stage: AllocationCounts] = [:]
    var tokenCount: Int = 0
    var utf8ByteCount: Int = 0
    var unzippedBytes: Int = 0
    /// Size of the encoded JSON report, which on a large log is several times the log itself.
    var encodedBytes: Int = 0
    /// Bytes seen by the streaming path. Must equal `encodedBytes` - the two paths emit the same
    /// report, so a mismatch here is a bug in one of them.
    var streamedBytes: Int = 0
    /// How many chunks the streaming path emitted, which is what the flush threshold controls.
    var chunkCount: Int = 0
    /// Footprint before any log data is touched, subtracted out so the figures are about the log rather
    /// than about the binary and the Swift runtime.
    var baselineFootprint: UInt64 = 0
    var peakFootprint: UInt64 = 0
    var peakResident: UInt64 = 0
    /// Which conditional parser paths this log exercised. Reported so that a stage which never ran cannot
    /// be read as a stage that ran and changed nothing.
    var coverage = PathCoverage()
}

/// Which encode path a process measures.
///
/// Exists because the two paths cannot share a heap history: `phys_footprint` never returns pages to
/// the kernel, so whichever encode stage runs second allocates from pages the first one already mapped
/// and its footprint delta reads near-zero no matter what it does. Selecting one per process is the
/// only way either delta is falsifiable. `.both` keeps the default report complete - it still runs and
/// times both - but the memory table refuses to print a footprint for the stage that ran second.
enum EncodePath: String {
    case both
    case buffered
    case streaming

    /// The stage whose footprint this mode can be trusted for: the one that runs first, and under
    /// `buffered`/`streaming` the only one that runs at all.
    var trustedFootprintStage: Stage {
        switch self {
        case .both, .buffered: return .encode
        case .streaming: return .encodeStreaming
        }
    }

    func measures(_ stage: Stage) -> Bool {
        switch (self, stage) {
        case (.both, _): return true
        case (.buffered, .encode), (.streaming, .encodeStreaming): return true
        default: return false
        }
    }
}

struct LogBenchmark {
    let url: URL
    let redacted: Bool
    let withoutBuildSpecificInformation: Bool
    let encodePath: EncodePath

    /// Runs one full pipeline pass, timing each stage and recording the footprint at each stage boundary.
    ///
    /// Each footprint is read *after* the stage returns and while its output is still in scope, so it
    /// includes that output. The peak is accumulated from those readings rather than taken from the
    /// kernel's process-wide high-water mark, which cannot be reset between iterations.
    func runIteration(baselineFootprint: UInt64) throws -> IterationResult {
        var result = IterationResult()
        result.baselineFootprint = baselineFootprint

        func recordFootprint(_ stage: Stage, into result: inout IterationResult) {
            let sample = memorySample()
            result.footprints[stage] = sample.footprint
            result.peakFootprint = max(result.peakFootprint, sample.footprint)
            // Peak RSS as well as footprint, because the two see different things. A stage that builds
            // a big buffer and frees it before returning is invisible to `footprint` - the reading is
            // taken after the stage, by which time the buffer is gone - but the kernel's high-water
            // mark remembers it. That transient double is exactly what a "copy the report once more"
            // change costs, and measuring it needed a separate CLI run until now.
            result.residentPeaks[stage] = sample.residentPeak
        }

        /// Times and counts `body` as `stage`, then reads the footprint while its output is still alive.
        ///
        /// Every stage goes through here so that adding one cannot record a timing and quietly forget the
        /// counts or the footprint - the three are what the three tables are built from.
        func runStage<T>(_ stage: Stage, _ body: () throws -> T) rethrows -> T {
            let measured = try measureWithCounts(body)
            result.timings[stage] = measured.seconds
            result.counts[stage] = measured.counts
            let value = measured.value
            recordFootprint(stage, into: &result)
            withExtendedLifetime(value) {}
            return value
        }

        let data = try runStage(.read) { try Data(contentsOf: url) }

        // The inflate the CLI runs. `LogLoader.loadBytesFromURL` is read-then-`Gunzip.inflate`, and the
        // read and gunzip stages here time those two halves separately, so they sum to the shipped read
        // path. `Gunzip.inflate` is called directly rather than through `loadBytesFromURL` only because
        // the latter would re-read the file inside the gunzip stage.
        let unzipped = try runStage(.gunzip) { try Gunzip.inflate(data) }
        result.unzippedBytes = unzipped.count

        result.utf8ByteCount = unzipped.count

        // `tokenize(data:)`, not `tokenize(contents:)`: the byte entry point is the one the library uses
        // on a real log, so it is the one whose cost is worth knowing. Both go through the same loop
        // today and the `Data` overload decodes a `String` to get there - the copies under it are what
        // this branch removes, and holding the call site still is what makes those removals comparable.
        let lexer = Lexer(filePath: url.path)
        let tokens = try runStage(.tokenize) {
            try lexer.tokenize(data: unzipped,
                               redacted: redacted,
                               withoutBuildSpecificInformation: withoutBuildSpecificInformation)
        }
        result.tokenCount = tokens.count

        let activityParser = ActivityParser()
        let activityLog = try runStage(.activityParse) {
            try activityParser.parseIDEActiviyLogFromTokens(tokens)
        }

        let stepParser = ParserBuildSteps(machineName: "benchmark",
                                          omitWarningsDetails: false,
                                          omitNotesDetails: false,
                                          truncLargeIssues: false)
        // `runStage` keeps the tree alive across its own footprint reading, which is the point of this
        // stage: how much memory the output costs.
        let buildStep = try runStage(.buildStepParse) {
            try stepParser.parse(activityLog: activityLog)
        }

        try encodeStages(buildStep, into: &result, recordFootprint: recordFootprint)

        // Deliberately outside every `runStage`: this re-walks the section tree, and timing it would
        // charge the parser for work the shipped CLI never does.
        result.coverage = PathCoverage.detect(activityLog: activityLog)

        result.peakResident = memorySample().residentPeak
        return result
    }

    /// Times whichever ways of getting the report out this process was asked to measure.
    ///
    /// Encoding is the stage the benchmark used to be blind to entirely: without it the harness saw
    /// 644 ms of a 4.70 s command and 898 MB of a 3152 MB peak. It then became blind in a subtler way
    /// - it timed only the buffered path, which after streaming landed is no longer the path the CLI
    /// takes. So both are measurable here.
    ///
    /// `MemoryOutput` is not a `StreamingReporterOutput`, so it takes the buffer-everything fallback -
    /// what a consumer with its own `ReporterOutput` still pays. `CountingStreamOutput` is one, so it
    /// takes the path the CLI takes.
    ///
    /// # Which footprint reading is trustworthy
    ///
    /// Only the one belonging to the encode stage that ran *first* in this process. Both paths allocate
    /// on the order of the report size, and `phys_footprint` never returns released pages to the
    /// kernel, so the second path allocates out of pages the first already mapped and its delta reads
    /// near-zero **even if it secretly buffered the whole report** - unfalsifiable, and therefore
    /// useless as the regression detector it exists to be.
    ///
    /// Hence `--encode-path`: `buffered` or `streaming` runs exactly one path per process, so that
    /// path's delta is measured against a heap no other encode has touched. The default `both` still
    /// runs and times both - a silently missing stage would be its own regression - but the memory
    /// table prints "not falsifiable here" for the second one instead of a plausible number, per
    /// `EncodePath.trustedFootprintStage`.
    ///
    /// The anchor for streaming's memory remains `/usr/bin/time -l` on the real CLI, which is what
    /// -160.9/-188.9 MB peak RSS was measured with.
    private func encodeStages(_ buildStep: BuildStep,
                              into result: inout IterationResult,
                              recordFootprint: (Stage, inout IterationResult) -> Void) throws {
        if encodePath.measures(.encode) {
            let output = MemoryOutput()
            let encoded = try measureWithCounts {
                try JsonReporter().report(build: buildStep, output: output, rootOutput: "")
            }
            result.timings[.encode] = encoded.seconds
            result.counts[.encode] = encoded.counts
            result.encodedBytes = output.byteCount
            // Read while both the tree and the whole report are alive: the peak of the buffered path.
            recordFootprint(.encode, &result)
            withExtendedLifetime(buildStep) {}
            withExtendedLifetime(output) {}
        }

        if encodePath.measures(.encodeStreaming) {
            // Measured with the report released as it goes - that being the whole point, retaining the
            // chunks here would measure the buffered path with extra steps.
            let streamOutput = CountingStreamOutput()
            let streamed = try measureWithCounts {
                try JsonReporter().report(build: buildStep, output: streamOutput, rootOutput: "")
            }
            // Only recorded when the report was actually streamed. `JsonReporter` streams as of this
            // commit, so this is the live path now; it is still guarded because the same harness gets
            // built against older libraries when sweeping a range, and filing the buffered fallback
            // under "Encode JSON (streaming)" would put a number against a path that did not run.
            if !streamOutput.fellBackToBuffering {
                result.timings[.encodeStreaming] = streamed.seconds
                result.counts[.encodeStreaming] = streamed.counts
                result.streamedBytes = streamOutput.byteCount
                result.chunkCount = streamOutput.chunkCount
                recordFootprint(.encodeStreaming, &result)
            }
            withExtendedLifetime(buildStep) {}
        }
    }
}

let options = parseOptions()

do {
    let logs = try discoverLogs(options)
    // Loaded before any measuring, so a bad path fails in a second rather than after a ten-minute run.
    let baselines = try options.baseline.map { try BaselineLog.load(from: $0) }
    print("xclogparser-bench — \(logs.count) log(s), "
        + "\(options.warmup) warmup + \(options.iterations) measured iteration(s)")

    var reports: [LogReport] = []
    for (logIndex, url) in logs.enumerated() {
        let benchmark = LogBenchmark(url: url,
                                     redacted: options.redacted,
                                     withoutBuildSpecificInformation: options.withoutBuildSpecificInformation,
                                     encodePath: options.encodePath)
        let compressed = (try? Data(contentsOf: url).count) ?? 0

        // Taken before any log data is touched, so the footprints are about the log. Only the first
        // measured iteration can be read against it - see `LogReport.footprint(for:)`.
        let baseline = memorySample().footprint

        FileHandle.standardError.write(Data("  \(url.lastPathComponent): warming up…\n".utf8))
        for _ in 0..<options.warmup {
            _ = try withIterationPool { try benchmark.runIteration(baselineFootprint: baseline) }
        }

        var iterations: [IterationResult] = []
        for index in 0..<options.iterations {
            FileHandle.standardError
                .write(Data("  \(url.lastPathComponent): iteration \(index + 1)/\(options.iterations)…\n".utf8))
            iterations.append(try withIterationPool {
                try benchmark.runIteration(baselineFootprint: baseline)
            })
        }

        let report = LogReport(name: url.lastPathComponent,
                               compressedBytes: compressed,
                               iterations: iterations,
                               // Only the first log of a process can be measured. The per-log baseline is
                               // taken fresh, but the heap it is taken against has already grown to the
                               // previous log's high-water mark and `phys_footprint` never gives that
                               // back, so a later log subtracts a baseline far above its own usage. With
                               // the encode stage allocating gigabytes this stopped being a small error
                               // and started printing negative footprints: the second log of a two-log
                               // run reported -926.5 MB, where measured alone it reports +1931.8 MB.
                               memoryIsMeaningful: options.warmup == 0 && logIndex == 0,
                               encodePath: options.encodePath)
        report.printReport()
        // Matched by log name rather than by position, so reordering the logs cannot compare one log's
        // figures against another's. A baseline that does not cover this log says so instead of comparing.
        if let baselines = baselines {
            if let match = baselines.first(where: { $0.name == report.name }) {
                report.compared(with: match).printComparison()
            } else {
                print("")
                print("── \(report.name): not in the baseline "
                    + "(\(baselines.map { $0.name }.joined(separator: ", "))) — not compared")
            }
        }
        reports.append(report)
    }

    if let jsonPath = options.jsonOutput {
        let payload: [String: Any] = ["logs": reports.map { $0.jsonObject }]
        let data = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: jsonPath))
        print("\nJSON written to \(jsonPath)")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
