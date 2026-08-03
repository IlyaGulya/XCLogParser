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

The tool times each pipeline stage separately — read, gunzip, UTF-8 decode,
`Lexer.tokenize`, `ActivityParser`, `ParserBuildSteps` — and reports
median/mean/min/max/stddev, each stage's share, peak RSS and throughput.
Timings use the monotonic clock (`DispatchTime.uptimeNanoseconds`).

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

### Load average is not sufficient — check for an EDR agent

A managed Mac can show a perfectly healthy load average and still be unusable
for timing. Check explicitly:

```bash
ps aux | grep -iE "jamf|crowdstrike|sentinel|falcon|defender" | grep -v grep
```

A corporate endpoint agent hooks process execution, so it taxes exactly the
work a parser benchmark does. Observed here at 27-35% CPU on an otherwise idle
host (load ~1.5), producing a 216ms stddev on a 9.5s total where a quiet run
gives 2.8ms — a 77x spread — and inflating peak RSS from 1167MB to 1731MB for
code that only *removes* allocations. Those numbers look like a regression and
are pure measurement artefact.

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

### Allocation counts — DTrace

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

## Worked example

Both committed optimizations came out of this loop:

1. Instrumentation counted 51,069,072 executions of a closure inside
   `Scanner.scanCharacters(from:)` for 14,971,475 calls — it rebuilt a
   `Set<UInt8>` from a `Set<Character>` on every call. Hoisting it into
   `Lexer.init` cut tokenize 4.65s → 0.79s.
2. Counts pointed at `Notice.parseSwiftIssuesDetailsByLocation` but fixing its
   quadratic string concat changed nothing measurable. Probes showed the real
   cost was splitting 185MB of text in sections that held no diagnostic at all;
   guarding on the marker cut the BuildStep stage 10.72s → 9.03s.

Step 2 is the point of this document: the plausible fix suggested by call counts
was not the fix that mattered, and only direct timing distinguished them.

A third instance of the same lesson, from the allocation pass: peak RSS is 5.4x
the input (1434MB for a 265MB log), and the obvious culprit looked like the
163MB of section text copied into `Token` strings. Allocation counts ranked that
at ~13%, well behind `_ArrayBuffer._consumeAndCreateNew` at 41.7% — plain array
growth in `Lexer.tokenize` and a throwaway array returned per token. The
cheapest fix was also the biggest, and the expensive API-breaking one ranked
fourth. Rank by measurement, not by how obviously wrong the code looks.

Two measurements that read as promising and were not, recorded so they are not
retried:

- `parseAsString` calls `trimmingCharacters` on every string, including 265MB of
  section text. It costs **0.08s** across all 677k strings. Not a target.
- A hand-written byte-level trim meant to avoid allocating was **20-38x slower**
  (1.7s and 3.0s vs 0.08s), because `Substring.count` on UTF-8 walks the whole
  string. Foundation already wins here.

## Allocation counts are not a proxy for time

Three fixes cut `swift_allocObject` by **70%** (10,950,087 → 3,222,863) and left
wall clock **flat**. Tokenize did improve (0.749s → 0.547s), but the BuildStep
stage regressed enough to cancel it.

The time profile explained why, and the explanation was uncomfortable: one of the
three fixes had introduced its own hotspot. Replacing `input.lowercased()` with
byte comparison removed the allocations it was meant to remove, but gated the
fast path on a scan of the entire input, which landed at **14.7% of samples** —
more than twice the 7.4% → 2.0% it saved at the call site it targeted. Checking
ASCII-ness inline instead, one byte at a time, took it to 0.00%.

So: measure allocations to find *which* code allocates, but never report an
allocation reduction as a speedup. They are different quantities, and here they
moved in opposite directions.

The same round rewrote the hottest function in the parse
(`parseSwiftIssuesDetailsByLocation`, 35.0% of samples) as a single byte-wise
pass, taking it to 3.10% while allocations barely moved (3,222,863 → 3,204,736) —
the mirror image of the same point. What was being paid for was *passes over
bytes*, which no allocation count shows.

Both of those changes altered `String` comparison semantics, which is worth
knowing before repeating the trick: `String.contains`/`starts(with:)` compare
grapheme clusters, so a combining mark fused to the end of a match makes
Foundation report no match where bytes say otherwise. Differential testing
against the original implementation (tens of thousands of generated inputs,
including all 112 combining marks in U+0300–U+036F) is what kept those rewrites
honest — and it caught two real bugs that the project's own unit test, which
asserts only a dictionary's `count`, would have passed.

