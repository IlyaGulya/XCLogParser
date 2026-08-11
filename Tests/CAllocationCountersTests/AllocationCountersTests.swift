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

import CAllocationCounters
import XCTest

private final class Holder {
    var value: Int
    init(_ value: Int) { self.value = value }
}

/// What the counters observed over one measured region. A struct rather than a tuple so the three
/// figures are named at every use - they are easy to transpose and impossible to tell apart by type.
private struct Observed {
    let allocations: UInt64
    let retains: UInt64
    let releases: UInt64
}

/// Holds references so allocations escape and cannot be stack-promoted or deleted outright.
///
/// This is load-bearing, not defensive. A release build removes `_ = Holder(1)` entirely, and even
/// `Holder(1).value` folds to a constant with the allocation elided - the first version of these checks
/// reported zero for every case and looked like a broken counter when in fact nothing had been allocated.
/// A count of zero for code the optimizer deleted is correct and validates nothing, so every object here
/// is stored somewhere observable.
private var escaped: [Holder] = []

/// Blocks ARC from removing a retain/release pair by hiding the reference behind a call it cannot inline.
@inline(never)
private func launder(_ box: Holder) -> Holder { box }

/// Checks the runtime counters against workloads whose event counts are known by construction.
///
/// # Why this exists rather than a comparison against DTrace
///
/// `Benchmarks/README.md` documents a DTrace recipe that counts the same events, and the obvious
/// validation is to run both and compare. That comparison is weaker than this one in two ways: it only
/// establishes that two counters agree, not that either is right, and it cannot be run at all on a host
/// where SIP reports `DTrace Restrictions: enabled`. Counting a loop that allocates exactly 1000 objects
/// needs no second tool to be authoritative.
final class AllocationCountersTests: XCTestCase {

    /// Mirrors the version gate in `AllocationCounters.swift`, which this target cannot import - it
    /// lives in the benchmark executable. Kept as one expression so the two stay easy to compare.
    ///
    /// Installing the hooks on Linux 6.3 does not fail an assertion, it faults the process
    /// (`_swift_retain_adapterImpl` over-masks; fixed in swiftlang/swift#88924, expected in 6.4). So
    /// this has to be checked before `xclog_counters_start`, not asserted after.
    private static let hookingIsSafeHere: Bool = {
        #if os(Linux) && compiler(>=6.3) && !compiler(>=6.4)
        return false
        #else
        return true
        #endif
    }()

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(Self.hookingIsSafeHere,
                          "Swift 6.3 on Linux faults when these hooks are installed - see "
                          + "Sources/CAllocationCounters/counters.c. Skipped rather than crashing "
                          + "the suite; run on 6.2.x, 6.4+, or Darwin to exercise it.")
        escaped = []
        escaped.reserveCapacity(8192)
    }

    /// Runs `body` with the counters active and returns what they saw.
    private func counting(_ body: () -> Void) -> Observed {
        xclog_counters_start()
        body()
        xclog_counters_stop()
        return Observed(allocations: xclog_counters_allocations(),
                        retains: xclog_counters_retains(),
                        releases: xclog_counters_releases())
    }

    func testHooksAreAvailable() {
        // The counters hook `libswiftCore` internals rather than API, so a toolchain is entitled to stop
        // exposing them. Asserted rather than skipped: the benchmark withholds counts when this is false,
        // and a silent switch to withholding is how a regression check stops checking anything.
        XCTAssertTrue(xclog_counters_available(),
                      "The Swift runtime no longer exposes the hookable allocation pointers. "
                      + "The benchmark will report no counts until this is addressed.")
    }

    /// A region that allocates nothing must report zero, not a floor of runtime bookkeeping.
    ///
    /// The distinction the whole design rests on: the benchmark reports absent counts when it cannot
    /// measure, and zero only when nothing happened. A nonzero floor here would make those two
    /// indistinguishable in the output.
    func testEmptyRegionCountsZero() {
        let counts = counting {}
        XCTAssertEqual(counts.allocations, 0)
        XCTAssertEqual(counts.retains, 0)
        XCTAssertEqual(counts.releases, 0)
    }

    func testSingleAllocationIsCountedExactly() {
        let counts = counting { escaped.append(Holder(1)) }
        XCTAssertEqual(counts.allocations, 1)
    }

    func testThousandAllocationsAreCountedExactly() {
        let counts = counting {
            for index in 0..<1000 { escaped.append(Holder(index)) }
        }
        XCTAssertEqual(counts.allocations, 1000)
    }

    /// Each region must measure its own work, not the total since the process started.
    ///
    /// This is what lets the benchmark take a median across iterations: the footprint figures cannot be
    /// averaged because `phys_footprint` never returns pages, and the counters can only be averaged
    /// because `start` genuinely resets them.
    func testCountersResetBetweenRegions() {
        _ = counting {
            for index in 0..<1000 { escaped.append(Holder(index)) }
        }
        let second = counting {
            for index in 0..<1000 { escaped.append(Holder(index)) }
        }
        XCTAssertEqual(second.allocations, 1000, "Counters accumulated across regions instead of resetting")
    }

    /// Retains are counted per reference taken, with no allocation involved.
    ///
    /// Exercised through `launder` because ARC elides pairs it can prove redundant - a loop that merely
    /// copies a reference legitimately counts zero, which is why this passes each one through a call the
    /// optimizer cannot see across.
    func testRetainsAreCountedWithoutAllocating() {
        escaped.append(Holder(0))
        let shared = escaped[0]
        var laundered: [Holder] = []
        laundered.reserveCapacity(5000)
        let counts = counting {
            for _ in 0..<5000 { laundered.append(launder(shared)) }
        }
        XCTAssertEqual(counts.retains, 5000)
        XCTAssertEqual(laundered.count, 5000)
    }

    /// `stop` must restore the runtime's own pointers, so nothing is counted afterwards.
    ///
    /// A leaked hook would not merely inflate a later stage - it would keep the counting overhead on
    /// every retain in the process for the rest of its life.
    func testNothingIsCountedAfterStop() {
        _ = counting { escaped.append(Holder(1)) }
        for index in 0..<1000 { escaped.append(Holder(index)) }
        let after = counting {}
        XCTAssertEqual(after.allocations, 0, "Allocations outside a measured region were still counted")
    }
}
