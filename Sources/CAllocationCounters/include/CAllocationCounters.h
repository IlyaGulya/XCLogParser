#ifndef XCLOGPARSER_C_ALLOCATION_COUNTERS_H
#define XCLOGPARSER_C_ALLOCATION_COUNTERS_H

#include <stdbool.h>
#include <stdint.h>

/// Counts Swift runtime allocation and reference-counting events by swapping the
/// runtime's own function pointers, so a measured region reports its exact counts
/// without DTrace, without `sudo`, and without the ~20x slowdown that `ustack()`
/// imposes. Measured cost on a real log is +1.2%, which is why counts and timings
/// can come from the same run.
///
/// **Not thread-safe in the sense that matters**: the hooks sit on the process's
/// `swift_retain`/`swift_release`, so every thread in the process is counted, not
/// just the caller's. The counters are atomic, which keeps them from losing events
/// (a plain counter lost ~53% under 8 threads), but a region that runs concurrent
/// work still attributes other threads' events to itself. See `countingIsSupported`
/// in `AllocationCounters.swift` before trusting a figure.
///
/// Not linked into the XCLogParser library or the CLI - benchmark target only.

/// Whether counting works here. Callers must withhold counts rather than report
/// zeros when this is false.
///
/// True on Darwin and on Linux. This answers only "does this runtime expose the
/// pointers", which is a runtime check rather than a constant: they are
/// implementation details of `libswiftCore` rather than API, so a future toolchain
/// may drop them.
///
/// It deliberately does **not** answer "is hooking safe here". The Swift 6.3 Linux
/// runtime exposes these pointers and then faults once they are used, because
/// `_swift_retain_adapterImpl` over-masked its argument (fixed upstream in
/// swiftlang/swift#88924, expected in 6.4). That defect is unreachable by any probe
/// that does not itself crash, so it is gated by toolchain version on the Swift side
/// - see `countingIsSupported` in `AllocationCounters.swift`. Call that, not this,
/// to decide whether to count.
bool xclog_counters_available(void);

/// Begins counting, resetting all counters to zero. Idempotent only in the sense
/// that a second call re-arms from zero; it does not nest.
void xclog_counters_start(void);

/// Stops counting and restores the runtime's original pointers. The totals stay
/// readable afterwards.
void xclog_counters_stop(void);

/// `swift_allocObject` calls in the measured region - class instances plus array
/// and string buffers. Excludes the `malloc` family, which the DTrace recipe in
/// Benchmarks/README.md also probes and which accounted for 0.7% of events there.
uint64_t xclog_counters_allocations(void);

/// `swift_retain` calls in the measured region.
uint64_t xclog_counters_retains(void);

/// `swift_release` calls in the measured region. May legitimately exceed retains:
/// objects created before the region can be released inside it.
uint64_t xclog_counters_releases(void);

#endif