## Measuring memory: peak RSS cannot do it

`/usr/bin/time -l`'s "maximum resident set size" is unusable for this project.
Three runs of the *same unchanged binary* on the 265 MB log:

    1769 MB    1918 MB    1750 MB

That is ±10% (~170 MB) run to run with no code change, which hides every change
worth making — the whole token array is 35 MB.

It does not merely fail to resolve small changes, it reports them backwards.
Removing a dead field that held the entire log measured RSS going **up 4%**
(1746 → 1820 MB). Both figures were noise.

`phys_footprint` (`TASK_VM_INFO`) is roughly **70× quieter**. Five runs of
unchanged code, per stage, over a pre-read baseline:

| stage | spread over 5 runs |
|---|---|
| Gunzip | 0.1 MB |
| UTF-8 decode | 0.0 MB |
| Tokenize | 0.1 MB |
| Parse IDEActivityLog | 0.1 MB |
| peak | 2.6 MB (0.18%) |

Timing over those same runs varied 179–204 ms, so this is a genuinely quieter
metric and not a quiet machine. `xclogparser-bench --warmup 0` prints it.

### Two traps, both of which produced a wrong answer first

**`phys_footprint` never comes back down.** Released memory goes back to the
malloc zone, not to the kernel, so each iteration reads a *cumulative* high-water
mark rather than its own cost. Across five iterations the `read` stage reported:

    15.9 MB   -25.4 MB   583.1 MB   759.2 MB   1029.4 MB

A negative reading is the tell. Only the first pass over a fresh heap measures
one iteration; for another sample, repeat the **process**, not the loop. This is
why `--warmup 0` is required for memory, and why the benchmark refuses to print
footprints at all when a warmup ran rather than printing numbers that look fine.

**The median of three hid it completely.** Running `-n 3` gave per-stage medians
that agreed to ±1 MB across runs and looked like a working metric. They agreed
because the median of three always returns iteration 2 — the metric was stable
only in the sense of being consistently the same wrong number, and it would have
silently changed meaning with `-n 4`. An aggregate that looks stable is not
evidence the underlying samples are; look at the raw per-iteration values.

### What it immediately showed

With a metric that resolves 35 MB, the per-stage table says where the memory is
(265 MB log, 15.9 MB compressed):

    Read file                 0.2 MB      +0.2 MB
    Gunzip                  270.4 MB    +270.2 MB
    UTF-8 decode            567.7 MB    +297.3 MB
    Tokenize (Lexer)       1164.6 MB    +596.9 MB
    Parse IDEActivityLog   1399.7 MB    +235.1 MB
    Parse BuildStep tree   1429.1 MB     +29.3 MB

Peak is **5.4× the uncompressed input**, and the decode step alone costs ~1.1× the
log to turn `Data` the process already holds into a `String`.

It also settled a question the old metric got wrong: removing the dead
`Scanner.string` field changes memory by **0.0 MB** (tokenize 1164.5–1164.6 MB,
unchanged). Swift `String` is copy-on-write, so that field was a retain of a
string the caller already holds alive — dead code worth deleting, but never the
265 MB it looked like. Report memory in absolute units for the same reason time
shares are misleading: a change to the total moves every other stage's share.

## Duplicate values in the output are not duplicated memory

Counting repeated values in the parsed JSON is an easy way to find apparent waste,
and it was wrong every single time it was tried here:

| claim, from output counting | actual, measured |
|---|---|
| `Scanner.string` holds a 265 MB copy of the log | **0.0 MB** |
| 124,179 `classNameRef` tokens copy ~160 distinct names | **≤8.4 MB** |
| `buildIdentifier`/`machineName`: 42,148 uses of 1 value | **≤9 MB** |

Swift `String` is copy-on-write, so passing one around is a retain, not a copy of
its bytes. Handing the same stored property to 42,148 structs allocates one string,
not 42,148 — and 21–45 byte class names are past the small-string limit, so this is
real COW sharing rather than an artifact of short strings.

### The two-line check that settles it

Rather than building a deduplicating interner and hoping, defeat COW at the call
site and see whether memory moves:

