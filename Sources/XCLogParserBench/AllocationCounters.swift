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
import Foundation

/// Allocation and reference-counting event counts for one measured region.
struct AllocationCounts {
    /// `swift_allocObject` calls: class instances plus array and string buffers.
    var allocations: UInt64 = 0
    var retains: UInt64 = 0
    var releases: UInt64 = 0

    static let zero = AllocationCounts()

    static func + (lhs: AllocationCounts, rhs: AllocationCounts) -> AllocationCounts {
        AllocationCounts(allocations: lhs.allocations + rhs.allocations,
                         retains: lhs.retains + rhs.retains,
                         releases: lhs.releases + rhs.releases)
    }
}

/// Counts Swift runtime allocation and retain/release events around a region of code.
///
/// Replaces the DTrace recipe in `Benchmarks/README.md` for *totals*, and unlike it needs no `sudo` and
/// costs +1.2% on a real log rather than the ~20x that `ustack()` imposes - which is why counts can be
/// collected in the same run as the timings instead of a separate one. The DTrace recipe is still the
/// only way to get per-function attribution, because that is what `ustack()` buys.
///
/// Two limits worth stating, because a count that silently means something else is worse than no count:
///
/// - The hooks sit on the process's `swift_retain`/`swift_release`, not on the caller. Every thread is
///   counted. The XCLogParser pipeline is single-threaded except `SwiftCompilerParser.findRawSwiftTimes`,
///   which needs swiftc timing flags and so runs on neither benchmark log - but a region that does run
///   concurrent work will attribute other threads' events to itself.
/// - Only the `swift_allocObject` family is hooked, not `malloc`. On the flagged log DTrace measured
///   `swift_allocObject` at 10,950,109 against 71,688 for `malloc`, so this covers ~99.3% of events and
///   reads legitimately low against a DTrace total.
enum AllocationCounters {
    /// Why counting is off, when it is. `nil` means counting is on.
    ///
    /// A reason rather than a bare `false`: the two ways this can fail need different responses from
    /// whoever reads the report, and "not measured" alone sends them looking in the wrong place.
    static var unsupportedReason: String? {
        // Ordered so the version gate wins: on Linux 6.3 the pointers *are* exposed, so asking
        // `xclog_counters_available()` first would report the wrong reason - or, worse, report
        // available and then crash.
        #if os(Linux) && compiler(>=6.3) && !compiler(>=6.4)
        return """
            the Swift 6.3 Linux runtime faults when these hooks are installed \
            (_swift_retain_adapterImpl over-masks its argument; fixed upstream in \
            swiftlang/swift#88924, expected in 6.4). Counting is disabled here rather than \
            crashing the benchmark. Use a 6.2.x or 6.4+ Linux toolchain, or a Darwin host.
            """
        #else
        guard xclog_counters_available() else {
            return """
                this runtime does not expose the swift_allocObject/retain/release pointers, \
                which are libswiftCore internals rather than API
                """
        }
        return nil
        #endif
    }

    /// Whether counting works here, in both senses: the runtime exposes the pointers *and* this
    /// toolchain is one where using them is safe.
    ///
    /// The pointers are `libswiftCore` internals rather than API, so exposure is checked rather than
    /// assumed. Safety cannot be checked at all - see `unsupportedReason` - so it is gated by version.
    /// When false, callers must withhold counts rather than report zeros, which would read as
    /// "measured, and nothing happened".
    ///
    /// One caveat this cannot close: the version gate reads the *compiling* toolchain, while the bug
    /// lives in the `libswiftCore` loaded at run time. They match under SwiftPM, but a binary built
    /// with 6.2 and run against a 6.3 runtime would slip through and fault.
    static var countingIsSupported: Bool {
        unsupportedReason == nil
    }

    /// Runs `body`, returning its value alongside the events counted during it.
    ///
    /// Returns `nil` counts when the hooks are unavailable, so the caller cannot mistake an
    /// unmeasurable region for an empty one.
    static func measuring<T>(_ body: () throws -> T) rethrows -> (value: T, counts: AllocationCounts?) {
        guard countingIsSupported else {
            return (try body(), nil)
        }

        xclog_counters_start()
        // `stop` before reading, so neither the read nor anything the runtime does on the way out of
        // `body` is counted.
        let value: T
        do {
            value = try body()
        } catch {
            xclog_counters_stop()
            throw error
        }
        xclog_counters_stop()

        return (value, AllocationCounts(allocations: xclog_counters_allocations(),
                                        retains: xclog_counters_retains(),
                                        releases: xclog_counters_releases()))
    }
}
