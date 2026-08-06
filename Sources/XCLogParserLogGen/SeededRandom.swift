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

/// A seeded PRNG, so a profile plus its seed always produces byte-identical output.
///
/// Deliberately not `SystemRandomNumberGenerator`, and deliberately not the stdlib's `random(in:)`
/// helpers on top of it: reproducibility is the point here. A generated log has to be regenerable
/// months later from the checked-in profile, otherwise a benchmark comparison against an older run
/// is comparing two different inputs. The algorithm is SplitMix64, which is small enough to read and
/// has no state beyond the seed.
///
/// Not for anything needing unpredictability.
public struct SeededRandom: RandomNumberGenerator {

    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    /// A uniform integer in `range`, inclusive.
    public mutating func int(in range: ClosedRange<Int>) -> Int {
        guard range.lowerBound < range.upperBound else { return range.lowerBound }
        let span = UInt64(range.upperBound - range.lowerBound) + 1
        return range.lowerBound + Int(next() % span)
    }

    /// A uniform double in `0..<1`.
    public mutating func unitDouble() -> Double {
        // 53 bits is what a Double can hold exactly, so this is uniform over representable values.
        return Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }

    /// Picks an index by relative weight. Weights need not be normalised.
    public mutating func weightedIndex(weights: [Double]) -> Int {
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        var target = unitDouble() * total
        for (index, weight) in weights.enumerated() {
            target -= weight
            if target < 0 { return index }
        }
        return weights.count - 1
    }
}
