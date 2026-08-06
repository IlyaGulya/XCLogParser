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

/// Event counts, grouped in threes. Printed in full rather than abbreviated to "1.4M": these are
/// compared against each other across runs, and a change of a few thousand allocations is a real result
/// that rounding would erase.
func formatCount(_ count: UInt64) -> String {
    let digits = String(count)
    var grouped = ""
    for (offset, digit) in digits.enumerated() {
        if offset > 0 && (digits.count - offset) % 3 == 0 {
            grouped.append(",")
        }
        grouped.append(digit)
    }
    return grouped
}

/// Greedy word wrap, so an explanatory paragraph can be authored as one string and still line up under
/// its label. Collapses existing newlines: the input is prose, and where it wrapped in source is not
/// where it should wrap on screen.
func wrap(_ text: String, width: Int) -> [String] {
    var lines: [String] = []
    var current = ""
    for word in text.split(whereSeparator: { $0 == " " || $0.isNewline }) {
        if current.isEmpty {
            current = String(word)
        } else if current.count + 1 + word.count <= width {
            current += " " + word
        } else {
            lines.append(current)
            current = String(word)
        }
    }
    if !current.isEmpty {
        lines.append(current)
    }
    return lines
}

extension LogReport {
    /// Allocation and retain/release events per stage.
    ///
    /// Absolute counts and a share of allocations, deliberately without a share of *time*: the two do not
    /// track each other, and assuming they do has misled this work repeatedly - `moveSwiftStepsToRoot`
    /// took 16.7% of all retains while allocating nothing at all. The point of putting these next to the
    /// timing table is to make that divergence visible, not to imply a correspondence.
    func printAllocationReport() {
        print("")
        guard countsAreAvailable else {
            // The reason, not just the absence: one of these is "this toolchain has a known bug" and
            // the other is "this runtime changed shape", and they send you to different places.
            let reason = AllocationCounters.unsupportedReason
                ?? "no stage reported counts, though the hooks are supported here"
            print("   allocations: not measured -")
            for line in wrap(reason, width: 74) {
                print("                \(line)")
            }
            print("                Counts are deterministic, so they can be taken from any supported")
            print("                host under any load; only timings need an idle one.")
            #if canImport(Darwin)
            print("                For per-function attribution, use the DTrace recipe in")
            print("                Benchmarks/README.md - that is what ustack() buys.")
            #endif
            return
        }
        print("   \("Stage".padding(toLength: 24, withPad: " ", startingAt: 0))"
            + "\("allocations".padding(toLength: 14, withPad: " ", startingAt: 0))"
            + "\("share".padding(toLength: 9, withPad: " ", startingAt: 0))"
            + "\("retains".padding(toLength: 14, withPad: " ", startingAt: 0))"
            + "releases")
        print("   " + String(repeating: "─", count: 75))

        let totals = Stage.allCases.compactMap { counts(for: $0) }.reduce(AllocationCounts.zero, +)
        for stage in Stage.allCases {
            guard let stageCounts = counts(for: stage) else {
                // Printed rather than skipped. A stage that silently vanishes from the table reads as
                // one that allocated nothing worth a row, which is the same false negative the timing
                // table used to produce for an unselected encode path.
                print("   \(stage.label.padding(toLength: 24, withPad: " ", startingAt: 0))"
                    + "\("-".padding(toLength: 14, withPad: " ", startingAt: 0))"
                    + "\("-".padding(toLength: 9, withPad: " ", startingAt: 0))"
                    + "\("-".padding(toLength: 14, withPad: " ", startingAt: 0))"
                    + "not run")
                continue
            }
            let share = totals.allocations > 0
                ? Double(stageCounts.allocations) / Double(totals.allocations) * 100
                : 0
            print("   \(stage.label.padding(toLength: 24, withPad: " ", startingAt: 0))"
                + "\(formatCount(stageCounts.allocations).padding(toLength: 14, withPad: " ", startingAt: 0))"
                + "\(String(format: "%5.1f%%", share).padding(toLength: 9, withPad: " ", startingAt: 0))"
                + "\(formatCount(stageCounts.retains).padding(toLength: 14, withPad: " ", startingAt: 0))"
                + formatCount(stageCounts.releases))
        }
        print("   " + String(repeating: "─", count: 75))
        print("   \("TOTAL".padding(toLength: 24, withPad: " ", startingAt: 0))"
            + "\(formatCount(totals.allocations).padding(toLength: 14, withPad: " ", startingAt: 0))"
            + "\("100.0%".padding(toLength: 9, withPad: " ", startingAt: 0))"
            + "\(formatCount(totals.retains).padding(toLength: 14, withPad: " ", startingAt: 0))"
            + formatCount(totals.releases))
        // Said in every run rather than left to the README: these two caveats are what stop the figures
        // being compared against a DTrace total and declared broken.
        print("   counts cover swift_allocObject only, not the malloc family (0.7% of events on the")
        print("   flagged log), and count every thread in the process, not just this stage's own work.")
    }

