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

func formatSeconds(_ seconds: Double) -> String {
    seconds >= 1 ? String(format: "%7.3f s ", seconds) : String(format: "%7.1f ms", seconds * 1000)
}

func formatBytes(_ bytes: Int) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_048_576)
}

struct LogReport {
    let name: String
    let compressedBytes: Int
    let iterations: [IterationResult]

    /// Whether the footprint figures describe this run's own allocation.
    ///
    /// False once anything has already grown the heap, because `phys_footprint` never gives those pages
    /// back - so a warmup, or an earlier log in the same process, turns every footprint reading into a
    /// cumulative total instead of a cost.
    ///
    /// Reported rather than silently corrected: the timing numbers genuinely want a warmup, so the two
    /// metrics disagree about what a good run looks like and the caller has to choose.
    let memoryIsMeaningful: Bool

    /// Which encode path(s) this process measured. Decides which encode stage's footprint is a real
    /// measurement - see `footprintIsFalsifiable(for:)`.
    let encodePath: EncodePath

    /// Whether `stage`'s footprint delta could have come out high if the code were wrong.
    ///
    /// False for the encode stage that ran second in this process. Both encode paths allocate on the
    /// order of the report size and `phys_footprint` never returns pages to the kernel, so the second
    /// one is satisfied from pages the first already mapped: its delta reads near-zero even if it
    /// buffered the entire report. A figure that cannot come out wrong cannot detect a regression,
    /// which is the only reason these stages record memory at all.
    ///
    /// Reported rather than silently omitted, on the same grounds as `peakResident`: a blank cell reads
    /// as "not measured", where the honest statement is "this run cannot measure it, and here is the
    /// flag that can".
    func footprintIsFalsifiable(for stage: Stage) -> Bool {
        guard stage == .encode || stage == .encodeStreaming else { return true }
        return encodePath.trustedFootprintStage == stage
    }

    var totalStats: Stats {
        Stats(samples: iterations.map { $0.timings.values.reduce(0, +) })
    }

    /// Peak RSS, or `nil` when this run cannot report it honestly.
    ///
    /// `resident_size_peak` is a high-water mark since *process start* and cannot be reset, so it has
    /// exactly the same defect as `phys_footprint` above and needs the same rule: it only describes one
    /// iteration's cost if only one iteration ran. With a warmup or `-n > 1` it reports the highest
    /// point any earlier pass reached, and a later regression hides underneath that ceiling.
    ///
    /// This was not theoretical. The same log measured three ways gave 1152.3 MB (`-n 3 --warmup 1`),
    /// 990.6 MB (`-n 1 --warmup 0`) and 832.6 MB from the real CLI - the default flags read 38% high.
    /// That is why a reporter-side memory regression measured here as "unchanged 900.7 MB" while
    /// `/usr/bin/time -l` on the CLI showed +234 MB.
    ///
    /// Returning `nil` rather than a number, because the previous behaviour - printing the last
    /// iteration's reading unconditionally - was a number that looked authoritative and was not.
    var peakResident: UInt64? {
        guard memoryIsMeaningful, iterations.count == 1 else { return nil }
        return iterations.first?.peakResident
    }

    func stats(for stage: Stage) -> Stats {
        Stats(samples: iterations.compactMap { $0.timings[stage] })
    }

    /// The stage's timings, or `nil` when it never ran in this process.
    ///
    /// A stage that was not selected has no samples, and `Stats` of no samples is all zeros - which
    /// printed as `0.0 ms`, indistinguishable from a stage that ran and cost nothing. That is not a
    /// cosmetic difference: sweeping this branch with `--encode-path buffered` reported an exact
    /// `0.0 ms` and zero allocations for the commit that introduced streaming, and it was read as
    /// "this change does nothing" when the truth was "this path was never executed". The same
    /// mistake, in three different disguises, is the most expensive one this harness has made.
    func measuredStats(for stage: Stage) -> Stats? {
        let samples = iterations.compactMap { $0.timings[stage] }
        return samples.isEmpty ? nil : Stats(samples: samples)
    }