```swift
// forces a genuine independent copy
String(decoding: Array(value.utf8), as: UTF8.self)
```

Then `xclogparser-bench <log> -n 1 --warmup 0`. If forcing real copies does not make
things measurably worse, the values were already shared and deduplicating them
cannot make things better. That experiment is how all three rows above were closed,
and it costs minutes rather than the days an interner would.

The corollary is that a ratio like "776 references per declaration" is evidence about
the *log format*, not about memory. Get a number from the metric before believing it.

### The opposite trap: a cost that is real but not removable

A ceiling probe can also come back *positive* and still not justify the work. The
lexer's per-token `String`s were measured, by replacing every scanned payload with a
shared constant, at **295 MB and half the tokenize time** — a real cost, unlike the
three rows above. The conclusion "so make `Token` carry a byte range instead" was
still wrong.

Those strings are not a duplicate of the input; they *are* the parsed model's
storage. `IDEActivityLogSection` stores plain `String` fields assigned straight from
`ActivityParser.parseAsString`, whose only transform is `trimmingCharacters` — and
that returns the same buffer when there is nothing to trim. On the flagged log only
44,215 of 394,106 string tokens (11.2%) would be trimmed, so ~89% of the 258 MB is
shared with the model, not copied.

The forced-copy check confirms it from the other direction: giving every string token
private storage moved the footprint 649.3 → 684.7 MB, **+35 MB**, not +258 MB. Had the
strings been a redundant copy, forcing real ones would have cost the full 258 MB.

So a range-based `Token` would remove 258 MB from the lexer and oblige the parser to
build ~230 MB of it straight back, because the model needs real `String`s. That is
moving an allocation, not deleting one.

**Ask who else holds the value before removing an allocation.** A cost that is real,
and even dominant in its own stage, is only worth removing if nothing downstream needs
it materialised anyway.

### Two probes that produced confident wrong answers

Both of these ran here and had to be thrown out:

- **"Free it and watch memory fall."** Dropping all 1.45M tokens reported 0.0 MB
  reclaimed, which reads as proof the model owns everything independently. A control
  that allocated *and freed a known-dead 300 MB blob* reported 0.0 MB too —
  `phys_footprint` never decreases. Sharing must be measured as growth in a fresh
  process, never as shrinkage in a live one. Always run the control.
- **Neutering payloads through the whole pipeline.** `ActivityParser` validates string
  contents and dies with `Unexpected attachment identifier`, so a constant or
  truncated payload cannot reach a peak measurement. Ceiling probes on token contents
  are only usable against the lexer alone.

## Foundation is not always the fast option

The two fixes above replaced Foundation calls that the profile had ranked first
and second among what remained:

| what | before | after |
| --- | --- | --- |
| `NSDateFormatter` in `toDate` | 7.30% | 0.00% |
| `range(of:)` across its call sites | 11.46% | 0.00% |

Both replacements cost far less than what they removed — `ISO8601DateString` is
6.02% against the formatter's 7.30%, and `isDeprecatedWarning` fell to 1.57%
(with the byte search itself at 0.59%) — but note the first one is *not* a 7.30%
saving. Read those numbers together, not just the "before" column.

Two transferable points:

- **The date formatter's cost was steady-state, not setup.** It was already a
  `lazy var`, so caching or reusing the instance had nothing left to win; the
  7.30% was ICU field formatting plus Objective-C bridging on every call. What
  made it removable was that nothing varied — literal format, `en_US_POSIX`, UTC
  — so the whole result is integer arithmetic.
- **Several needles against one haystack is the shape to look for.**
  `isDeprecatedWarning` ran four `contains` calls in sequence over the same
  string, so a non-matching text paid four full scans. All four phrases share the
  substring `deprecated`, so one scan for it now rules out all four, and the
  four-scan path is reached only for text that actually mentions deprecation.

### Reproducing a formatter exactly is harder than it looks

`SSSSSS` does not mean microseconds. `DateFormatter` computes *milliseconds*,
rounds them, and zero-pads to the requested width, so `0.1234564` formats as
`.123000`. Truncating to six digits — the obvious reading — disagrees on nearly
every fractional input.

