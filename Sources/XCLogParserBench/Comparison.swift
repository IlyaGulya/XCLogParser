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

/// One log's figures loaded back out of a bench JSON file, in the shape the diff compares.
///
/// A decoded view rather than a re-hydrated `LogReport`: a baseline file is written by whatever version
/// of the bench produced it, so it may lack fields this build writes. Every optional here is a field an
/// older baseline can legitimately be missing, and a missing field must produce "cannot compare" rather
/// than a comparison against zero.
struct BaselineLog {
    struct StageFigures {
        let percentileSeconds: [Percentile: Double]
        /// Absent when that baseline was produced by a build without the runtime counters, or by a
        /// toolchain that did not expose the hooks. Distinct from present-and-zero, which means the stage
        /// genuinely allocated nothing.
        let allocations: Double?
        let retains: Double?
        let releases: Double?

        func value(for metric: Metric, at percentile: Percentile) -> Double? {
            switch metric {
            case .time: return percentileSeconds[percentile]
            case .allocations: return allocations
            case .retains: return retains
            case .releases: return releases
            // Derived at the report level, not per stage - see `BaselineLog.throughput`.
            case .throughput: return nil
            }
        }
    }

    let name: String
    let stages: [String: StageFigures]
    let uncompressedBytes: Int
    let totalMedianSeconds: Double

    /// MB/s of uncompressed log, the one metric where larger is better.
    var throughput: Double? {
        guard totalMedianSeconds > 0 else { return nil }
        return Double(uncompressedBytes) / 1_048_576 / totalMedianSeconds
    }

    /// Reads every log out of a bench JSON file.
    ///
    /// Throws rather than returning an empty list on a file that parses but carries no logs: an empty
    /// baseline compares as "no deviations", which reads exactly like "nothing regressed".
    static func load(from path: String) throws -> [BaselineLog] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let root = try JSONSerialization.jsonObject(with: data)
        guard let object = root as? [String: Any],
              let logs = object["logs"] as? [[String: Any]] else {
            throw BenchError.unreadableBaseline(path, "expected a top-level object with a \"logs\" array")
        }
        let parsed = logs.compactMap(parse)
        guard parsed.isEmpty == false else {
            throw BenchError.unreadableBaseline(path, "no log entries with a recognisable \"stages\" array")
        }
        return parsed
    }

    private static func parse(_ log: [String: Any]) -> BaselineLog? {
        guard let name = log["name"] as? String,
              let stages = log["stages"] as? [[String: Any]] else {
            return nil
        }
        var figures: [String: StageFigures] = [:]
        for stage in stages {
            guard let key = stage["stage"] as? String else { continue }
            var percentiles: [Percentile: Double] = [:]
            if let raw = stage["percentileSeconds"] as? [String: Any] {
                for (name, value) in raw {
                    guard let percentile = Percentile(rawValue: name),
                          let seconds = (value as? NSNumber)?.doubleValue else { continue }
                    percentiles[percentile] = seconds
                }
            } else if let median = (stage["medianSeconds"] as? NSNumber)?.doubleValue {
                // A baseline written before percentiles existed. Its median is a genuine p50, so it is
                // carried over as one; the other percentiles stay absent and so are reported as
                // uncomparable rather than compared against a stand-in.
                percentiles[.p50] = median
            }
            figures[key] = StageFigures(percentileSeconds: percentiles,
                                        allocations: (stage["allocations"] as? NSNumber)?.doubleValue,
                                        retains: (stage["retains"] as? NSNumber)?.doubleValue,
                                        releases: (stage["releases"] as? NSNumber)?.doubleValue)
        }
        return BaselineLog(name: name,
                           stages: figures,
                           uncompressedBytes: (log["uncompressedBytes"] as? NSNumber)?.intValue ?? 0,
                           totalMedianSeconds: (log["totalMedianSeconds"] as? NSNumber)?.doubleValue ?? 0)
    }
}

/// The outcome of diffing one log against its baseline.
struct Comparison {
    let name: String
    /// Kept as two lists rather than one signed total, so that a large win in one stage cannot net out a
    /// regression in another. The half-day hand comparison this replaces made exactly that mistake
    /// available: a total that improved while a stage got worse.
    let regressions: [Deviation]
    let improvements: [Deviation]
    /// Metric/stage pairs the baseline could not be compared on, and why. Reported rather than dropped:
    /// a comparison silently covering fewer stages than the reader thinks is the failure mode that had
    /// the wrong baseline commit go unnoticed for half a day.
    let uncomparable: [String]

