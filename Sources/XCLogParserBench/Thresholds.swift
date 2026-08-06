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

/// Which direction of change is an improvement for a metric.
///
/// Carried on the metric rather than decided at each comparison site, so adding a metric where bigger is
/// better cannot silently be reported backwards. Throughput is the case that motivated this: it was
/// previously the one figure a reader had to mentally invert.
enum Polarity {
    case prefersSmaller
    case prefersLarger
}

/// A metric the baseline diff can compare between two runs.
///
/// Timings and counters are deliberately separate cases rather than one numeric metric, because they
/// take different thresholds: see `Thresholds.forMetric`.
enum Metric: String, CaseIterable {
    case time
    case allocations
    case retains
    case releases
    case throughput

    var polarity: Polarity {
        switch self {
        case .throughput: return .prefersLarger
        case .time, .allocations, .retains, .releases: return .prefersSmaller
        }
    }

    var label: String {
        switch self {
        case .time: return "time"
        case .allocations: return "allocs"
        case .retains: return "retains"
        case .releases: return "releases"
        case .throughput: return "throughput"
        }
    }
}

/// How much a metric may move before the diff calls it a change rather than noise.
///
/// A change must exceed **both** the relative and the absolute tolerance to be reported. Requiring both
/// is what makes the two useful together: relative alone flags a 6% swing on a 0.4 ms stage that no one
/// can act on, and absolute alone flags a 20 ms shift on a 4 s stage that is well inside this host's
/// noise. Either tolerance can be set to zero to disable it, which is how the counter defaults work.
struct Thresholds {
    /// Percent change tolerated, per percentile. Absent percentile means "not checked".
    var relative: [Percentile: Double]
    /// Absolute change tolerated, per percentile, in the metric's own units.
    var absolute: [Percentile: Double]

    /// The tolerance for timings on this harness.
    ///
    /// 5% relative, matching ordo-one's `Relative.default`, and 1 ms absolute so that sub-millisecond
    /// stages cannot produce a headline. Checked at p50 and p90 only: p0 and p100 are single samples and
    /// so are the two most load-sensitive figures the harness has, and p99 on a 3-10 sample run is p100
    /// under another name - see `Stats.distinguishablePercentiles`.
    ///
    /// 5% is not a claim about this host. The recorded case is on the other side of it: a real 3.5%
    /// improvement over six commits, 5/5 rounds favouring after, could not be claimed because load was
    /// 9.51/10 cores. This threshold's job is to stop *reporting* such a run as a result, and the
    /// remedy for a real change smaller than 5% is a quieter host and more samples, not a looser number.
    static let time = Thresholds(relative: [.p50: 5.0, .p90: 5.0],
                                 absolute: [.p50: 0.001, .p90: 0.001])

    /// The tolerance for allocation and retain/release counts: exact.
    ///
    /// Zero on both sides, so any change at all is reported. This is the case a percentage cannot
    /// express - "allocations did not grow by even one" is a statement about identity, not about
    /// magnitude, and it is checkable here precisely because the counts are deterministic where the
    /// timings are not: two runs 26% apart in wall time reported byte-identical counts. That makes a
    /// counter diff a signal about the code and never about the host.
    ///
    /// Checked at p50 alone: with a deterministic metric the other percentiles carry no extra
    /// information, and a spread across iterations is surfaced by the report's own tables instead.
    static let counters = Thresholds(relative: [.p50: 0], absolute: [.p50: 0])

    static func forMetric(_ metric: Metric) -> Thresholds {
        switch metric {
        case .time, .throughput: return .time
        case .allocations, .retains, .releases: return .counters
        }
    }

    /// The percentiles this threshold checks, in report order.
    var checkedPercentiles: [Percentile] {
        Percentile.allCases.filter { relative[$0] != nil || absolute[$0] != nil }
    }

    /// Whether a move from `baseline` to `current` at `percentile` exceeds this tolerance.
    ///
    /// Returns false when the percentile is not checked at all, so an unchecked percentile can never
    /// produce a verdict.
    func exceeded(baseline: Double, current: Double, at percentile: Percentile) -> Bool {
        guard relative[percentile] != nil || absolute[percentile] != nil else { return false }
        let absoluteChange = abs(current - baseline)
        // A baseline of zero has no percentage to be a fraction of. Treating the relative test as
        // satisfied there is the only reading that does not divide by zero and does not silently pass:
        // 0 -> anything is then judged by the absolute tolerance alone, which is the honest test.
        let relativeChange = baseline == 0 ? Double.infinity : absoluteChange / abs(baseline) * 100
        let passesRelative = relativeChange > (relative[percentile] ?? 0)
        let passesAbsolute = absoluteChange > (absolute[percentile] ?? 0)
        return passesRelative && passesAbsolute
    }
}

/// One metric of one stage moving between two runs, past the threshold.
struct Deviation {
    let stage: String
    let metric: Metric
    let percentile: Percentile
    let baseline: Double
    let current: Double

    var absoluteChange: Double { current - baseline }
    var percentChange: Double? {
        baseline == 0 ? nil : (current - baseline) / abs(baseline) * 100
    }

    /// Whether this move is in the metric's preferred direction.
    var isImprovement: Bool {
        switch metric.polarity {
        case .prefersSmaller: return current < baseline
        case .prefersLarger: return current > baseline
        }
    }
}