Worse, at an exact half-millisecond tie ICU's choice could not be reproduced at
all. These were each falsified by measurement: rounding the binary double
half-up or half-even, snapping the fraction to a fixed decimal precision (4
through 7), and rounding the shortest round-trip decimal representation. The
decisive pair is `676.49996…` rounding *down* while `613.49999…` rounds *up*,
with the result stable across the whole-seconds magnitude, which rules out
precision loss in the subtraction.

That divergence is shipped deliberately, and it is small but not zero: 24 of
223,938 real section dates (0.011%), always by exactly 1ms. Xcode writes
timestamps with 4 decimal places, so such ties are common rather than
theoretical — reasoning that they would be rare was wrong, and only the
whole-log diff showed it.

### Diff whole-log output, and ignore key order

The check that gave confidence here was parsing two real logs with the old and
new binaries and comparing the reporter JSON. Compare it **parsed**, not as
bytes: dictionary serialization order varies between runs, so `cmp` reports a
difference at the first step in every file and tells you nothing. Comparing
decoded structures instead showed the only differences in two full logs were
those 24 date fields — every target name, step type, warning, error and linker
statistic byte-identical, which is what established the `range(of:)` rewrites as
behaviour-preserving.

That diff also surfaced a latent crash unrelated to performance:
`getTargetFromCommand` searched for `in target '` and `' from project '`
independently and subscripted the string with the resulting range, which traps
when the markers appear in reverse order. It now returns `nil`, and there is a
regression test.

But note what a whole-log diff cannot tell you. Replacing the clang-flag regex
(`\[(-W[\w-,]*)\]+`) produced identical output on both logs — and neither log
contains a single `[-W`, so the comparison only ever exercised the no-match path.
It was worth running, because that path is the hot one, but the extraction
behaviour was established by a differential test against the original regex, not
by the logs. **Check that your fixture actually contains the input you think you
are testing** before reading "identical" as "correct".

### A fallback that almost always triggers is not a fallback

The first version of that scanner deferred to the regex whenever it saw a
non-ASCII byte *anywhere* in the section text, on the reasoning that real
diagnostics are ASCII. They are — 99.974% of bytes in a 278MB fleet log. But the
remaining 0.026% were spread widely enough that nearly every section contained
one, so nearly every section still went through ICU: re-profiling showed the
regex still at 22.8% of samples, barely moved.

The fix was narrowing the bail-out to where a non-ASCII byte can actually change
the answer — inside a candidate flag body, since `\w` is Unicode-aware — rather
than anywhere in the string. ICU then dropped to 0.10% and throughput went from
119 to 149 MB/s.

The general lesson: when a fast path has an escape hatch, measure how often the
hatch is taken. "Rare in principle" and "rare per section of a 278MB log" are
very different claims, and only the profile distinguishes them. Had I trusted the
first version's passing tests and identical output, I would have shipped a
rewrite that bought almost nothing.

### Two searches over the same bytes is one too many

`parseSwiftIssuesDetailsByLocation` looked for `": error:"` and then, failing
that, `": warning:"` — the direct translation of
`range(of:) ?? range(of:)`. Each search walked the whole line comparing its
marker's first byte at every offset, so every line was scanned twice. On a real
fleet log that is close to worst case: `": error:"` does not occur *once* in
278MB, so the first search always ran to the end and always failed.

Both markers start with `":"`, and only 0.78% of that log's bytes are `":"`. One
pass anchored on that byte, trying both markers only at those positions, took
`parseSwiftIssues` from **31.4% to 17.8%** of samples. The `??` precedence needs
care to preserve — it is by *marker*, not position, so a later `": error:"` must
still beat an earlier `": warning:"`, which means finishing the line rather than
returning the first hit.

Worth checking the frequency of what you search for. A pattern that never matches
costs full price on every call.

### Do not build a String you are about to parse as a number

The lexer's hottest path scanned a run of digits, built a `String` from those bytes,
and handed it to `UInt64(_:radix:)`. Every SLF value has such a payload — a length,
a class-name index, a hex-encoded double — so this ran tens of millions of times
per log, and each one was a heap allocation plus a UTF-8 validation pass, to
produce a string that was immediately walked again by the integer parser.

`scanCharacters` now returns the byte `Range` it consumed, and the payload is
accumulated straight from the bytes. Two smaller changes came with it: `Set<UInt8>`
membership became a 256-bit bitmap held inline in the struct (`Set.contains` hashes
and probes a heap buffer; a byte has only 256 possible values, so four `UInt64`
words in registers answer the same question), and `String(bytes:encoding:)` became
`String(decoding:)`, which does not copy.