    /// Footprint at each stage boundary, in absolute MB over the baseline.
    ///
    /// A separate table rather than more columns on the timing one: these are the figures a memory change
    /// is judged by. Deliberately absolute and never a percentage - a change to total memory moves every
    /// other stage's share even when that stage's own cost did not move, the same trap already documented
    /// for time shares in Benchmarks/README.md.
    /// One row per stage: footprint, its delta, and how much the peak RSS rose.
    private func printMemoryRows() {
        var previous: Double = 0
        var previousPeak: Double = 0
        for stage in Stage.allCases {
            // The peak-RSS rise is printed for every stage that ran, including the encode path whose
            // footprint is not falsifiable: the two metrics fail in different ways, and the high-water
            // mark is not affected by the allocator having kept the other path's pages.
            let peakRise = residentPeakRise(for: stage, previous: &previousPeak)
            guard let footprint = footprint(for: stage) else {
                continue
            }
            guard footprintIsFalsifiable(for: stage) else {
                // The number exists but would be a lie of omission: it is near-zero by construction.
                print("   \(stage.label.padding(toLength: 24, withPad: " ", startingAt: 0))"
                    + "\("not falsifiable".padding(toLength: 26, withPad: " ", startingAt: 0))"
                    + peakRise)
                continue
            }
            print("   \(stage.label.padding(toLength: 24, withPad: " ", startingAt: 0))"
                + "\(formatBytes(Int(footprint)).padding(toLength: 14, withPad: " ", startingAt: 0))"
                + String(format: "%+.1f MB", (footprint - previous) / 1_048_576)
                    .padding(toLength: 12, withPad: " ", startingAt: 0)
                + peakRise)
            previous = footprint
        }
    }

    func printMemoryReport() {
        print("")
        guard memoryIsMeaningful else {
            print("   memory: not measured. Anything that already grew the heap - a warmup, or an earlier")
            print("           log in this same run - makes every footprint reading cumulative, because")
            print("           phys_footprint never gives those pages back. Measure one log per process,")
            print("           with --warmup 0.")
            return
        }
        print("   \("Stage".padding(toLength: 24, withPad: " ", startingAt: 0))"
            + "\("footprint".padding(toLength: 14, withPad: " ", startingAt: 0))"
            + "\("delta".padding(toLength: 12, withPad: " ", startingAt: 0))"
            + "peak RSS rise")
        print("   " + String(repeating: "─", count: 66))
        printMemoryRows()
        print("   " + String(repeating: "─", count: 66))
        if encodePath == .both {
            print("   Encode memory: only \(encodePath.trustedFootprintStage.label) is measured against an")
            print("   untouched heap. The other path ran second, and phys_footprint never gives pages")
            print("   back, so its delta would read near-zero even if it buffered the whole report.")
            print("   Re-run with --encode-path streaming (or buffered) to measure one path per process.")
        }
        if let peak = peakFootprint {
            print("   \("PEAK".padding(toLength: 24, withPad: " ", startingAt: 0))"
                + formatBytes(Int(peak)))
        }
        print("   (phys_footprint over the pre-read baseline, first iteration only - see")
        print("    LogReport.footprint(for:) for why later iterations cannot be used)")
        // Stated here because a footprint table is exactly when someone concludes a memory change is
        // settled, and these two figures answer different questions. The harness deliberately keeps the
        // tree and the report alive together and never writes the report out; the CLI writes it and
        // drops it. Measured on baseline-noflags: 990.6 MB here against 832.6 MB from the CLI.
        print("")
        print("   Peak here is the harness's own peak, not the CLI's: this process retains the parsed")
        print("   tree and the encoded report simultaneously and never writes the report out. For a")
        print("   change to how the report is built or handed over, measure the real command with")
        print("   /usr/bin/time -l as well - a transient double buffer can be invisible to")
        print("   phys_footprint and plainly visible in peak RSS.")
    }
}