    var hasFindings: Bool { regressions.isEmpty == false || improvements.isEmpty == false }
}

extension LogReport {
    /// Diffs this run against `baseline`, one metric-percentile at a time.
    func compared(with baseline: BaselineLog) -> Comparison {
        var regressions: [Deviation] = []
        var improvements: [Deviation] = []
        var uncomparable: [String] = []

        for stage in Stage.allCases {
            guard let baselineStage = baseline.stages[stage.rawValue] else {
                uncomparable.append("\(stage.rawValue): absent from the baseline")
                continue
            }
            // A stage this run did not execute has no figures to compare. Skipped with a note rather
            // than compared against its absent samples, which would read as "unchanged".
            guard encodePath.measures(stage) else {
                uncomparable.append("\(stage.rawValue): not measured by this run's --encode-path")
                continue
            }
            collect(stage: stage,
                    baselineStage: baselineStage,
                    into: &regressions,
                    improvements: &improvements,
                    uncomparable: &uncomparable)
        }
        compareThroughput(with: baseline,
                          into: &regressions,
                          improvements: &improvements,
                          uncomparable: &uncomparable)

        return Comparison(name: name,
                          regressions: regressions.sorted { abs($0.absoluteChange) > abs($1.absoluteChange) },
                          improvements: improvements.sorted { abs($0.absoluteChange) > abs($1.absoluteChange) },
                          uncomparable: uncomparable)
    }

    private func collect(stage: Stage,
                         baselineStage: BaselineLog.StageFigures,
                         into regressions: inout [Deviation],
                         improvements: inout [Deviation],
                         uncomparable: inout [String]) {
        let timing = stats(for: stage)
        let stageCounts = counts(for: stage)

        for metric in [Metric.time, .allocations, .retains, .releases] {
            let thresholds = Thresholds.forMetric(metric)
            guard let current = currentValue(metric, timing: timing, counts: stageCounts) else {
                if metric != .time {
                    uncomparable.append("\(stage.rawValue) \(metric.label): not counted in this run")
                }
                continue
            }
            for percentile in thresholds.checkedPercentiles {
                guard let baselineValue = baselineStage.value(for: metric, at: percentile) else {
                    uncomparable.append("\(stage.rawValue) \(metric.label) \(percentile.label): "
                        + "absent from the baseline")
                    continue
                }
                // Counters are a single deterministic figure, so they are compared once at p50 and the
                // percentile is carried only to name the threshold that judged them.
                let currentValue = metric == .time ? timing.percentile(percentile) : current
                guard thresholds.exceeded(baseline: baselineValue,
                                          current: currentValue,
                                          at: percentile) else { continue }
                let deviation = Deviation(stage: stage.rawValue,
                                          metric: metric,
                                          percentile: percentile,
                                          baseline: baselineValue,
                                          current: currentValue)
                if deviation.isImprovement {
                    improvements.append(deviation)
                } else {
                    regressions.append(deviation)
                }
            }
        }
    }

    private func currentValue(_ metric: Metric,
                              timing: Stats,
                              counts: AllocationCounts?) -> Double? {
        switch metric {
        case .time: return timing.median
        case .allocations: return counts.map { Double($0.allocations) }
        case .retains: return counts.map { Double($0.retains) }
        case .releases: return counts.map { Double($0.releases) }
        case .throughput: return nil
        }
    }

    private func compareThroughput(with baseline: BaselineLog,
                                   into regressions: inout [Deviation],
                                   improvements: inout [Deviation],
                                   uncomparable: inout [String]) {
        let last = iterations.last!
        let median = totalStats.median
        guard median > 0, let baselineThroughput = baseline.throughput else {
            uncomparable.append("throughput: baseline has no total median to derive it from")
            return
        }
        let current = Double(last.unzippedBytes) / 1_048_576 / median
        guard Thresholds.time.exceeded(baseline: baselineThroughput, current: current, at: .p50) else {
            return
        }
        let deviation = Deviation(stage: "TOTAL",
                                  metric: .throughput,
                                  percentile: .p50,
                                  baseline: baselineThroughput,
                                  current: current)
        if deviation.isImprovement {
            improvements.append(deviation)
        } else {
            regressions.append(deviation)
        }
    }
}