Lexer cost fell **67%** in absolute samples, and total work for the whole parse fell
**38%** — throughput went from ~150 to ~245 MB/s.

Note the reporting trap in that last pair of numbers. As percentage-of-samples the
lexer went 39.3% → 20.8%, while *every other subsystem's percentage went up* —
`parseSwiftIssues` from 17.8% to 24.9%. None of them got slower; the denominator
shrank. Their absolute sample counts all fell 13–28%, because not allocating a
string per token takes malloc traffic out of the whole program. When total work
changes, compare absolute counts, not shares.

### A differential test found a bug the benchmark logs could not

The sweep for the above (20,000 generated inputs against the original Foundation
implementation) failed 3,678 times, and every failing input contained a NUL byte.
The cause was pre-existing and unrelated to the marker search: the function
reached its bytes via `withCString` and derived the length by scanning to the
first NUL, so section text containing one was silently truncated and every
diagnostic after it dropped. Both benchmark logs contain exactly zero NUL bytes,
so no amount of whole-log diffing would ever have surfaced it — but Xcode logs
*can* contain them, which is why this repo has tests named for preserving them.

Fixed by using `withContiguousStorageIfAvailable` (with a `makeContiguousUTF8`
retry for lazily-bridged strings). Two complementary checks, then: whole-log
diffs prove you did not break the data you have, and differential tests against
the old implementation probe the inputs you do not.

## Attribute a hot symbol by caller before believing your theory about it

A profile names the function that allocated, which is often not the function
worth changing. Twice in a row here, a plausible story about a symbol was wrong,
and the check that settled it was cheap.

`_ArrayBuffer._consumeAndCreateNew` sat at 12.4% of allocations — array growth.
The obvious suspects were the six `ActivityParser` list parsers, which append in a
loop and knew their element count up front. Adding `reserveCapacity` to all six
removed **9,327** allocations, about 4% of the symbol's total.

Grouping the same stacks by *caller* instead of by innermost frame located it:

```
49%  Lexer.scanTypeDelimiter          112,848
38%  CaseFolding.asciiBytes            86,334   (under NoticeType.fromTitle)
```

The second one is the kind of thing no symbol-level reading finds.
`NoticeType.fromTitle` matched with `case Prefix("Lexical"):`, and a struct
written in a `case` pattern is **constructed on every call** — each initializer
lowercased its pattern and built a `[UInt8]` of it. Roughly 86,000 byte arrays
per run, all comparing against string literals that never changed. Hoisting them
to `static let` was three lines and removed 38% of all array growth.

The aggregation is a small change to the allocation recipe: instead of keying on
the innermost project frame, keep the stacks whose innermost frame matches the
symbol you are chasing, then key on the *next* few frames up.

```bash
# from raw.stacks produced by the allocation recipe above
python3 - <<'PY'
import re, collections
agg = collections.Counter(); cur = []; total = 0
for line in open("raw.stacks", errors="replace"):
    s = line.strip()
    if re.fullmatch(r"\d+", s) and cur:
        n = int(s)
        frames = [f.split("`", 1)[1].split("+0x")[0]
                  for f in cur if f.startswith("xclogparser-bench`")]
        if frames and "TARGET_SYMBOL" in frames[0]:
            total += n
            agg[" <- ".join(frames[1:4])] += n
        cur = []
    elif "`" in s:
        cur.append(s)
for path, count in agg.most_common(10):
    print(f"{count * 100 / total:6.2f}%  {count:>9}  {path}")
