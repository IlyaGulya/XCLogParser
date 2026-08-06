#include <stdatomic.h>
#include <stddef.h>

#include "CAllocationCounters.h"

// Works on Darwin, and on Linux except for the 6.3 series. The gate is split in two: this file decides
// whether the runtime exposes hookable pointers at all, and `AllocationCounters.swift` decides whether
// the *running toolchain* is one where hooking is safe. Neither half can do the other's job - see below.
//
// What goes wrong on Linux 6.3 is a runtime bug, not something about our hooks. `_swift_retain_adapterImpl`
// masked its argument with `~SwiftSpareBitsMask`, which strips the tag bits that make a small-string
// bridge-object payload *fail* `isValidPointerForNativeRetain`. Stripped of its tag, a payload of packed
// string bytes looks like a valid pointer, passes the guard in `_swift_retain_impl`, and the refcount load
// at +8 faults:
//
//     Bad pointer dereference at 0x676f70          <- "gop", string bytes read as an address
//     0  __swift_retain_ + 36            in libswiftCore.so
//     1  _swift_retain_adapterImpl       in libswiftCore.so
//
// `_swift_retain_impl` does the same thing correctly: it guards on the *unmasked* value first, then masks.
// Upstream fixed the adapter to mask with `~UntaggedNonNativeBridgeObjectBits` instead, in
// https://github.com/swiftlang/swift/pull/88924 (merged 2026-05-16, after 6.3.3, so expected in 6.4).
//
// Two things about this were counterintuitive enough to be worth recording, because both cost real time:
//
// 1. The adapter runs whether or not we count. Setting the three pointers is enough to route retains
//    through it, and a hook that only called the original died exactly the same way. The earlier note in
//    this file blamed a missing swizzle flag; that was wrong. The flag is not ours to set at all -
//    `CALL_IMPL_CHECK`, which `swift_allocObject` dispatches through, compares its slot against the
//    default target and arms the flag *itself* on the first mismatch. So hooking only `allocObject` and
//    never touching the flag still crashes. There is no subset of the three pointers that is safe on 6.3.
//
// 2. The bad values cannot be filtered in the hook. They are string *contents* reinterpreted as pointers:
//    measured 12,005 distinct values spanning 0x0..0x676f6c2e3938 (~113 TB), no marker bits, top 16 bits
//    zero, and which ones appear depends on what the strings say. Every address-shape heuristic tried here
//    (sign check, loaded-image ranges via `dl_iterate_phdr`, a learned heap floor, a fixed floor) either
//    let a faulting value through or - worse - silently rejected everything and reported zero events.
//
// Hence a version gate rather than a defensive hook. It cannot be a runtime probe either: the defect is
// only reachable once the swizzle flag is armed and a tagged payload is retained, which is precisely the
// sequence that crashes, and `libswiftCore` exports no version symbol to ask instead.
#if defined(__APPLE__) || defined(__linux__)

typedef struct HeapObject_s HeapObject;
typedef struct HeapMetadata_s HeapMetadata;

// On arm64 the runtime declares retain and release with `preserve_most`, on both Darwin
// and Linux. A hook installed with the default convention would be called under a
// contract it does not honour, so the attribute has to be mirrored here rather than
// left to chance. `swift_allocObject` uses the ordinary convention.
#if defined(__aarch64__) && defined(__clang__) && __has_attribute(preserve_most)
#define XCLOG_RC_CONVENTION __attribute__((preserve_most))
#else
#define XCLOG_RC_CONVENTION
#endif

// The Swift runtime keeps these as mutable function pointers, which is what makes
// hooking possible at all. They are internal to `libswiftCore` - `nm` shows them as
// `D` (data) under a double underscore, next to the single-underscore `T` (text)
// symbols that are the functions themselves:
//
//     0000000000398620 D __swift_allocObject
//     00000000002c9260 T _swift_allocObject
//
// Because they are not API, `xclog_counters_available()` checks them at runtime
// rather than assuming a future toolchain still provides them.
//
// `_swift_release` returns void; giving it a return type here would be a mismatched
// slot even though the wrong declaration happens to link.
extern HeapObject *(*_swift_allocObject)(HeapMetadata const *, size_t, size_t);
extern HeapObject *(*_swift_retain)(HeapObject *) XCLOG_RC_CONVENTION;
extern void (*_swift_release)(HeapObject *) XCLOG_RC_CONVENTION;

