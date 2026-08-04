# Benchmarking and profiling XCLogParser

Tooling for measuring where time goes when parsing an `.xcactivitylog`.

## Running the benchmark

```bash
swift build -c release --product xclogparser-bench
./.build/release/xclogparser-bench -n 5 --warmup 1 --json Benchmarks/Results/latest.json
```

With no arguments it benchmarks every `.xcactivitylog` in `Benchmarks/Logs`
(gitignored — drop your own logs there). Pass paths explicitly to override.

| Flag | Meaning |
| --- | --- |
| `-n`, `--iterations` | Measured iterations per log (default 3) |
| `--warmup` | Unmeasured warmup iterations (default 1) |
| `--redacted` | Redact the user directory while lexing |
| `--without-build-specific-information` | Strip build-specific information while lexing |
| `--json <path>` | Also write results as JSON |
| `--baseline <path>` | Diff this run against a previous `--json` file — see ["Comparing two runs"](#comparing-two-runs) |
| `--encode-path <p>` | Which encode path to measure: `both` (default), `buffered`, `streaming`. Only the encode stage that runs first in a process has a falsifiable footprint — see ["A commit's effect is a property of what you ran"](#a-commits-effect-is-a-property-of-what-you-ran-not-of-the-commit). `both` still times both, but prints no footprint for the second. |

The tool times each pipeline stage separately — read, gunzip, UTF-8 decode,
`Lexer.tokenize`, `ActivityParser`, `ParserBuildSteps` — and reports
p0/p50/p90/p99/p100 and stddev, each stage's share, allocation and
retain/release counts, peak RSS and throughput. Timings use the monotonic clock
(`DispatchTime.uptimeNanoseconds`).

Percentiles are nearest-rank on the sorted samples, with no interpolation and no
histogram: with 3–10 samples per stage, interpolating would invent a duration no
iteration actually took. The consequence is that the high percentiles collapse
onto the slowest sample — with 5 samples, p90, p99 and p100 are the same number.
The report says which percentiles the sample size can resolve rather than
letting three identical columns read as a converged distribution.

### Comparing two runs

```bash
# before
git checkout <baseline-commit>
swift build -c release --product xclogparser-bench
./.build/release/xclogparser-bench "$PWD/Benchmarks/Logs/your.xcactivitylog" \
  -n 5 --json /tmp/before.json

# after
git checkout <your-branch>
swift build -c release --product xclogparser-bench
./.build/release/xclogparser-bench "$PWD/Benchmarks/Logs/your.xcactivitylog" \
  -n 5 --baseline /tmp/before.json
```

Regressions and improvements are printed as two separate lists, not netted into
one signed total — a win in one stage must not be able to mask a regression in
another. Logs are matched by name, so reordering them cannot compare one log's
figures against another's, and anything that could not be compared is listed
explicitly: a comparison covering three of seven stages otherwise prints the
same verdict as one covering all seven.

The two metric families take different thresholds, and the split is the point:

| Metric | Threshold | Why |
| --- | --- | --- |
| time, throughput | ±5% **and** ±1 ms, at p50 and p90 | Both must be exceeded. Relative alone flags a 6% swing on a 0.4 ms stage nobody can act on; absolute alone flags 20 ms on a 4 s stage that is inside this host's noise. |
| allocations, retains, releases | exact — any change at all | "Allocations did not grow by even one" is a statement about identity, not magnitude, and no percentage expresses it. |

Counters can be held to an exact threshold because they are deterministic where
the timings are not: two runs 26% apart in wall time reported byte-identical
counts. **A counter verdict is a statement about the code; a timing verdict is
partly a statement about the host.** On a loaded machine the counter half of
this diff is still worth reading and the timing half is not.

#### Pass the same *kind* of path to both runs

Use an absolute path, and the same form on both sides. A relative path costs
**20 extra allocations** in the `read` stage (27 against 7), deterministically,
because `Data(contentsOf:)` resolves a relative `URL` against the current
directory and that resolution allocates.

This is small, but it is in the first stage and it is exactly the shape of a
real finding: stable across processes, reproducible, and attributable to a named
stage. Passing an absolute path to the baseline run and a relative one to the
comparison run produced a confident three-line `read` regression — `+285.7%`
allocations, `+550.0%` retains — that was entirely an artifact of the invocation.
The counters are exact enough to resolve the benchmark's own arguments, so
anything not held identical between the two runs shows up as a library change.

### The report names the paths your log never exercised

Two parser paths run only on logs that meet a condition:

| function | needs |
| --- | --- |
| `assignNoticesFrom` | a whole-module build |
| `addSwiftcTimesSteps` | `-Xfrontend -debug-time-function-bodies` or `-debug-time-expression-type-checking` |

Every run ends by naming the ones that did not run. This is not a nicety: **a
whole-log diff over a change to an unexecuted path reports "identical", and
identical reads as verified.** That is a false negative dressed as a pass, and it
is the same class of problem as a footprint that cannot be falsified — so it gets
the same treatment the rest of the harness gives that class, named in the output
rather than omitted from it.

The check evaluates the library's own gates through public API and log content;
it does not instrument the library, and it runs outside the timed stages so that
re-walking the section tree is not charged to the parser.

Worth knowing what this immediately corrected: the 14 MB baseline log **does**
exercise `assignNoticesFrom` — 53,717 `Compile <file>.swift` steps in its output,
each one synthesized by that path — and only `addSwiftcTimesSteps` is missing.
The assumption going in was that neither log covered either path. Coverage is a
property of the log, and guessing at it from the project's shape was wrong.

### Figures are comparable within a platform, not across

The harness runs on Linux as well as macOS, and reports the same three metrics on
both. Those metrics do **not** convert between the two. Measured on one generated
294 MB log, same bytes on both hosts (`sha256` verified), so nothing about the
input differs:

| stage | macOS p50 | Linux p50 | macOS allocations | Linux allocations |
|---|---|---|---|---|
| Read file | 1.4 ms | 9.6 ms | 7 | 7 |
| Gunzip | 49.2 ms | 652.9 ms | 1 | 1 |
| Tokenize (Lexer) | 79.5 ms | 276.7 ms | **433,621** | **433,621** |
| Parse IDEActivityLog | 88.1 ms | **18.805 s** | 420,745 | 704,014 |
| Parse BuildStep tree | 617.0 ms | 1.822 s | 993,322 | 2,096,980 |
| Encode JSON (buffered) | 207.4 ms | 775.1 ms | 4 | 4 |
| TOTAL | 1.229 s | 22.861 s | 1,847,797 | 3,234,724 |

Hardware differs (10-core Apple silicon against 4 Xeon cores in a container), so
a flat 3-4x on most stages is expected and uninteresting. Two things in this table
are not about hardware:

**`Tokenize` matches bit-for-bit.** It is pure Swift with no Foundation on its
path, and 433,621 on both platforms is the evidence that the Linux counters count
correctly rather than approximately. Where the numbers diverge, the divergence is
real and not an artefact of the measurement.

**The stages that diverge are the Foundation-heavy ones**, by +67% and +111%.
Linux resolves Foundation through swift-foundation and Darwin through
ObjC-Foundation; these are different implementations, so they allocate different
amounts for the same call. Comparing a Linux count against a macOS count measures
the two standard libraries, not the change under test.

**`Parse IDEActivityLog` is 7% of the run on macOS and 82% on Linux** — 213x
slower in absolute terms where neighbouring stages are 3x. That size of gap is not
hardware and not a measurement artefact; it is a property of the Linux Foundation
path through that stage, and it makes the stage worth profiling on Linux in its
own right.

What follows from this: use a baseline recorded on the same platform, and never
quote a figure from one platform in a comparison against the other. The report
names its footprint source (`phys_footprint` on Darwin, `RssAnon` on Linux) for
the same reason.

## Measure on an idle machine

This is not optional. Benchmarking under load produced a *3x slowdown* and a
15s standard deviation, which read as a code regression but was a loaded host
(load average 72, from unrelated JVM and container processes).

```bash
sysctl -n vm.loadavg     # want the 1-minute figure low, ~1-2
```

On a quiet host the same benchmark has a stddev under ~1% of the median. If
stddev exceeds a few percent, or peak RSS shifts a lot between runs, discard
the numbers — do not interpret them.

A second occasion made the point again, with numbers worth keeping for calibration.
The same commit and the same log, measured on a loaded workstation and then on an
idle 12-core host:

| | loaded (load avg ~190) | idle (load avg 1.7) |
|---|---|---|
| total | 1.3–3.4 s | **643.7 ms** |
| stddev | 820 ms | **8.9 ms** |
| agreement across 3 process runs | none | within 13 ms |

Nothing about the binary changed. The loaded host cannot answer a timing question at
all — not "roughly", not "as a lower bound". Memory figures are unaffected, since
`phys_footprint` does not depend on scheduling, so a loaded machine is still fine for
memory work; that is the only thing to do on it.

If no idle machine is available locally, measuring over `ssh` on one is worth the
setup: `rsync` the tree (excluding `.build`), build there, and run both the benchmark
and `/usr/bin/time -l` on the real CLI.

### Load average is not sufficient

A machine can show a healthy load average and still be unusable for timing.
Anything that hooks process execution — a security agent, a filesystem monitor —
taxes exactly the work a parser benchmark does, while contributing little to load
average. Seen here at 27-35% CPU on an otherwise idle host (load ~1.5): a 216 ms
stddev on a 9.5 s total where a quiet run gives 2.8 ms, a 77x spread, and peak RSS
inflated from 1167 MB to 1731 MB for code that only *removes* allocations. Those
numbers look like a regression and are pure measurement artefact, so check what
else is running before trusting a spread like that.

If no clean host is available, prefer the **minimum** across many interleaved
runs rather than the mean or median. Contention can only ever make a run
slower, so the minimum is the robust estimator; the mean is dominated by
whatever else the machine happened to do. Interleave variants (`A B C A B C …`)
rather than running each variant's iterations together, so a slow patch of
wall-clock cannot be mistaken for a property of one variant.

Allocation counts (below) need none of this — they are deterministic and
unaffected by CPU contention, which makes them the more trustworthy signal when
a quiet machine is out of reach.

## Profiling: what works and what does not

**`sample` and `xctrace` are not useful here.** In a release build the lexer and
parsers inline completely into the caller, so the entire library collapses into
a single frame (`main.swift:127` / `main.swift:145`) and ~0 samples get
attributed to any `XCLogParser` function. Adding `-g` does not restore
attribution, and `-Onone` distorts the profile too much to act on.

**DTrace does work, and it is the tool to reach for first.** It samples the
stack from outside the process, so inlining does not hide anything from it —
the same property that makes it work for allocation counts below.

### Where time goes — DTrace sampling

```bash
swift build -c release --product xclogparser-bench

sudo dtrace -x ustackframes=40 \
  -n 'profile-997 /pid == $target/ { @s[ustack(40)] = count(); }' \
  -c "./.build/release/xclogparser-bench -n 1 --warmup 0 <log>" > time.stacks
```

Aggregate by taking the innermost `xclogparser-bench` frame in each stack and
stripping the `+0x…` offset, which gives per-function shares directly:

```
15.02%  Scanner.scanCharacters
13.64%  ParserBuildSteps.parseLogSection
 5.12%  Notice.parseClangWarningFlags
```

This is what found the two largest wins in the file's history, and it also
caught a *regression* that had been introduced by an optimization: an ASCII
fast-path gate that scanned its whole input showed up at 14.7% of samples,
more than twice what the fast path saved elsewhere.

Same caveats as the allocation recipe: needs `sudo`, SIP must permit it, and
`ustack()` slows the run ~20x. Shares are comparable between runs; absolute
timings from such a run are not. `LogBenchmark.runIteration` appearing high is
the harness itself, not the library.

### Exact call counts — LLVM instrumentation

```bash
swift build -c release --product xclogparser-bench -Xswiftc -profile-generate

LLVM_PROFILE_FILE=out.profraw \
  ./.build/release/xclogparser-bench -n 1 --warmup 0 <log>

X=$(dirname $(xcrun --find swift))
$X/llvm-profdata merge -sparse out.profraw -o out.profdata
$X/llvm-profdata show --all-functions --counts --text out.profdata
```

Output is `path:mangled_name` followed by `# Counter Values:`. Pipe the mangled
names through `swift-demangle --compact` to read them.

Overhead is small (measured 10.9s/18.4s instrumented vs 10.8s/19.0s clean), but
these are **call counts, not time shares**. They find code that runs a huge
number of times; take absolute timings from an ordinary release run.

### Counting inputs — in-code probes

DTrace sampling gives time shares and instrumentation gives call counts, but
neither can tell you *how much data* a function was handed. A probe can, and
that is often the actual finding — so reach for this when you need to measure
inputs, not as a substitute for the sampler above.

```swift
enum ParseProbe {
    nonisolated(unsafe) static var buckets = [String: Double]()
    nonisolated(unsafe) static var counts = [String: Int]()

    @inline(never)
    static func t<T>(_ key: String, _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            buckets[key, default: 0] += Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            counts[key, default: 0] += 1
        }
        return try body()
    }
}
```

`@inline(never)` keeps the probe itself from being inlined away. Accumulate into
a bucket per call site, print at the end, then remove the probes before
committing.

The reason to bother: summing `text.utf8.count` alongside a marker check is what
revealed that 185MB of section text was being split while only 6.8% of sections
contained a diagnostic. No sampler reports that, because it is a property of the
data rather than of where cycles went.

### Allocation counts — built into the benchmark

For **totals per stage**, the benchmark reports them itself and no `sudo` or
DTrace is needed. It hooks the Swift runtime's `_swift_allocObject`,
`_swift_retain` and `_swift_release` function pointers — mutable data symbols in
`libswiftCore`, not API, so availability is checked at runtime rather than
assumed. When the hooks are unavailable the counts are reported as absent, never
as zero: "cannot measure" and "allocated nothing" must not print the same.

This costs **+2.65%** on a real log, which is why counts and timings come from
one run here where DTrace forces two: `ustack()` slows the process ~20x, so no
timing from that run means anything.

Two limits, stated in the tool's own output on every run:

- Only the `swift_allocObject` family is hooked, not `malloc` — ~99.3% of events
  on these logs, so the totals read slightly low against a DTrace figure.
- Every thread in the process is counted, not just the measured stage's own work.
  The pipeline is single-threaded except `SwiftCompilerParser.findRawSwiftTimes`,
  which needs swiftc timing flags and so runs on neither benchmark log.

**DTrace remains the only source of per-function attribution**, which is what
`ustack()` buys and what the recipe below is still for.

### Per-function attribution — DTrace

Based on the [Swift server guide on allocations][swift-allocations], with one
correction that matters a great deal here.

```bash
swift build -c release --product xclogparser-bench

sudo dtrace -n 'pid$target::swift_allocObject:entry,pid$target::swift_slowAlloc:entry,pid$target::malloc:entry,pid$target::calloc:entry,pid$target::realloc:entry,pid$target::posix_memalign:entry,pid$target::malloc_zone_malloc:entry,pid$target::malloc_zone_calloc:entry,pid$target::malloc_zone_memalign:entry { @s[ustack(40)] = count(); } ::END { printa(@s); }' \
  -c "./.build/release/xclogparser-bench -n 1 --warmup 0 <log>" > raw.stacks
```

**The guide's recipe probes only the `malloc` family, which here sees 0.7% of
reality.** Swift allocates class instances and array/string buffers through
`swift_allocObject`:

| probe | count |
| --- | --- |
| `swift_allocObject` | 10,950,109 |
| `malloc` | 71,688 |
| `swift_slowAlloc` | 175 |
| `realloc` | 31 |

Probing `malloc` alone blamed `Notice.parseClangWarningFlags` for 97.4% of
allocations — a real but negligible site — and entirely hid array growth in the
`Lexer`, which is the actual 41.7%. Always include `swift_allocObject`.

Like the time profile above, this defeats release-build inlining because it
hooks `libswiftCore` and walks the stack from outside the process. Two caveats:

- `ustack()` slows the run ~20x (60.5s vs 3.4s total). Allocation **counts** from
  such a run are valid; **timings** from it are meaningless.
- Requires `sudo`, and SIP must permit it. If `csrutil status` reports
  `DTrace Restrictions: enabled`, the recipe will not run.

FlameGraph is optional — aggregating `raw.stacks` by counting the first
application frame in each stack gives the same ranking.

[swift-allocations]: https://www.swift.org/documentation/server/guides/allocations.html


## What the metrics can and cannot tell you

Everything below was arrived at the expensive way — by getting a confident wrong
answer first. They are recorded as rules because each one cost a round of work.

### Allocation counts are not a proxy for time

Three fixes cut `swift_allocObject` by **70%** (10,950,087 → 3,222,863) and left
wall clock **flat**. One of the three had introduced its own hotspot: replacing
`input.lowercased()` with byte comparison removed the allocations it targeted but
gated the fast path on a scan of the entire input, landing at **14.7% of samples**
— more than twice the 7.4% → 2.0% it saved. Checking ASCII-ness inline instead,
one byte at a time, took it to 0.00%.

The mirror image happened in the same round: rewriting the hottest parse function
as a single byte-wise pass took it from 35.0% of samples to 3.10% while
allocations barely moved (3,222,863 → 3,204,736). What was being paid for was
*passes over bytes*, which no allocation count shows.

So: measure allocations to find *which* code allocates, never report an allocation
reduction as a speedup.

### Peak RSS cannot resolve a stage, and `phys_footprint` cannot see a transient

`/usr/bin/time -l`'s maximum resident set size, three runs of the *same unchanged
binary* on the 265 MB log:

    1769 MB    1918 MB    1750 MB

±10% run to run with no code change, which hides every change worth making — the
whole token array is 35 MB. It does not merely fail to resolve small changes, it
reports them backwards: removing a dead field measured RSS going **up 4%**.

`phys_footprint` (`TASK_VM_INFO`) is roughly **70× quieter** — 2.6 MB spread on
peak across five runs, against timings that varied 179–204 ms over the same runs.
`xclogparser-bench --warmup 0` prints it.

But it has a structural blind spot, and peak RSS is the only thing that sees
through it. Replacing GzipSwift's incremental inflate briefly held two buffers
alive: the harness reported peak **unchanged** at 900.7 MB while `/usr/bin/time -l`
showed **+234 MB**. The memory was freed before the stage ended, so a
stage-boundary footprint reading missed it entirely.

**The rule: any change to how the report is built or handed over must be measured
with `/usr/bin/time -l` on the real CLI, and a harness reading of "unchanged" is
not evidence.**

#### Two traps in `phys_footprint`, both of which produced a wrong answer first

**It never comes back down.** Released memory returns to the malloc zone, not to
the kernel, so each iteration reads a *cumulative* high-water mark. Across five
iterations the `read` stage reported:

    15.9 MB   -25.4 MB   583.1 MB   759.2 MB   1029.4 MB

A negative reading is the tell. Only the first pass over a fresh heap measures one
iteration; for another sample, repeat the **process**, not the loop. This is why
`--warmup 0` is required for memory, and why the benchmark refuses to print
footprints when a warmup ran rather than printing numbers that look fine.

**The median of three hid it completely.** `-n 3` gave per-stage medians agreeing
to ±1 MB across runs, which looked like a working metric. They agreed because the
median of three always returns iteration 2 — consistently the same wrong number,
and it would have silently changed meaning at `-n 4`. An aggregate that looks
stable is not evidence the samples are.

### A commit's effect is a property of what you ran, not of the commit

The commit that streams the JSON report, measured on both encode paths against the
commit before it:

| path | baseline log | fleet log |
| --- | --- | --- |
| streaming | 1118.0 → 941.4 MB (**−177 MB**) | 1102.8 → 890.5 MB (**−212 MB**) |
| buffered | 1118.3 → 1118.2 MB (−0.1 MB) | 1103.0 → 1102.7 MB (−0.3 MB) |

Measuring only the buffered path returns "this commit changes nothing" — honestly,
reproducibly, and wrongly. The stage it improves did not run.

This is why the report prints `not run` rather than `0.0 ms` for a path it did not
take. An earlier version printed the zero, and the streaming commit read as an
exact zero for time, allocations and memory simultaneously — three metrics agreeing
on a wrong answer, which is far more convincing than one.

It is also why measuring both paths takes two processes rather than one: since
`phys_footprint` never returns pages, whichever encode runs second inherits a heap
the first one grew, so only the first is falsifiable.

### Duplicate values in the output are not duplicated memory

Counting repeated values in the parsed JSON is an easy way to find apparent waste.
It was wrong every single time it was tried:

| claim, from output counting | actual, measured |
| --- | --- |
| `Scanner.string` holds a 265 MB copy of the log | **0.0 MB** |
| 124,179 `classNameRef` tokens copy ~160 distinct names | **≤8.4 MB** |
| `buildIdentifier`/`machineName`: 42,148 uses of 1 value | **≤9 MB** |

Swift `String` is copy-on-write, so passing one around is a retain, not a copy of
its bytes. Rather than building a deduplicating interner and hoping, defeat COW at
the call site and see whether memory moves:

```swift
// forces a genuine independent copy
String(decoding: Array(value.utf8), as: UTF8.self)
```

If forcing real copies does not make things measurably worse, the values were
already shared and deduplicating them cannot help. That check closed all three rows
above in minutes rather than the days an interner would have taken.

### Pure code movement is not free, and diffing the source will not tell you

Collapsing three copies of a byte-range-to-`String` conversion into one method on
`UnsafeBufferPointer<UInt8>` cost **+14,225 allocations** on the baseline log and
**+35,303** on the fleet log, in the buildstep stage, while every other stage
stayed identical to the event.

The verification that missed it was a source diff: stripping comments and blank
lines showed the code was byte-identical apart from an added `import`. That check
was sound and irrelevant — it confirmed the property that had been preserved and
said nothing about the one that broke. Tests were equally quiet, since behaviour
never changed.

Three hypotheses were tried and all three were wrong: `@inline(__always)`,
`@inlinable`, and moving the method into the same file as its caller each left the
count exactly where it was. What restores it is making the helper a `static` on a
concrete type in the module again. A method on a generic standard-library type does
not optimise the same way for a call made once per section.

**For a refactor whose whole claim is "nothing changed", deterministic counters are
the check, and the source diff is not.**

### A differential test found a bug the benchmark logs could not

Two rewrites here changed `String` comparison semantics:
`String.contains`/`starts(with:)` compare grapheme clusters, so a combining mark
fused to the end of a match makes Foundation report no match where bytes say
otherwise.

Differential testing against the original implementation — tens of thousands of
generated inputs, including all 112 combining marks in U+0300–U+036F — is what kept
those rewrites honest. It caught two real bugs that the project's own unit test,
which asserts only a dictionary's `count`, would have passed. The same technique
over generated SLF documents found a crash on malformed input that no real log in
the corpus reproduced.