PY
```

The same grouping is what turned "`StandardOutput.write` is 16.4%, and writing
is irreducible" into an actionable finding: 68% of it was the `write` syscall,
but 25% was `validateUTF8`, because the function rebuilt a 171 MB `String` from
the report `Data` before printing it. Removing that copy took 159 MB off peak
RSS. A frame that looks like unavoidable I/O can still have a third of it be
something you added.

## Probe a projected win before implementing it

Cheaper than implementing and measuring, and it has already prevented one
pointless change. A review proposed extending `trimmedIfNeeded` with a
hand-rolled byte-level ASCII trim so the Foundation fallback would not be needed,
estimating up to ~4% of runtime.

Two counters and one stack breakdown, about two minutes of work:

- The fallback fires **11.6%** of the time (45,835 slow against 348,271 fast).
- Of the samples inside `trimmedIfNeeded`, only ~9% are in Foundation's trim.
  **54% is `_platform_memmove` plus `_allASCII`** — building the returned String,
  which both paths pay.

So the real target was ~9% of a 5.7% frame: under 0.5% of runtime, in exchange
for hand-written Unicode boundary handling. Declined.

The general shape: when a projection depends on how often a branch is taken, or
on which part of a frame the time is really in, count it first. An estimate that
cannot survive two counters was not going to survive an implementation.

### …and then the same change was worth 49x, on the other platform

The probe above was run on macOS, and its conclusion held there. On Linux the
identical change made `Parse IDEActivityLog` **18.33 s → 366.7 ms**, and the whole
run 23.12 s → 4.76 s.

Nothing about the probe was wrong. What was wrong was reading "under 0.5% of
runtime" as a property of the change rather than of the platform it was measured
on. `trimmingCharacters(in:)` is cheap where Foundation has a native `NSString`.
Where it does not, it routes through
`NSString.substring` → `String._slowFromCodeUnits` → `UTF16.ForwardParser.parseScalar`,
converting the string to UTF-16 one scalar at a time; `perf` put that chain at over
55% of the stage. The macOS probe could not have seen this, because the expensive
path does not exist there.

Two counts made the fix bigger than the original proposal, and both came from
counting rather than reasoning:

| | count | share of string tokens |
|---|---|---|
| already trimmed (fast path) | 383,097 | 62.2% |
| **empty** | 182,241 | **29.6%** |
| needed an ASCII trim | 50,514 | 8.2% |
| non-ASCII at an edge | 0 | 0.000% |

The empty strings were the surprise: 3.6x more than the strings that needed any
trimming at all, and every one of them went to Foundation to have whitespace
removed from a string with no characters in it. `bytes.first` returns nil, the
guard returned nil, and the fast path was skipped for the case with nothing to do.

Measured, 3 interleaved rounds each, `-n 1 --warmup 0`:

|  | Linux | macOS |
|---|---|---|
| Parse IDEActivityLog | 18.33 s → **366.7 ms** | 124.1 ms → **92.3 ms** |
| stage share of run | 82% → 6.9% | 8.9% → 6.9% |
| TOTAL | 23.12 s → 4.76 s | 1.394 s → 1.346 s (noise) |
| stage allocations | 3,335,143 → 1,301,746 | 420,745 → **187,990** |
| stage footprint | +270.6 → +270.4 MB | +306.5 MB, unchanged |

macOS TOTAL stays inside run-to-run noise — the stage is under 9% of that run —
but the stage itself is reliably faster and allocates 232,755 fewer objects. So
the macOS probe's "not worth it" was an understatement even on macOS, because it
counted only the trim and not the empty-string detour.

The lesson that replaces the earlier one: a measurement is scoped to the platform
it ran on. "Foundation wins here" was true, and "here" was doing more work in that
sentence than it looked.

Correctness is the part worth stating plainly. The first implementation was
**wrong**: after removing an ASCII whitespace run, the new boundary can be a
*non-ASCII* member of `.whitespacesAndNewlines` — `U+00A0` and the `U+2000` block
are whitespace too — and trimming has to continue through it. On
`"\r\n  \u{00A0}nbsp inside  \t"` it returned `" nbsp inside"` where Foundation
returns `"nbsp inside"`. A test written at the same time as the change caught it.
The fix re-checks the post-trim boundary and hands the whole string back to
Foundation when it is >= 0x80, so the fast path only fires when the answer is
provable from the bytes.

One caveat on the 29.6%: that is a property of this generator profile, not of a
real Xcode log — no real log was available to check it against. The direction of
the fix does not depend on the ratio; the size of the win does.

## The comment can describe an intent the code does not implement

`parseSwiftIssues` collected a diagnostic's continuation lines as byte ranges and
joined them with `detail += "\n" + string(from: bytes, range: continuation)`,
under a comment saying the lines were "joined once, so the accumulated detail is
never re-copied". But `+=` in a loop is a repeated copy, and each iteration
allocates three Strings: the piece, the concatenation, and the grown result.

heaptrack ranked those two lines second and third among all allocators on the
baseline log — 243,094 and 219,347 calls, both with **0 B peak consumption**, the
signature of a pure temporary. Copying into one buffer sized up front, and
converting once, costs one String per detail instead of n:

| | before | after |
|---|---|---|
| stage allocations | 2,097,017 | **1,602,911** (−494,106, −23.6%) |
| run allocations | 2,718,739 | 2,224,633 (−18.2%) |
| stage footprint | −2.6 MB | **−11.1 MB** |

The time gain is real but not cleanly separable, and saying so is the honest
report: over eight interleaved pairs the stage ran 1.788–1.937 s before (median
1.827) and 1.660–1.901 s after (median 1.745). After wins seven pairs of eight,
the ranges overlap, and one pair reverses. TOTAL is unchanged within noise. The
allocation count is deterministic — it reproduced to within 4 across eight runs —
so that is the figure worth quoting, and the timing is not.

## Roughly 3% of this binary's profile is the harness, not the parser

`PathCoverage.detect` re-walks the section tree to report which conditional parser
paths a log never exercised, and it does that with uncached `NSRegularExpression`s
— about 3% of samples in a whole-process `perf` profile.

It is deliberately outside every `runStage`, so no stage timing includes it and
the reported figures are unaffected. But a flat profile of `xclogparser-bench`
does include it, and `isWholeModuleCompile` sitting near the top of a regex
breakdown looks like a parser problem when it is not. Discount it from the
denominator before concluding anything about regex cost in the library.

## Two data-oriented ideas that measured as nothing

Both came from a probe over the parsed tree, both looked well-founded, both were
implemented, measured, and reverted. The measurements are the useful part.

### An allocation attributed to a line is not one a guard can skip

heaptrack put 40,335 allocations on `IDEActivityLogSection+Parsing.swift:119`, a
`range(of:options:.regularExpression)` that recompiles its pattern on every call.
The pattern is anchored — `^CompileSwift\s\w+\s\w+\s.+\.swift\s` — so a byte prefix
test should reject most inputs before the regex engine is entered at all. (The
anchor really is start-of-string, not start-of-line: verified against the engine,
including after `\n` and `\r`.)

Measured over four interleaved pairs: stage allocations 2,097,025 → 2,097,018, a
saving of **seven**. Stage time was *slower* in three of four pairs.

The line sits inside `getSwiftIndividualSteps`, which is only called for
`.swiftCompilation` steps — whose `commandDetailDesc` does start with
`CompileSwift`. So the prefix check passes and the regex runs exactly as before.
The 40,335 allocations were the regex *matching*, not its compilation, and no guard
in front of that line can avoid them. Reverted.

`ClangCompilerParser` has three genuinely uncached patterns, one of them compiled
six times per linker section. They are all gated behind `hasPrintStatisticsLinkerFlag`,
which no available log sets, so caching them would be an unverifiable claim and was
left alone.

### A microbenchmark's memory figure does not transfer to a 270 MB working set

The probe found something real: 53,742 sections hold exactly **one** distinct
`domainType` value, in **53,742 distinct buffers** — confirmed by comparing buffer
addresses rather than assumed. Each value is 32–39 UTF-8 bytes, past the 15-byte
limit for inline storage, so every one is a heap allocation.

The reason there is no copy-on-write sharing is worth keeping: CoW shares when an
existing `String` is copied, and the lexer does not copy one. It builds each string
out of the raw log bytes with `String(decoding:as:)`, which allocates. A standalone
53,742-iteration reproduction of that showed peak memory falling 11.2 MB → 6.9 MB
when the values were interned.

That 4.3 MB does not exist in the real parser. Interning `domainType` in
`ActivityParser` measured:

- stage allocations 187,990 → 187,991 (**+1**)
- stage retains 1,301,746 → **1,355,491** (+53,745 — one per section, for the lookup)
- stage footprint +270.4 MB → +270.4 MB, **unchanged**; PEAK unchanged
- stage time slower in three of four pairs

The probe held 53,742 strings in an array with nothing else alive, so those buffers
dominated its footprint. In the parser they are noise against a 270 MB stage, and
neither `phys_footprint` nor `RssAnon` resolves them. Reverted.

Interning could never have removed the allocation anyway: it happens in the lexer,
before the parser sees the token, so interning only drops a retention afterwards.
Removing it means not materialising token strings at all — a change to the public
`Token` enum, and a different piece of work.