static HeapObject *(*original_allocObject)(HeapMetadata const *, size_t, size_t);
static HeapObject *(*original_retain)(HeapObject *) XCLOG_RC_CONVENTION;
static void (*original_release)(HeapObject *) XCLOG_RC_CONVENTION;

// Atomic because the hooks sit on the whole process: any thread that retains an
// object lands here, so the increments race even when the code under measurement
// is single-threaded. A plain `uint64_t` is not merely imprecise here, it is a data
// race - and it was measured losing ~53% of events under 8 threads, reproducibly.
// `memory_order_relaxed` is enough: only the totals matter, never the ordering
// between them, and on arm64 it lowers to a single uncontended `ldadd`.
static _Atomic uint64_t allocation_count;
static _Atomic uint64_t retain_count;
static _Atomic uint64_t release_count;

static HeapObject *hook_allocObject(HeapMetadata const *metadata,
                                    size_t requiredSize,
                                    size_t requiredAlignmentMask) {
    HeapObject *object = original_allocObject(metadata, requiredSize, requiredAlignmentMask);
    atomic_fetch_add_explicit(&allocation_count, 1, memory_order_relaxed);
    return object;
}

static HeapObject *hook_retain(HeapObject *object) XCLOG_RC_CONVENTION {
    HeapObject *result = original_retain(object);
    atomic_fetch_add_explicit(&retain_count, 1, memory_order_relaxed);
    return result;
}

static void hook_release(HeapObject *object) XCLOG_RC_CONVENTION {
    original_release(object);
    atomic_fetch_add_explicit(&release_count, 1, memory_order_relaxed);
}

bool xclog_counters_available(void) {
    return _swift_allocObject != NULL && _swift_retain != NULL && _swift_release != NULL;
}

void xclog_counters_start(void) {
    if (!xclog_counters_available()) {
        return;
    }

    atomic_store_explicit(&allocation_count, 0, memory_order_relaxed);
    atomic_store_explicit(&retain_count, 0, memory_order_relaxed);
    atomic_store_explicit(&release_count, 0, memory_order_relaxed);

    original_allocObject = _swift_allocObject;
    original_retain = _swift_retain;
    original_release = _swift_release;

    _swift_allocObject = hook_allocObject;
    _swift_retain = hook_retain;
    _swift_release = hook_release;
}

void xclog_counters_stop(void) {
    // Guarded because `start` leaves the originals NULL when the pointers are
    // unavailable, and restoring NULL would break every subsequent retain.
    if (original_allocObject == NULL) {
        return;
    }

    _swift_allocObject = original_allocObject;
    _swift_retain = original_retain;
    _swift_release = original_release;

    original_allocObject = NULL;
    original_retain = NULL;
    original_release = NULL;
}

uint64_t xclog_counters_allocations(void) {
    return atomic_load_explicit(&allocation_count, memory_order_relaxed);
}

uint64_t xclog_counters_retains(void) {
    return atomic_load_explicit(&retain_count, memory_order_relaxed);
}

uint64_t xclog_counters_releases(void) {
    return atomic_load_explicit(&release_count, memory_order_relaxed);
}

#else

// Platforms other than Darwin and Linux: the runtime may well keep these pointers, but nothing here has
// been tested against one, and an untested hook into refcounting is worse than no counts.
//
// Reports unavailable, which is what the benchmark already knows how to handle. Returning zero counts
// instead would read as "measured, and nothing happened".
bool xclog_counters_available(void) {
    return false;
}

void xclog_counters_start(void) {
}

void xclog_counters_stop(void) {
}

uint64_t xclog_counters_allocations(void) {
    return 0;
}

uint64_t xclog_counters_retains(void) {
    return 0;
}

uint64_t xclog_counters_releases(void) {
    return 0;
}

#endif