    /// Footprint after `stage`, over the baseline, from the first measured iteration only.
    ///
    /// # Why only the first iteration, and never an average
    ///
    /// `phys_footprint` does not come back down when an iteration's memory is released: malloc returns
    /// the pages to its zone, not to the kernel. Each successive iteration therefore reads a cumulative
    /// high-water mark rather than its own cost, and the figures climb monotonically - across five
    /// iterations of unchanged code the `read` stage reported 15.9, -25.4, 583.1, 759.2 and 1029.4 MB.
    ///
    /// Averaging those is meaningless, and the median of three is worse than meaningless: it always
    /// returns iteration 2, so the metric looks stable while silently depending on how many iterations
    /// were requested. This was nearly reported as a working metric on that basis. Only the first pass
    /// over a fresh heap measures one iteration's cost, so repeat the whole *process* for another sample.
    /// How much the process-wide peak RSS rose during `stage`, formatted for the memory table.
    ///
    /// The kernel's high-water mark only ever goes up, so the reading after a stage minus the reading
    /// before it is what that stage added to the peak - zero when it stayed under an earlier stage's
    /// high mark, which is a true statement about the peak rather than about the stage's allocations.
    ///
    /// This is the metric `footprint` cannot provide: a buffer allocated and freed *within* a stage is
    /// already gone when the footprint is sampled, but the peak remembers it. Reported per stage so
    /// that a transient double no longer needs a separate `/usr/bin/time -l` run to find.
    ///
    /// - parameter previous: The previous stage's peak, updated in place.
    func residentPeakRise(for stage: Stage, previous: inout Double) -> String {
        guard memoryIsMeaningful,
              let first = iterations.first,
              let peak = first.residentPeaks[stage] else {
            return "-"
        }
        let value = Double(peak)
        defer { previous = value }
        guard previous > 0 else { return "(baseline)" }
        return String(format: "%+.1f MB", (value - previous) / 1_048_576)
    }

    func footprint(for stage: Stage) -> Double? {
        guard let first = iterations.first, let value = first.footprints[stage] else {
            return nil
        }
        return Double(value) - Double(first.baselineFootprint)
    }

    var peakFootprint: Double? {
        guard let first = iterations.first else {
            return nil
        }
        return Double(first.peakFootprint) - Double(first.baselineFootprint)
    }

