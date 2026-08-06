# Benchmark log profiles

A profile describes an `.xcactivitylog` to generate. `xclogparser-loggen` reads one and writes a
gzipped log the parser accepts:

    swift run -c release xclogparser-loggen \
      --profile Benchmarks/Profiles/baseline.yaml \
      --output Benchmarks/Logs/baseline.xcactivitylog

The profiles are checked in. The logs they produce are not: they are derived artifacts, they are
large, and anyone can regenerate them. A profile plus its seed always produces the same log, so a
benchmark comparison against a run from months ago is comparing the same input.

"The same log" means the same *uncompressed* bytes. Those are reproducible across platforms: the
generator's PRNG is SplitMix64 seeded from the profile, with no dictionary or set iteration anywhere in
the emit path, so nothing platform-dependent reaches the output. Verified by generating `baseline.yaml`
on macOS and on Linux — the inflated payload hashed identically on both
(`ad4fc6f5d0ba7873c8f823ac6f9c58c0d2eed0f373566a3a2b670be0bda01f76`, 308,666,320 bytes).

The gzip *container* is not reproducible across platforms, because the two hosts' zlib compresses the
same input differently: `8113de62...` on macOS against `167a1215...` on Linux for that same payload. So
compare the inflated hash, not the file's. A differing file hash on two machines does not mean the
benchmark ran on different data — check the payload before concluding anything from it.

`baseline.yaml` takes around 2.5 seconds and writes an 8.6 MB file that expands to 294 MB. Build the
generator in release mode as above; a debug build is several times slower.

## Why a generator

Real build logs cannot be committed. They carry absolute paths, target and project names, and the
source structure of whatever was being built. So the benchmark had nothing to run on, and the
numbers in `../README.md` came from logs nobody else could obtain.

## Why the fields are what they are

The point is not to produce a log of the right *size*. Size alone is easy and measures the wrong
thing. Each field exists because a specific measurement depends on it, and a log with the right byte
count but the wrong shape produces numbers that look plausible and mean nothing.

| field | why |
|---|---|
| `sectionCount` | Drives token count and the parser's array growth. `_ArrayBuffer._consumeAndCreateNew` was 41.7% of allocations. |
| `diagnosticDensity` | The largest single win came from not splitting the text of sections holding no diagnostic. At 1.0 that work is invisible; at 0.0 the notice parser never runs. Real logs: 6.8%. |
| `sectionTextBytes` | The total is what `parseAsString` and the token strings work over — 265 MB in the real baseline log, against a 14 MB file. |
| `noticesPerSection` | Long-tailed on purpose. Most sections have a couple, a few carry hundreds, and the deep ones are what made notice parsing expensive. Buckets are explicit so a profile states its tail instead of implying one. |
| `detailVariety` | 78% of notice details were copy-on-write references to a shared buffer; 1,858 MB of logical `detail` deduped to 6.7 MB. Low variety reproduces that. |
| `colonByteFrequency` | Both diagnostic markers start with `":"` and the notice fast path is gated on how often that byte appears. Real logs: 0.78%. |
| `clangSectionShare` | C/ObjC sections carry `[-Wflag]` markers, and finding those is a regex scan over the whole section text — `Notice.parseClangWarningFlags` was 5.12% of parse samples. A log made only of Swift compilations never runs that code, so work done there measures as free. |
| `targetCount` | `groupedByTarget()` reads the target out of each section's command and rebuilds the tree around it. One target collapses that to a single group. |
| `nestingDepth` | The parser walks sections recursively and carries parent state down; `getSwiftIndividualSteps` reads the *parent's* command when the child's does not name the file. A flat log never exercises it. |
| `errorShare` | Errors take a different path through `assignNoticesFrom` than warnings, and reach the build status differently. |
| `seed` | Reproducibility. Without it a regenerated log is a different input. |

All five shape fields are optional and default to the flat, Swift-only, single-target log the
generator originally produced, so a profile written before they existed still describes the same log.

## What the generator cannot do directly

`detailVariety` is not written into the file. A notice's `detail` is *derived* by the parser from the
section text, by looking up `path:line:column:` against the markers found there. The generator's only
lever is how often a location repeats, so the realised sharing is an outcome, not a setting — which
is why it is reported rather than assumed.

For the same reason `colonByteFrequency` has a ceiling. Diagnostic lines are colon-rich, so above a
certain `diagnosticDensity` they alone exceed any low target and the filler cannot bring it back
down. The generator prints requested against realised for exactly this: a generated log states what
it actually is.

## Profiles

- **`baseline.yaml`** — the 14 MB log the recorded measurements used. ~265 MB of section text,
  ~13k notices piled into relatively few deep sections, and some errors.
- **`fleet.yaml`** — the second recorded log. ~263 MB of section text but spread over *fewer*
  sections holding more text each, ~16k notices spread thinly rather than piled deep, and **no
  errors at all**.
- **`smoke.yaml`** — 200 sections, for checking the harness runs at all. Too small to measure:
  stage timings are dominated by process startup and the baseline comparison will flag ordinary
  noise as a regression.

### Why two large profiles rather than one scaled

The two recorded logs are not the same workload at different sizes, and the numbers say so: the
*smaller* one (167 MB) reached a *higher* peak in the real CLI than the larger one — 5859 MB against
3116 MB. Scaling a single profile up and down cannot produce that, because the difference is in
shape, not volume.

The sharpest difference is that `": error:"` does not occur once in 278 MB of the fleet log. That
absence is what made one finding measurable at all: `parseSwiftIssuesDetailsByLocation` searched for
`": error:"` and then `": warning:"`, so on that log the first search ran to the end of every line
and always failed — 31.4% of samples, taken to 17.8% by scanning once. Benchmarked against a log
with errors in it, that work looks much cheaper than it is. Hence `errorShare: 0` in `fleet.yaml`,
and a test asserting the marker is absent from the bytes rather than merely unused.

## Fidelity

These profiles reproduce the distributional properties listed above. They do not reproduce a real
log: the file paths, target names and warning text come from small fixed corpora, so anything that
depends on the *variety* of strings rather than their shape will differ. The generated logs are
built for benchmarking the parsing pipeline, not for testing parser correctness against Xcode's
real output — the fixtures in `Tests/` cover that.
