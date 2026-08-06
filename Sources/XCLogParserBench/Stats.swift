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

/// The percentiles the tables and the baseline diff are keyed by.
///
/// Deliberately the same set ordo-one's package-benchmark reports, so a figure from either tool means
/// the same thing. `p0`/`p100` are the min and max under their percentile names: a threshold model keyed
/// by percentile has to be able to say "the fastest sample must not get slower" too, and special-casing
/// min and max as separate fields is what made the previous comparison a hand exercise.
enum Percentile: String, CaseIterable {
    case p0
    case p25
    case p50
    case p75
    case p90
    case p99
    case p100

    /// The fraction of the sorted sample this percentile sits at.
    var fraction: Double {
        switch self {
        case .p0: return 0
        case .p25: return 0.25
        case .p50: return 0.5
        case .p75: return 0.75
        case .p90: return 0.90
        case .p99: return 0.99
        case .p100: return 1
        }
    }

    var label: String { rawValue }
}

struct Stats {
    let samples: [Double]

    var min: Double { samples.min() ?? 0 }
    var max: Double { samples.max() ?? 0 }
    /// Zero for an empty sample, matching `min` and `max` above rather than dividing by zero.
    ///
    /// A stage that never ran has no samples - the streaming encode path is one whenever a build
    /// predates it, or when `--encode-path buffered` is passed. The bare division returns NaN there,
    /// which prints as a harmless `0.0 ms` in the table but makes `JSONSerialization` throw an
    /// `NSInvalidArgumentException` that no `catch` here can see: the process aborts, `--json` writes
    /// nothing, and the run looks successful to anything reading only the exit path.
    var mean: Double { samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count) }

    var median: Double { percentile(.p50) }

    /// The value at `percentile`, by nearest-rank on the sorted sample.
    ///
    /// Nearest-rank rather than interpolating, and no histogram: this harness takes 3-10 samples per
    /// stage, not the millions an HDR histogram is built for. Interpolation between two of five samples
    /// would invent a duration that no iteration actually took, and the point of these figures is that
    /// each one is a run that happened.
    ///
    /// The consequence of a small sample is real and not hidden by this: with 5 samples, `p90` and `p99`
    /// both resolve to the slowest one. `printPercentileNote` says so in the output rather than letting
    /// three identical columns read as a converged distribution.
    func percentile(_ percentile: Percentile) -> Double {
        let sorted = samples.sorted()
        guard sorted.isEmpty == false else { return 0 }
        // p50 keeps averaging the middle pair on an even count, which is what `median` has always
        // reported and what every recorded figure in Benchmarks/README.md was computed with. The other
        // percentiles take the nearest rank, so they always name a real sample.
        if percentile == .p50, sorted.count % 2 == 0 {
            let mid = sorted.count / 2
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        let rank = Int((percentile.fraction * Double(sorted.count - 1)).rounded())
        return sorted[rank]
    }

    /// Sample standard deviation. Zero for a single sample.
    var stddev: Double {
        guard samples.count > 1 else { return 0 }
        let mean = self.mean
        let variance = samples.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(samples.count - 1)
        return variance.squareRoot()
    }

    /// The highest percentile this many samples can distinguish from `p100`.
    ///
    /// With `n` samples, nearest-rank collapses every percentile above `1 - 1/(2(n-1))` onto the slowest
    /// sample. Used to caption the table rather than to drop columns: a reader comparing p90 against p99
    /// needs to know when they are the same number by arithmetic rather than by measurement.
    var distinguishablePercentiles: [Percentile] {
        guard samples.count > 1 else { return [.p0] }
        var seen: [Int: Percentile] = [:]
        for percentile in Percentile.allCases {
            let rank = Int((percentile.fraction * Double(samples.count - 1)).rounded())
            if seen[rank] == nil { seen[rank] = percentile }
        }
        return Percentile.allCases.filter { seen[Int(($0.fraction * Double(samples.count - 1)).rounded())] == $0 }
    }
}