    /// Allocation events for `stage`, or `nil` when this run cannot report them.
    ///
    /// Unlike the footprint figures, these need no first-iteration rule: the counters are reset per
    /// stage per iteration, so every pass measures its own work rather than a cumulative total. The
    /// median across iterations is therefore meaningful, and is what this returns - the counts are very
    /// nearly deterministic in practice, so a spread here is itself informative.
    ///
    /// `nil` when the Swift runtime does not expose the hookable pointers, never zero: the counters are
    /// not API, and a future toolchain dropping them must read as "cannot measure" rather than as a
    /// pipeline that allocated nothing.
    func counts(for stage: Stage) -> AllocationCounts? {
        let samples = iterations.compactMap { $0.counts[stage] }
        guard samples.isEmpty == false else { return nil }

        func median(_ values: [UInt64]) -> UInt64 {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        return AllocationCounts(allocations: median(samples.map { $0.allocations }),
                                retains: median(samples.map { $0.retains }),
                                releases: median(samples.map { $0.releases }))
    }

    /// Whether any stage reported counts, i.e. whether the runtime hooks worked at all.
    var countsAreAvailable: Bool {
        iterations.contains { $0.counts.isEmpty == false }
    }

    /// The identity-and-sizes block above the tables: what was read, what came out, and which of
    /// those figures this run is entitled to report.
    private func printHeader() {
        let last = iterations.last!
        print("")
        print("── \(name)")
        print("   compressed: \(formatBytes(compressedBytes))   "
            + "uncompressed: \(formatBytes(last.unzippedBytes))   "
            + "utf8 bytes: \(last.utf8ByteCount)   tokens: \(last.tokenCount)")
        // Peak RSS is deliberately absent unless it means something - see `peakResident`. Saying so
        // out loud, because a silently missing figure reads as "not measured" rather than "this run
        // cannot measure it", and the wrong figure is what hid a 234 MB regression.
        let peak = peakResident.map(Int.init).map(formatBytes)
            ?? "n/a (needs -n 1 --warmup 0)"
        // "n/a" rather than 0.0 MB when the buffered path did not run: a zero here would read as an
        // empty report rather than as a path that was never invoked.
        let encoded = encodePath.measures(.encode) ? formatBytes(last.encodedBytes) : "n/a (path not run)"
        print("   iterations: \(iterations.count)   "
            + "encoded JSON: \(encoded)   "
            + "peak RSS: \(peak)")
        // The two encode paths must produce the same number of bytes. Printed rather than asserted so
        // a mismatch is visible in every run's output instead of only when someone runs the tests.
        // Only comparable when both paths ran: under --encode-path one of the two counts is zero
        // because that path was never invoked, which is not a disagreement about the report.
        if encodePath == .both {
            let agree = last.streamedBytes == last.encodedBytes
            print("   streamed: \(formatBytes(last.streamedBytes)) in \(last.chunkCount) chunks   "
                + (agree ? "(matches buffered)" : "*** DISAGREES WITH BUFFERED PATH ***"))
        } else if encodePath == .streaming, last.timings[.encodeStreaming] != nil {
            // Suppressed when the reporter has no streaming path: it then buffered the report, the
            // stage was not recorded, and "streamed: 0.0 MB in 0 chunks" would describe a run that
            // never happened rather than a report that was empty.
            print("   streamed: \(formatBytes(last.streamedBytes)) in \(last.chunkCount) chunks   "
                + "(buffered path not run, so no cross-check)")
        }
    }

    /// The percentiles the timing table shows.
    ///
    /// `p0` and `p100` are included under those names rather than as separate min/max columns, so the
    /// table and the threshold model are keyed the same way. `p25`/`p75` are omitted from the *table* only
    /// to keep it inside a terminal width - they are still in the JSON, and still comparable.
    private static let reportedPercentiles: [Percentile] = [.p0, .p50, .p90, .p99, .p100]

    private func timingRow(_ label: String, _ stats: Stats, share: String) -> String {
        var row = "   \(label.padding(toLength: 24, withPad: " ", startingAt: 0))"
        for percentile in Self.reportedPercentiles {
            row += formatSeconds(stats.percentile(percentile)).padding(toLength: 12,
                                                                      withPad: " ",
                                                                      startingAt: 0)
        }
        row += formatSeconds(stats.stddev).padding(toLength: 12, withPad: " ", startingAt: 0)
        return row + share
    }

    /// A row for a stage this process never ran, so that it cannot be read as a stage costing nothing.
    private func unmeasuredRow(_ label: String) -> String {
        var row = "   \(label.padding(toLength: 24, withPad: " ", startingAt: 0))"
        for _ in 0..<(Self.reportedPercentiles.count + 1) {
            row += "-".padding(toLength: 12, withPad: " ", startingAt: 0)
        }
        return row + "not run"
    }

    func printReport() {
        let last = iterations.last!
        printHeader()
        print("")
        var header = "   \("Stage".padding(toLength: 24, withPad: " ", startingAt: 0))"
        for percentile in Self.reportedPercentiles {
            header += percentile.label.padding(toLength: 12, withPad: " ", startingAt: 0)
        }
        print(header + "\("stddev".padding(toLength: 12, withPad: " ", startingAt: 0))share")
        let width = 24 + 12 * (Self.reportedPercentiles.count + 1) + 6
        print("   " + String(repeating: "─", count: width))

        let total = totalStats.median
        for stage in Stage.allCases {
            guard let stats = measuredStats(for: stage) else {
                print(unmeasuredRow(stage.label))
                continue
            }
            let share = total > 0 ? stats.median / total * 100 : 0
            print(timingRow(stage.label, stats, share: String(format: "%5.1f%%", share)))
        }
        print("   " + String(repeating: "─", count: width))
        let overall = totalStats
        print(timingRow("TOTAL", overall, share: "100.0%"))
        let throughput = Double(last.unzippedBytes) / 1_048_576 / overall.median
        print(String(format: "   throughput: %.1f MB/s of uncompressed log", throughput))
        printPercentileNote()
        printMemoryReport()
        printAllocationReport()
        printCoverageReport()
    }

    /// Which conditional parser paths this log exercised, taken from the last iteration.
    ///
    /// Any iteration would do - coverage is a property of the log, not of the pass - and the last one is
    /// used for consistency with the other single-value figures in the header.
    var coverage: PathCoverage {
        iterations.last?.coverage ?? PathCoverage()
    }

    /// Names the parser paths this log never entered.
    ///
    /// Printed on every run, including when everything ran, because the useful statement is about
    /// coverage rather than about a problem: a reader diffing two reports needs to know that a change to
    /// one of these functions would show up as "identical" here. That silence is the failure this
    /// replaces - a false negative dressed as a pass.
    func printCoverageReport() {
        let missing = coverage.unexecuted
        print("")
        guard missing.isEmpty == false else {
            print("   coverage: every conditional parser path ran on this log.")
            return
        }
        print("   NOT EXERCISED BY THIS LOG — a change to these is unverifiable here, and a")
        print("   whole-log diff over one will report \"identical\":")
        for path in missing {
            print("     \(path.function.padding(toLength: 22, withPad: " ", startingAt: 0))"
                + "needs \(path.requirement)")
        }
    }

    var jsonObject: [String: Any] {
        let last = iterations.last!
        var stages: [[String: Any]] = []
        for stage in Stage.allCases {
            let stats = self.stats(for: stage)
            var entry: [String: Any] = [
                "stage": stage.rawValue,
                "medianSeconds": stats.median,
                "meanSeconds": stats.mean,
                "minSeconds": stats.min,
                "maxSeconds": stats.max,
                "stddevSeconds": stats.stddev,
                "samples": stats.samples
            ]
            // Written so `--baseline` can compare percentile against percentile without re-deriving them
            // from `samples`, which would silently disagree the moment the percentile rule changed. Nested
            // under one key rather than added as `p50Seconds`, `p90Seconds`… so that adding a percentile
            // does not add top-level fields a consumer has to learn about.
            var percentiles: [String: Double] = [:]
            for percentile in Percentile.allCases {
                percentiles[percentile.rawValue] = stats.percentile(percentile)
            }
            entry["percentileSeconds"] = percentiles
            // Omitted rather than emitted as a misleading number when a warmup has run, or when the
            // stage is the encode path that ran second and so cannot report a falsifiable delta.
            if memoryIsMeaningful, let footprint = footprint(for: stage) {
                if footprintIsFalsifiable(for: stage) {
                    entry["footprintBytes"] = footprint
                } else {
                    entry["footprintNotFalsifiable"] = true
                }
            }
            // Absent, not zero, when the runtime hooks are unavailable - the same rule the footprint
            // fields follow, so a consumer diffing two runs cannot read "unmeasurable" as "none".
            if let stageCounts = counts(for: stage) {
                entry["allocations"] = stageCounts.allocations
                entry["retains"] = stageCounts.retains
                entry["releases"] = stageCounts.releases
            }
            stages.append(entry)
        }
        var payload: [String: Any] = [
            "name": name,
            "compressedBytes": compressedBytes,
            "uncompressedBytes": last.unzippedBytes,
            "utf8Bytes": last.utf8ByteCount,
            "encodedBytes": last.encodedBytes,
            "streamedBytes": last.streamedBytes,
            "chunkCount": last.chunkCount,
            "tokens": last.tokenCount,
            "iterations": iterations.count,
            "memoryIsMeaningful": memoryIsMeaningful,
            // Lets a consumer distinguish "this build could not hook the runtime" from "every stage
            // happened to allocate nothing", which the per-stage fields alone cannot express.
            "allocationCountsAvailable": countsAreAvailable,
            "encodePath": encodePath.rawValue,
            "totalMedianSeconds": totalStats.median,
            "totalMeanSeconds": totalStats.mean,
            "stages": stages,
            // Emitted as the paths that did NOT run, rather than as a coverage percentage or a list of
            // those that did: a consumer comparing two reports needs the absent ones named, and a
            // percentage would let "84% covered" stand in for "the function you changed never ran".
            "unexecutedPaths": coverage.unexecuted.map {
                ["function": $0.function, "requires": $0.requirement]
            }
        ]
        if memoryIsMeaningful, let peak = peakFootprint {
            payload["peakFootprintBytes"] = peak
        }
        // Same rule as the printed report: omitted rather than emitted as a since-process-start
        // high-water mark that a consumer would read as this run's cost.
        if let peak = peakResident {
            payload["peakResidentBytes"] = peak
        }
        return payload
    }
}
