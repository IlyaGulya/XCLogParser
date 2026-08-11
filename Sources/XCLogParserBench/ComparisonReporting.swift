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

/// Renders one metric's value in its own units. Counters are integers and must not be shown as `1.4e+06`
/// - the whole point of an exact-threshold metric is that a reader can see which digit moved.
private func formatMetric(_ value: Double, _ metric: Metric) -> String {
    switch metric {
    case .time: return formatSeconds(value)
    case .throughput: return String(format: "%.1f MB/s", value)
    case .allocations, .retains, .releases: return formatCount(UInt64(value.rounded()))
    }
}

extension Deviation {
    /// One line: what moved, from what to what, and by how much.
    var line: String {
        let change = percentChange.map { String(format: "%+.1f%%", $0) } ?? "n/a"
        let location = "\(stage) \(metric.label) \(percentile.label)"
        return "     \(location.padding(toLength: 34, withPad: " ", startingAt: 0))"
            + "\(formatMetric(baseline, metric).padding(toLength: 14, withPad: " ", startingAt: 0))→ "
            + "\(formatMetric(current, metric).padding(toLength: 14, withPad: " ", startingAt: 0))"
            + change
    }
}

extension Comparison {
    /// Prints the diff against the baseline.
    ///
    /// Prints the "within threshold" line even when there is nothing to report, because a comparison that
    /// produces no output is indistinguishable from one that never ran - and a silent pass is exactly
    /// what a regression check must not look like.
    func printComparison() {
        print("")
        print("── \(name): vs baseline")
        print("   thresholds: time ±5% and ±1 ms at p50/p90;  counters exact (any change reported)")

        if regressions.isEmpty && improvements.isEmpty {
            print("   no change past the thresholds")
        }
        if regressions.isEmpty == false {
            print("   REGRESSIONS (\(regressions.count))")
            regressions.forEach { print($0.line) }
        }
        if improvements.isEmpty == false {
            print("   improvements (\(improvements.count))")
            improvements.forEach { print($0.line) }
        }
        // Always printed, so the reader can see how much of the run was actually compared. A comparison
        // covering three of seven stages and a comparison covering all seven print the same verdict
        // otherwise.
        if uncomparable.isEmpty == false {
            print("   not compared (\(uncomparable.count))")
            uncomparable.forEach { print("     \($0)") }
        }
        print("   A timing verdict here is not a claim on a loaded host: ±5% is wider than the real "
            + "changes")
        print("   this pipeline has produced. The counter verdicts are load-independent and exact.")
    }
}

extension LogReport {
    /// The caption under the timing table, naming the percentiles this sample size can actually resolve.
    ///
    /// Printed because nearest-rank on a small sample makes the high percentiles collapse onto the
    /// slowest iteration: with 3 samples p75, p90, p99 and p100 are all the same number. Three identical
    /// columns look like a converged distribution and are in fact one measurement, and a reader deciding
    /// whether to trust p99 needs that said out loud rather than inferred from the arithmetic.
    func printPercentileNote() {
        let distinguishable = totalStats.distinguishablePercentiles
        let count = iterations.count
        guard distinguishable.count < Percentile.allCases.count else { return }
        let names = distinguishable.map { $0.label }.joined(separator: ", ")
        print("   \(count) sample(s) resolve \(names); the rest repeat the nearest of those.")
    }
}
