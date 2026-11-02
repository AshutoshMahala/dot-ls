# Performance baseline

## Latest-parser trial: `38442d2` (2026-11-01)

The performance target is the complete dot-ls server. This trial compares the
current `01b0a8e` dependency with pushed upstream `38442d2` in isolated copies of
the same server. The project pin and installed development binaries stay on
`01b0a8e`. Both dependencies have zero local patches. The new optional event-based
graph builder is not enabled; dot-ls still uses compact feature indexes.

Both builds use Zig 0.17.0 `safe`, page allocation, buffered JSON, the block
scanner, metering, cancellation and 4,096 credits. Measurements cover full-sync
LSP intake through client receipt of diagnostics, completion readiness and hover.
Server RSS includes all analysis phases and excludes Zed and the harness. No
builds, tests or editor automation ran alongside measurements. There are three
alternating fresh-process trials per build/layout at 5 and 20 MB. Timing varied
at 40 MB, so a further three trials ran there. The table includes all six 40 MB
trials. Each process checks clean open, a broken edit and repair.

| Size | Layout | Open diagnostics before → candidate | Broken edit before → candidate | Repair before → candidate |
| --- | --- | ---: | ---: | ---: |
| 5 MB | plain | 44.1 → 48.1 ms | 49.8 → 47.2 ms | 45.1 → 45.4 ms |
| 5 MB | HTML-heavy | 42.4 → 37.6 ms | 42.4 → 47.1 ms | 44.8 → 37.6 ms |
| 20 MB | plain | 125.1 → 125.4 ms | 135.2 → 134.5 ms | 127.9 → 123.6 ms |
| 20 MB | HTML-heavy | 117.5 → 113.3 ms | 128.2 → 129.8 ms | 113.3 → 114.4 ms |
| 40 MB | plain | 217.8 → 209.9 ms | 238.9 → 229.7 ms | 214.1 → 212.0 ms |
| 40 MB | HTML-heavy | 193.9 → 189.5 ms | 216.9 → 222.6 ms | 189.7 → 195.2 ms |

The results show a modest plain-DOT gain at 40 MB, not a broad server speedup.
HTML-heavy edits are mixed, and the 40 MB process CPU medians for the full
open/edit/repair sequence are 1,140.6 → 1,142.7 ms. Plain-DOT CPU medians for that
sequence are 1,239.8 → 1,214.0 ms. Completion readiness at 40 MB is
361.5 → 350.0 ms plain and 348.3 → 342.2 ms HTML-heavy. These are small differences
beside the observed timing spread. No consistent startup improvement is shown.

Settled server RSS is unchanged apart from a 16 KiB increase in the 5 MB plain
median. At 40 MB it remains 40.993 MB plain and 38.879 MB HTML-heavy; peak RSS
stays near 125 MB. The new graph-building route is outside the current server
path. The scanner specialization targets scalar consumers; dot-ls uses block.
The new bare-name hash path can reach duplicate-attribute checks, while references
already use direct hashing for bare names. No parser-only benchmark result is
used to claim a dot-ls gain. This trial does not justify an update for speed alone.

The candidate passes 69 server and 213 vendored parser tests in `safe`, plus all
eleven protocol suites. All 26 captured replies/findings match the baseline after
excluding only the expected server version. Clean/broken/repaired findings and
HTML publication phases agree in every measured run. Production source, vendor
bytes, installed binaries and editor settings are unchanged by the experiment.

- [Combined server results](../bench/results/parser-38442d2/combined-summary.json)
- [Initial trials](../bench/results/parser-38442d2/comparison.json)
- [40 MB follow-up](../bench/results/parser-38442d2/repeat-40/comparison.json)
- [Protocol checks](../bench/results/parser-38442d2/checks.json)
- [Build identities and scope](../bench/results/parser-38442d2/experiment.json)

## Patch-free parser update to `01b0a8e` (2026-11-01)

The source dependency moves from `c936fd1` with its outline hook to unmodified
upstream `01b0a8e`. There are no local parser patches. The outline uses public
statement starts, statement heads, delimiter observations and committed statement
extents. A fixed-size tentative statement record preserves bare nodes at EOF.
Typed parser errors distinguish those nodes from incomplete edges, assignments
and lexical failures. No full AST, graph records or second source scan is added.
Temporary outline entries remain 24 bytes; published entries remain 48 bytes.

Both builds use Zig 0.17.0 `safe`, page allocation, buffered JSON and 4,096 parser
credits. Three alternating fresh-process trials cover open, broken edit and
repair for plain DOT and HTML-heavy files. No builds, tests or UI actions ran
alongside the measurements. RSS is server-only; it excludes Zed and the harness.
Sizes and memory below use decimal MB.

| Size | Layout | Open diagnostics before → after | Settled RSS before → after |
| --- | --- | ---: | ---: |
| 5 MB | plain | 38.5 → 47.2 ms | 7.487 → 7.487 MB |
| 5 MB | html | 38.7 → 44.8 ms | 7.340 → 7.340 MB |
| 20 MB | plain | 108.6 → 124.3 ms | 21.856 → 21.856 MB |
| 20 MB | html | 105.3 → 113.9 ms | 20.840 → 20.840 MB |
| 40 MB | plain | 187.3 → 220.1 ms | 40.976 → 40.976 MB |
| 40 MB | html | 178.0 → 197.7 ms | 38.863 → 38.863 MB |

Removing the patch has a measured time cost. Open diagnostics add 6.1–32.8 ms
in these medians, about 8–23%. This comparison includes both the parser update
and the outline adapter; it does not isolate their individual costs. Public
observations and statement extents require more parser work than the old private
hook. No causal profile of that extra work is claimed here.

| Size | Layout | Broken-edit diagnostics before → after | Repair diagnostics before → after |
| --- | --- | ---: | ---: |
| 5 MB | plain | 44.2 → 50.9 ms | 38.9 → 45.6 ms |
| 5 MB | html | 46.1 → 45.8 ms | 35.7 → 44.3 ms |
| 20 MB | plain | 120.2 → 135.9 ms | 108.3 → 124.8 ms |
| 20 MB | html | 117.7 → 127.8 ms | 105.8 → 115.2 ms |
| 40 MB | plain | 208.7 → 246.3 ms | 185.0 → 229.1 ms |
| 40 MB | html | 205.0 → 229.2 ms | 179.5 → 202.9 ms |

Settled RSS is unchanged at the reported precision. Peak RSS stays near 125 MB
for 40 MB input; the new medians are 125.174 MB plain and 125.354 MB HTML-heavy.
This peak includes message intake and temporary analysis storage. It is distinct
from memory retained after work settles. Idle RSS is 2.228 MB. Startup medians
vary from 4.8 to 8.5 ms for the candidate; these samples do not establish a
startup regression or improvement. Completion readiness, hover and full memory
samples are in the raw summary. These are controlled server measurements, not
editor responsiveness measurements.

Three further alternating trials insert 1,000 syntax errors into each 5 MB
layout. Broken-edit diagnostics are 44.4 → 49.7 ms plain and 44.6 → 45.2 ms
HTML-heavy. Both builds report 1,001 findings at the cap, including the explicit
incomplete-checking notice. HTML retains both publication phases. Settled RSS
matches the table above.

69 server and 211 vendored parser tests pass in both debug and safe builds.
Eleven focused upstream boundary-event tests and all eleven protocol suites
pass. Four focused suites also pass with the debug allocator. All 227 tested
prefixes preserve outline names, hierarchy and selection ranges against the old
binary. New tests cover nested recovery, truncated nodes and ports, invalid edge
and assignment starts, comments, strings and HTML with brace characters.
Completed node ranges now exclude trailing trivia and optional semicolons, as
the public extent contract requires. The 26 captured baseline replies/findings
match after excluding only the server version string.

The tested candidate is installed under both native development binary names.
A fresh Mac ARM64 archive also passes all eleven protocol suites after clean
extraction with no development toolchain on PATH. Its notices and manifest need
no patch file. Existing release archives and the packaged Zed cache are unchanged;
rebuild them from the current pin before publication. This update changes no
editor grammar or settings and adds no new Zed visual verification.

- [Timing and memory summary](../bench/results/parser-01b0a8e/summary.json)
- [Raw trials](../bench/results/parser-01b0a8e/comparison.json)
- [Protocol checks](../bench/results/parser-01b0a8e/checks.json)
- [Wire parity](../bench/results/parser-01b0a8e/wire-parity.json)
- [Broken-prefix outline comparisons](../bench/results/parser-01b0a8e/outline-prefixes.json)
- [Debug-allocator checks](../bench/results/parser-01b0a8e/debug-checks.json)
- [1,000-error comparison](../bench/results/parser-01b0a8e/errors-1000/summary.json)
- [Clean native package checks](../bench/results/parser-01b0a8e/package-checks.json)
- [Source and binary identities](../bench/results/parser-01b0a8e/implementation.json)

## Parser update to `c936fd1` (2026-10-27)

The source dependency moves from `8615e9f` to pushed commit `c936fd1`. Export uses
committed files only; uncommitted sibling changes are excluded. The sole outline
patch has identical added lines and rebased offsets. References, duplicate-key
validation and label selection now accept typed `dot.Name` values and bind
logical readers with `identifier.fromName`. Eight-byte name records replace
eight-byte spans in temporary indexes. Published storage and source lifetimes
stay unchanged. The optional graph layer and early/token-preview observations
remain disabled. No full AST or graph records are retained.

Both builds use Zig 0.17.0 `safe`, page allocation, buffered JSON and 4,096 parser
credits. Three alternating fresh-process trials cover open, broken edit and
repair. No concurrent builds, tests or UI actions ran during measurement.
RSS excludes Zed and the Python harness.

| Size | Layout | Open diagnostics before → after | Settled RSS before → after |
| --- | --- | ---: | ---: |
| 5 MB | plain | 39.1 → 43.2 ms | 7.438 → 7.455 MB |
| 5 MB | html | 39.2 → 40.9 ms | 7.291 → 7.307 MB |
| 20 MB | plain | 110.5 → 109.6 ms | 21.807 → 21.823 MB |
| 20 MB | html | 103.6 → 105.9 ms | 20.791 → 20.808 MB |
| 40 MB | plain | 189.8 → 186.3 ms | 40.927 → 40.944 MB |
| 40 MB | html | 174.9 → 174.7 ms | 38.814 → 38.830 MB |

The medians add about 16 KiB of settled RSS. Peak RSS at 40 MB remains about
125 MB. Timing varies: 5 MB plain open is 4.1 ms slower, and 40 MB HTML broken
edits are 192.2 → 198.9 ms. These samples do not establish a general speedup or
identical latency. Startup medians are recorded in the raw summary; the focused
LSP suite reports 2.28 ms median startup for the updated binary.

A separate nearly 5 MB fixture alternates long quoted and concatenated spellings
of one logical node name. Both versions return the same 4,922 locations, with
identical result hashes. Three alternating pairs give 49.2 → 45.8 ms from open
through the reference reply. The interval after diagnostics is 25.5 → 28.7 ms;
that interval includes pending completion/outline work, indexing and serialization,
so it is not a parser-only measurement. Settled RSS is 3.637 → 3.654 MB.

Three alternating 5 MB trials with 1,000 inserted syntax errors give broken-edit
diagnostics of 48.4 → 48.1 ms for plain DOT and 46.0 → 47.5 ms for HTML-heavy
input. Both builds report 1,001 findings at the cap, including the explicit
incomplete-checking notice; HTML retains both publication phases.

69 server and 208 vendored parser tests pass in both debug and safe builds.
All eleven protocol suites pass. The 26 captured baseline replies/findings match
after excluding only the expected server version string. Four focused suites
also pass with the debug allocator. Existing package archives and their Zed smoke
evidence still refer to the previous parser; rebuild them before publication.
No editor grammar or settings change is part of this update.

- [Summary and binary identities](../bench/results/parser-c936fd1/summary.json)
- [Protocol checks](../bench/results/parser-c936fd1/checks.json)
- [Wire parity](../bench/results/parser-c936fd1/wire-parity.json)
- [Debug-allocator checks](../bench/results/parser-c936fd1/debug-checks.json)
- [Repeated quoted-name comparison](../bench/results/parser-c936fd1/quoted-references.json)
- [1,000-error comparison](../bench/results/parser-c936fd1/errors-1000/summary.json)
- [Source identities and migration details](../bench/results/parser-c936fd1/implementation.json)

## Local package candidates (2026-10-25)

The local 0.0.1 candidates contain stripped native binaries for macOS and Linux,
ARM64 and x86-64. Both macOS builds target macOS 15 or later. Linux builds are
static. A separate Zed bundle contains compiled extension and grammar Wasm.
End users need no Zig or Rust toolchain. Nothing has been published.

The Mac ARM64 native archive is 280 KiB compressed; its executable is 604 KiB.
The other native archives are 300–308 KiB. The compiled Zed archive is 250 KiB.
Checks cover archive hashes, executable headers, dependency notices and absence
of checkout paths. Clean extraction on Mac ARM64 passes all eleven protocol
suites with no toolchain on PATH. The other three native targets have build and
archive checks only; matching-host runtime tests remain required. Three native
resolver tests cover offline cache reuse, failed downloads and invalid binaries.
An isolated Zed 1.25.3 profile registers the compiled extension as non-development
and launches the matching native binary from its versioned managed cache. Process
metadata confirms that server path and parent. No binary path override is set.
The user confirmed the sample's diagnostic underline, attribute hover help and
closing-bracket quick fix. Applying that fix clears the error. These are manual
visual results; the UI tool selects the normal Zed process and did not capture
the test window. This completes the local packaged smoke check on Mac ARM64.
Cold network download remains untested until release hosting is authorized.

Packaging changes version metadata, CPU targeting and stripping. It adds no
server feature index or parse work. Both compared binaries use Zig 0.17.0 `safe`,
the page allocator and the same parser. Three alternating trials give these
preliminary server-only measurements:

| Size | Layout | Open diagnostics development → packaged | Settled RSS development → packaged |
| --- | --- | ---: | ---: |
| 5 MB | plain | 39.7 → 37.5 ms | 7.44 → 7.34 MB |
| 5 MB | html | 35.1 → 34.2 ms | 7.29 → 7.19 MB |
| 20 MB | plain | 112.5 → 105.2 ms | 21.81 → 21.71 MB |
| 20 MB | html | 103.1 → 96.8 ms | 20.79 → 20.69 MB |
| 40 MB | plain | 188.5 → 186.6 ms | 40.93 → 40.83 MB |
| 40 MB | html | 170.3 → 166.8 ms | 38.81 → 38.72 MB |

Attempts to start a separate Zed profile may overlap early trials. These samples
do not establish a speedup or an isolated cold-start result. They exclude Zed
memory and show no material increase in retained server memory.

- [Package checks and native protocol results](../bench/results/packaging/checks.json)
- [Resolver tests](../bench/results/packaging/resolver-tests.json)
- [Isolated Zed registration and launch evidence](../bench/results/packaging/zed-local.json)
- [Preliminary comparison and binary identities](../bench/results/packaging/performance/summary.json)
- [Raw comparison](../bench/results/packaging/performance/comparison.json)

## Message templates (2026-10-24)

Diagnostics now use concise problem/repair lines for recognized closing delimiters
and edge endpoints. Attribute help has a heading, compact metadata, common examples
and a Graphviz reference. Hover negotiates Markdown/plaintext. Quick-fix titles
name closing delimiters and clear actions. Parser edits, feature indexes and
storage limits are unchanged. Formatting uses the existing 2 KiB response buffer.

Both binaries use Zig 0.17.0 `safe`, the page allocator and parser `8615e9f`.
Three fresh processes per size/layout/build ran in alternating order, without
concurrent builds, tests or UI work. The size matrix uses plain-text fallback.
RSS is server-only and excludes Zed and the Python harness.

| Size | Layout | Open diagnostics before → after | Settled RSS before → after |
| --- | --- | ---: | ---: |
| 5 MB | plain | 21.5 → 21.8 ms | 7.42 → 7.44 MB |
| 5 MB | html | 19.2 → 19.9 ms | 7.27 → 7.29 MB |
| 20 MB | plain | 84.4 → 85.5 ms | 21.79 → 21.81 MB |
| 20 MB | html | 77.1 → 74.8 ms | 20.77 → 20.79 MB |
| 40 MB | plain | 167.6 → 169.6 ms | 40.91 → 40.93 MB |
| 40 MB | html | 156.6 → 150.6 ms | 38.80 → 38.81 MB |

Timing remains in the previous range; these samples do not establish a speedup.
Settled RSS increases about 16 KiB in these medians. Idle RSS remains 2.18 MB
and peak RSS at 40 MB remains about 125 MB. There is no new per-document index
or retained formatted card. The raw summaries include startup and hover timing.

A separate three-trial 5 MB comparison advertises Markdown and inserts 1,000
errors. The old binary returns plaintext; the new binary returns Markdown.
Median hover receipt is 0.0715 → 0.0785 ms. The label hover response grows
311 → 455 bytes. Both builds retain 1,001 findings at the error cap, including
the explicit incomplete-checking notice. HTML keeps both publication phases.

Quick-fix requests on a 5 MB document also ran three alternating trials per build.
A single quotation fix took 0.099 → 0.109 ms; 1,000 quotation fixes took
0.975 → 1.275 ms. Both builds returned the same two versioned insertion edits
per fix. The longer titles add response bytes, not retained index storage.

69 unit tests and eleven protocol suites pass. All 177 catalog entries fit the
bounded plain/Markdown buffer. Tests cover client preference order, missing and
malformed capabilities, default values, links, examples, delimiter wording,
encodings, stale fixes and cancellation. Four focused suites also pass with the
debug allocator. Of 26 captured protocol replies/findings, only intended
presentation strings change; response structure, codes and ranges match.

Zed visual verification succeeded with its existing light theme: Markdown heading,
bold labels, inline code, DOT example and reference link render correctly. The
short missing-bracket diagnostic and “Insert closing ']'” menu were visible.
Applying the fix removed the underline; undo restored the error and left the
fixture clean. Existing dirty buffers and global theme settings were untouched.
No Zed RSS or rendering-cost comparison is claimed for these server measurements.

- [Size-matrix summary and binary identities](../bench/results/templates/summary.json)
- [Markdown/error-load summary](../bench/results/templates/markdown-errors-1000/summary.json)
- [Protocol checks](../bench/results/templates/checks.json)
- [Quick-fix request timings](../bench/results/templates/actions.json)
- [Allowed wire text changes](../bench/results/templates/wire-changes.json)
- [Debug-allocator checks](../bench/results/templates/debug-checks.json)
- [Zed visual check](../bench/results/templates/zed-visual.json)
- [Implementation and source identities](../bench/results/templates/implementation.json)


## macOS release stress checks (2026-10-24)

The server implementation and pinned parser are unchanged. The normal binary is
`620fa7b7`, Zig 0.17.0 `safe`, page allocator and buffered JSON. A separately built
`safe` debug-allocator binary checks cleanup at process exit. Both use parser
`8615e9f` and the existing outline hook. No editor settings or buffers changed.

The normal build passed 1,740 full-text edits; the debug build passed another 90.
Every edit alternated valid input with a 1,000-error version and queued a reference
request followed by cancellation. All 1,830 requests returned cancellation errors.
The size matrix used three open/edit/close cycles per layout, with 30 edits/cycle.
An extended 40 MB run added three cycles of 200 edits per layout.

| Size | Layout | Normal-build edits | Peak server RSS | Highest RSS after close |
| --- | --- | ---: | ---: | ---: |
| 5 MB | plain | 90 | 24.30 MB | 2.49 MB |
| 5 MB | html | 90 | 18.09 MB | 2.56 MB |
| 20 MB | plain | 90 | 90.73 MB | 2.49 MB |
| 20 MB | html | 90 | 90.78 MB | 2.54 MB |
| 40 MB | plain | 690 | 175.37 MB | 2.49 MB |
| 40 MB | html | 690 | 184.61 MB | 2.54 MB |

Initial idle RSS was about 2.18 MB. Repeated close returned the normal build to
2.49–2.56 MB without cycle-by-cycle growth. Debug-allocator close samples were
2.64–2.75 MB; its clean exits reported no leaks or allocator failures. Burst peaks
are higher than the earlier one-edit-at-a-time benchmark. They are different
workloads, not a before/after implementation comparison. All figures exclude
Zed and the Python sender.

The sender targeted 20 full-text edits/s. Actual rates were about 20/s at 5 MB,
16–20/s at 20 MB and 10.6–13.3/s at 40 MB. JSON encoding and input backpressure
affect those rates. This tests overload recovery, not 20 completed analyses/s.
The slowest cancellation receipt was 394.4 ms. Small-file error diagnostics
during a large-file rebuild took at most 160.5 ms. These are observed client
receipt times, including client scheduling and full-sync intake; they are not
parser-only timing or a guaranteed cancellation deadline.

Additional checks passed:

- Eight simultaneous 5 MB HTML-heavy documents over three cycles per run.
  Four documents had 1,000 errors; each completed check reported 1,001 findings,
  including the explicit incomplete-checking notice. Clean documents stayed clean.
- Close/reopen with version 1 reused, followed by completion and a reference query
  against the replacement content. Published versions never regressed within an
  incarnation; no versioned diagnostics followed its acknowledged close.
- 18 shutdowns after sending a 40 MB document; slowest clean exit
  98.7 ms. No stderr or allocator error was reported.
- Four output-suite runs: three normal and one debug-allocator. Partial packets,
  paused/resumed readers, intact 60,000-node outline replies, cancellation while
  output is paused, bounded stopped-reader failure and broken pipes passed.

The initial harness run treated a null clear-notification version as an integer.
That harness error was corrected before the successful runs; its failure record
is preserved. No server fix was needed. These are finite macOS workload checks,
not an exhaustive leak proof or a fixed wall-clock guarantee. Linux runtime and
Zed visual verification remain separate release work.

- [Summary and source/binary identities](../bench/results/stress-2026-10-24/summary.json)
- [5/20/40 MB matrix](../bench/results/stress-2026-10-24/stress.json)
- [Extended 40 MB run](../bench/results/stress-2026-10-24/soak-40/stress.json)
- [Multi-document/error/reopen checks](../bench/results/stress-2026-10-24/multi/stress.json)
- [Debug allocator checks](../bench/results/stress-2026-10-24/debug/stress.json)
- [Output checks](../bench/results/stress-2026-10-24/output-checks.json)


## Parser update to `8615e9f`

The dependency moved from `75ce950` to upstream HEAD `8615e9f`. The existing
outline hook is unchanged apart from patch offsets. New unfinished-token previews
are opt-in and remain disabled. No AST or new feature storage is retained.

Zig 0.17.0 `safe`, three alternating fresh-process trials per size/layout/build.
Memory below is server-only; it excludes Zed and the benchmark harness.

| Size | Layout | Open diagnostics before → after | Settled RSS before → after |
| --- | --- | ---: | ---: |
| 5 MB | plain | 43.4 → 42.1 ms | 7.42 → 7.42 MB |
| 5 MB | html | 20.1 → 20.2 ms | 7.27 → 7.27 MB |
| 20 MB | plain | 86.8 → 87.5 ms | 21.79 → 21.79 MB |
| 20 MB | html | 86.4 → 97.3 ms | 20.77 → 20.77 MB |
| 40 MB | plain | 172.8 → 186.9 ms | 40.93 → 40.91 MB |
| 40 MB | html | 166.9 → 169.5 ms | 38.80 → 38.80 MB |

Settled memory is unchanged. At 40 MB, plain DOT was about 8% slower in this
sample; HTML timing was close. Individual runs vary, so this does not establish
a systematic regression or speedup. Peak RSS remains about 125 MB at 40 MB.
Idle RSS is 2.18 MB. Raw evidence includes startup, edits, repair and readiness.

69 server unit tests, 208 vendored parser tests and all ten protocol suites pass.
The 26 baseline replies/findings match after excluding the intentional version
string update. Layout, formatting and exact vendor checks pass.

- [Summary and binary identities](../bench/results/parser-8615e9f/summary.json)
- [Protocol checks](../bench/results/parser-8615e9f/checks.json)
- [Dependency and test details](../bench/results/parser-8615e9f/implementation.json)


## Bounded output (migration step 7)

`protocol/output.zig` owns bounded frame chunks and write offsets. Incremental
intake and nonblocking POSIX stdio let the protocol thread serve input while
stdout is blocked. The existing worker encodes/queues frames; no extra worker or
full JSON copy is added. Queue caps are allocation credits, not preallocated RSS.
Parser policy, feature indexes and editor grammar are unchanged.

Both builds use Zig 0.17.0 `safe`, parser `75ce950`, the page allocator, packed
HTML entries and buffered JSON. Three fresh processes per size/layout/build ran
in alternating order. Open, broken-edit and repair packets were pre-encoded.
RSS is server-only and excludes Zed, the compiler and the Python harness.

| Size | Layout | Open diagnostics before → after | Settled server RSS before → after |
| --- | --- | ---: | ---: |
| 5 MB | plain | 38.1 → 43.4 ms | 7.54 → 7.44 MB |
| 5 MB | html | 41.5 → 39.7 ms | 7.39 → 7.29 MB |
| 20 MB | plain | 109.1 → 105.6 ms | 21.91 → 21.79 MB |
| 20 MB | html | 102.7 → 102.8 ms | 20.89 → 20.79 MB |
| 40 MB | plain | 190.1 → 187.5 ms | 41.03 → 40.91 MB |
| 40 MB | html | 172.2 → 171.3 ms | 38.91 → 38.81 MB |

Timing stays in the previous range and settled RSS falls slightly. These runs do
not establish a general speedup. Peak RSS at 40 MB remains about 125 MB. The raw
summaries also include broken/repair delay, first/final findings, readiness,
startup, hover and idle RSS.

66 unit tests and ten protocol suites pass at this checkpoint. The paused-reader
checks preserve a large outline frame, process close/shutdown while output is
blocked, bound exit and detect a broken pipe. Partial headers/bodies do not block
ready output. Ordinary error replies use bulk credits so a full deferred queue
does not exhaust the shutdown reserve. In-place intake passes focused suites
with the debug allocator.

- [Raw comparison and binary identities](../bench/results/refactor-output/comparison.json)
- [Summary](../bench/results/refactor-output/summary.json)
- [Protocol checks](../bench/results/refactor-output/checks.json)
- [Allocator/storage checks](../bench/results/refactor-output/storage-checks.json)
- [Source and implementation identities](../bench/results/refactor-output/implementation.json)

## Final runtime facade and dependency audit (migration step 8)

Publication admission, generation/fix-version checks, ready/pending queries and
worker startup now belong to runtime. Application imports are limited to runtime,
protocol and shared text. The import graph is acyclic. Main contains startup only.
Typed views retain feature readers until encoding finishes; queued frames then
own independent bytes. A job owns its completed HTML findings through the encoder
handoff. It does not copy their arrays. Failure diagnostics also use generation
checks before a frame starts.

The control metadata allowance was corrected to 16 KiB to cover an 8 KiB copied
URI plus frame/chunk metadata. This changes admission accounting, not an idle
allocation. The bulk allowance remains 256 KiB. Body, byte and frame caps are
listed in [FEATURES.md](FEATURES.md); input/index limits remain separate.

The same method compares the saved step 7 binary with the final step 8 binary:

| Size | Layout | Open diagnostics before → after | Settled server RSS before → after |
| --- | --- | ---: | ---: |
| 5 MB | plain | 26.9 → 27.7 ms | 7.42 → 7.42 MB |
| 5 MB | html | 36.5 → 25.6 ms | 7.29 → 7.27 MB |
| 20 MB | plain | 105.9 → 111.1 ms | 21.79 → 21.79 MB |
| 20 MB | html | 102.8 → 101.5 ms | 20.79 → 20.77 MB |
| 40 MB | plain | 192.5 → 194.2 ms | 40.91 → 40.91 MB |
| 40 MB | html | 171.9 → 172.5 ms | 38.81 → 38.80 MB |

At 40 MB, the final diagnostic medians differ by about 1.7 ms for plain DOT and
0.6 ms for HTML-heavy DOT. Settled memory is effectively unchanged. Peak server
RSS remains about 125 MB. Idle RSS is about 2.18 MB; startup medians span about
5.5–8.5 ms across these runs. Small-file timings vary substantially; do not infer
a general speedup from one median. This work adds no full AST, source copy,
worker, parser patch or external library.

### Many-error check

| 5 MB / 1,000 errors | Broken-edit diagnostics before → after | Peak RSS before → after |
| --- | ---: | ---: |
| plain | 46.1 → 43.3 ms | 17.92 → 17.89 MB |
| html | 40.4 → 48.5 ms | 18.09 → 18.06 MB |

Each broken edit returns 1,000 findings plus the same limit notice. Diagnostic
counts and serialized byte lengths match in every phase. The cap still reports
incomplete coverage; this does not claim unbounded error collection.

69 unit tests pass in Debug and safe builds. All ten protocol suites pass,
including 26 exact baseline replies/findings. In-place and arena builds pass six
focused suites each with the debug allocator. The final output test also cancels
a deferred request while a large reply holds stdout blocked. Allocation sweeps,
resource-error replies, retired-reader release and the HTML result handoff have
regression checks. The initial handoff failure is preserved with raw evidence.
The POSIX path cross-compiles for aarch64 Linux; runtime validation here is macOS.

Zed launched the rebuilt server and opened the smoke fixture. The UI tool could
not reliably capture/control that window, so the interactive repair check is not
counted as verified. Existing dirty buffers were not saved or discarded. This is
the remaining editor verification item, alongside separate M0 packaging/platform
and worst-case fairness release work. The full refactor is not an M0 release claim.

- [Raw comparison and binary identities](../bench/results/refactor-final/comparison.json)
- [Summary](../bench/results/refactor-final/summary.json)
- [Many-error comparison](../bench/results/refactor-final/errors-1000/summary.json)
- [Protocol checks](../bench/results/refactor-final/checks.json)
- [Allocator/storage checks](../bench/results/refactor-final/storage-checks.json)
- [Source and implementation identities](../bench/results/refactor-final/implementation.json)
- [Zed check scope and blocker](../bench/results/refactor-final/zed-smoke.json)

Earlier sections below describe historical checkpoints. Their architecture and
blocking-output notes do not describe the current implementation.

## Pipeline and worker extraction (migration step 5)

The worker loop now lives in `runtime/worker.zig`. Analysis work and phase
progression live in `analysis/pipeline.zig`. Publication acceptance stays in the
application as a named bridge. This checkpoint keeps the previous locking,
collector storage, priorities, yields and DOT → HTML → context/outline → references
order. There is no new source scan, source copy, parser patch or retained tree.

Both builds use Zig 0.17.0 `safe`, parser `75ce950`, the page allocator, packed HTML
entries and buffered JSON. Three fresh processes per size/layout/build ran in
alternating order with pre-encoded open, broken-edit and repair packets. Timing
and RSS are server-only. Zed and the Python harness are excluded.

| Size | Layout | Open diagnostics before → after | Settled server RSS before → after |
| --- | --- | ---: | ---: |
| 5 MB | plain | 42.4 → 41.1 ms | 7.47 → 7.45 MB |
| 5 MB | html | 38.7 → 39.3 ms | 7.31 → 7.31 MB |
| 20 MB | plain | 104.4 → 101.3 ms | 21.84 → 21.82 MB |
| 20 MB | html | 99.7 → 96.5 ms | 20.81 → 20.81 MB |
| 40 MB | plain | 188.6 → 178.2 ms | 40.96 → 40.94 MB |
| 40 MB | html | 171.3 → 169.0 ms | 38.83 → 38.83 MB |

Settled memory is effectively unchanged. The initial 5 MB plain edit timings
varied substantially, so the same binaries were measured again. Both rounds are
kept; use the raw per-phase values rather than treating one median as a general
speedup or slowdown. Protocol checks preserve 26 exact replies/findings and all
nine suites pass. At this checkpoint, 58 unit tests pass in Debug and safe builds.

- [Raw comparison and binary identities](../bench/results/refactor-pipeline/comparison.json)
- [Summary](../bench/results/refactor-pipeline/summary.json)
- [5 MB repeat](../bench/results/refactor-pipeline/repeat-5/summary.json)
- [Protocol checks](../bench/results/refactor-pipeline/checks.json)
- [Source identities and implementation checks](../bench/results/refactor-pipeline/implementation.json)

## Snapshot leases and unlocked encoding (migration step 6)

Each published feature has an independent reader lease. Edits retire document
ownership; the last reader frees the arrays and their live budget charge. Headers
and copied URI metadata use one small allocation per feature. Existing large
arrays transfer without copying. Quick fixes keep their captured document version.
JSON encoding and synchronous writes now run outside the state mutex. An ordered
output ticket keeps frames intact across the two existing threads. Diagnostics
recheck generation after encoding, before starting their frame.

The same controlled method compares step 5 with step 6:

| Size | Layout | Open diagnostics before → after | Settled server RSS before → after |
| --- | --- | ---: | ---: |
| 5 MB | plain | 39.6 → 44.1 ms | 7.45 → 7.54 MB |
| 5 MB | html | 40.0 → 41.7 ms | 7.31 → 7.39 MB |
| 20 MB | plain | 110.1 → 108.5 ms | 21.82 → 21.91 MB |
| 20 MB | html | 102.2 → 104.0 ms | 20.81 → 20.89 MB |
| 40 MB | plain | 185.1 → 187.5 ms | 40.94 → 41.03 MB |
| 40 MB | html | 169.6 → 173.1 ms | 38.83 → 38.91 MB |

At 40 MB, settled RSS rises by 81,920 bytes for both layouts. This is the measured
lease/metadata cost, not another source or index copy. Peak RSS stays about
125 MB. Idle RSS is about 2.31 MB; startup medians are about 7–8 ms. The small
diagnostic differences vary by size and layout; they do not establish a general
speedup. Feature readiness, broken/repair timings, peak RSS and hover costs are
kept in the linked summaries.

### Many-error check

| 5 MB / 1,000 errors | Broken-edit diagnostics before → after | Peak RSS before → after |
| --- | ---: | ---: |
| plain | 47.5 → 43.7 ms | 18.02 → 18.04 MB |
| html | 46.2 → 47.3 ms | 18.14 → 18.15 MB |

Each broken edit produces 1,000 findings plus the same limit notice. Counts and
serialized byte lengths match in all phases. Peak RSS covers the whole process,
not just response encoding.

66 unit tests pass in Debug and safe builds. Tests cover charged retired indexes,
reader release after allocation/encoding/write failure, stale diagnostic frames,
and concurrent edit/close while a reply writer is paused. All nine protocol suites
pass, including exact baseline parity. In-place and arena JSON builds pass five
focused suites with the debug allocator. Those checks exposed an empty transferred
request queue that still owned capacity; worker cleanup now always frees it. A
regression test covers that case. Initial failure evidence is kept with the checks.

Output still blocks. It can stall either existing thread, although it no longer
holds the state mutex. Bounded output progress is step 7; final facade/import
cleanup is step 8. No editor grammar change or Zed performance claim is made here.

- [Raw comparison and binary identities](../bench/results/refactor-snapshots/comparison.json)
- [Summary](../bench/results/refactor-snapshots/summary.json)
- [Many-error comparison](../bench/results/refactor-snapshots/errors-1000/summary.json)
- [Protocol checks](../bench/results/refactor-snapshots/checks.json)
- [Storage-mode checks](../bench/results/refactor-snapshots/storage-checks.json)
- [Source identities and implementation checks](../bench/results/refactor-snapshots/implementation.json)

## Runtime ownership extraction (migration step 4)

The current build puts document, job, pending-request and budget ownership in
`src/runtime/`. Prepared jobs commit a source allocation only after setup and
worker startup succeed. Runtime imports no protocol types. The application still
drives the existing worker and analysis phases; locking and synchronous output
are unchanged. At that checkpoint, step 5 had not started.

Jobs store neutral findings and related notes. Protocol serializes borrowed views
without copying whole arrays. The fixed wire source name is no longer stored
per finding. No full source scan, source copy, worker or retained tree is added.

Both builds use Zig 0.17.0 `safe`, parser `75ce950`, the page allocator, packed
HTML cache entries and buffered JSON. Three fresh processes per size/layout/build
ran in alternating order. Open, broken edit and repair packets were pre-encoded.

| Size | Layout | Open diagnostics before → after | Settled server RSS before → after |
| --- | --- | ---: | ---: |
| 5 MB | plain | 42.1 → 43.5 ms | 7.47 → 7.47 MB |
| 5 MB | html | 36.7 → 38.7 ms | 7.32 → 7.31 MB |
| 20 MB | plain | 106.7 → 113.7 ms | 21.84 → 21.84 MB |
| 20 MB | html | 102.8 → 100.7 ms | 20.82 → 20.81 MB |
| 40 MB | plain | 184.4 → 188.0 ms | 40.96 → 40.96 MB |
| 40 MB | html | 172.7 → 169.8 ms | 38.85 → 38.83 MB |

At 40 MB, plain open diagnostics increased by about 3.6 ms, while HTML decreased
by about 3.0 ms. Timing varies across runs; these figures do not establish a
general speedup or slowdown. Settled memory is effectively unchanged. Peak server
RSS remains about 125 MB at 40 MB input. Memory excludes Zed and Python.

### Many-error check

A separate 5 MB comparison changes 1,000 node starts in the broken edit. Both
builds publish 1,000 findings plus the same limit notice. Diagnostic counts and
serialized byte lengths match for all phases in both measured workloads.

| 5 MB / 1,000 errors | Broken-edit diagnostics before → after | Peak RSS before → after |
| --- | ---: | ---: |
| plain | 46.4 → 45.7 ms | 18.01 → 18.01 MB |
| html | 47.0 → 46.1 ms | 18.19 → 18.14 MB |

Peak RSS covers the complete open/broken/repair process, not an isolated
serialization allocation. The many-error case does not claim unbounded checking.

58 unit tests pass in Debug and safe builds. All nine protocol suites pass,
including 26 exact baseline replies/findings. Runtime tests cover allocation
failure, packet commit/rollback, failed worker startup, cancellation, source
admission and cleanup after output failure. In-place and arena JSON variants
pass five focused protocol suites with the debug allocator.

- [Raw comparison](../bench/results/refactor-runtime/comparison.json)
- [Summary](../bench/results/refactor-runtime/summary.json)
- [Many-error comparison](../bench/results/refactor-runtime/errors-1000/summary.json)
- [Protocol checks](../bench/results/refactor-runtime/checks.json)
- [Storage-mode checks](../bench/results/refactor-runtime/storage-checks.json)
- [Unchanged module checks](../bench/results/refactor-runtime/extraction-parity.json)
- [Ownership checks and binary identity](../bench/results/refactor-runtime/implementation.json)

## Protocol extraction (migration step 3)

The current build extracts framing, JSON intake, wire types/error codes, typed
request decoding and feature response encoding into `src/protocol/`.
`main.zig` now starts `app.zig`. Document/job/worker state remains in that
application module as the explicit bridge for steps 4–5. Serialization still
runs synchronously under the existing state lock; bounded output is not done.

Both builds use Zig 0.17.0 `safe`, the same parser, allocator and fixtures.
JSON intake and 12 state/phase methods match the baseline apart from named error
codes. There is no new source scan, source copy, worker or retained tree. Three
fresh processes per size/layout/build ran in alternating order. Open, broken-tail
edit and repair requests were pre-encoded.

| Size | Layout | Open diagnostics before → after | Settled server RSS before → after |
| --- | --- | ---: | ---: |
| 5 MB | plain | 44.3 → 42.3 ms | 7.49 → 7.47 MB |
| 5 MB | html | 41.0 → 39.5 ms | 7.32 → 7.32 MB |
| 20 MB | plain | 109.4 → 108.6 ms | 21.86 → 21.84 MB |
| 20 MB | html | 101.1 → 99.3 ms | 20.82 → 20.82 MB |
| 40 MB | plain | 186.8 → 197.2 ms | 40.98 → 40.96 MB |
| 40 MB | html | 172.1 → 177.5 ms | 38.85 → 38.85 MB |

The initial 40 MB diagnostic medians increased, so the same binaries were tested
again. Both rounds are kept. The repeat gives:

| 40 MB repeat | Open diagnostics before → after | Edit diagnostics before → after |
| --- | ---: | ---: |
| plain | 192.7 → 192.3 ms | 204.8 → 200.1 ms |
| html | 175.4 → 174.5 ms | 184.2 → 183.7 ms |

The diagnostic increase did not persist in the repeat. Timing varies; this is
not evidence of a general speedup or a fixed latency guarantee. Settled memory
is effectively unchanged, and peak server RSS remains about 125 MB at 40 MB.
Memory excludes Zed and Python. Startup, completion readiness and hover timings
are recorded in both summaries.

51 unit tests pass in Debug and safe builds. All nine protocol suites pass.
The boundary suite compares 26 exact replies/findings with the baseline, plus
framing/process-exit checks. In-place and arena JSON modes pass focused protocol,
attribute and fix checks with the debug allocator and cleanup assertions.

- [Raw comparison](../bench/results/refactor-protocol/comparison.json)
- [Summary](../bench/results/refactor-protocol/summary.json)
- [40 MB repeat](../bench/results/refactor-protocol/repeat-40/summary.json)
- [Protocol checks](../bench/results/refactor-protocol/checks.json)
- [Storage-mode checks](../bench/results/refactor-protocol/storage-checks.json)
- [Extraction parity](../bench/results/refactor-protocol/extraction-parity.json)
- [Build identity](../bench/results/refactor-protocol/implementation.json)

## Analysis and feature module moves (migration step 2)

The current build places analysis under `src/analysis/` and features under
`src/features/`. Unit tests use `src/tests.zig`, with parser-session tests under
`src/tests/`. All 12 moved modules match their previous contents except for
import paths. The production entry no longer contains the test aggregation block.
Parser policy, allocation policy, collectors, phase order and storage are unchanged.

Both binaries use Zig 0.17.0 `safe`, the same parser and the same fixtures.
Three fresh server processes per size/layout/build ran in alternating order.
The harness measures pre-encoded open, broken-tail edit and repair requests.

| Size | Layout | Open diagnostics before → after | Settled server RSS before → after |
| --- | --- | ---: | ---: |
| 5 MB | plain | 42.2 → 43.7 ms | 7.49 → 7.49 MB |
| 5 MB | html | 36.1 → 33.8 ms | 7.32 → 7.32 MB |
| 20 MB | plain | 105.4 → 105.7 ms | 21.86 → 21.86 MB |
| 20 MB | html | 97.9 → 99.0 ms | 20.82 → 20.82 MB |
| 40 MB | plain | 186.0 → 187.1 ms | 40.98 → 40.98 MB |
| 40 MB | html | 171.1 → 169.6 ms | 38.85 → 38.85 MB |

Memory is effectively unchanged. Peak server RSS remains about 125 MB at 40 MB
input. Small timing differences vary by case; this does not establish a general
speedup or slowdown. Memory excludes Zed and the Python harness.

- [Raw runs and binary identities](../bench/results/refactor-modules/comparison.json)
- [Timing and memory summary](../bench/results/refactor-modules/summary.json)
- [Protocol checks](../bench/results/refactor-modules/after-checks.json)
- [Move parity](../bench/results/refactor-modules/move-parity.json)
- [Build and verification record](../bench/results/refactor-modules/implementation.json)

## Shared text extraction (migration steps 0–1)

The first refactor step moves shared types and coordinate code into `src/text/`.
Outline no longer imports completion. Runtime ranges no longer depend on quick
fixes. The same coordinate arrays and source scans remain. No new source copy,
retained AST, worker or parser patch is added.

Boundary tests also found an existing truncated-UTF-8 decoder panic. A shared
guard fixes it. The comparison includes this correction and the extraction;
[the decoding patch](../bench/results/refactor-text/utf8-guard.patch) records the
behavior change separately. Both builds use Zig 0.17.0 `safe` and the same parser,
allocator, limits and fixtures. Three fresh processes per size/layout/build ran
in alternating order. Open, broken-tail edit and repair are pre-encoded.

| Size | Layout | Open diagnostics before → after | Settled server RSS before → after |
| --- | --- | ---: | ---: |
| 5 MB | plain | 21.2 → 21.7 ms | 7.50 → 7.49 MB |
| 5 MB | html | 30.7 → 31.1 ms | 7.34 → 7.32 MB |
| 20 MB | plain | 85.2 → 83.5 ms | 21.87 → 21.86 MB |
| 20 MB | html | 79.0 → 87.4 ms | 20.86 → 20.82 MB |
| 40 MB | plain | 188.9 → 185.8 ms | 40.99 → 40.98 MB |
| 40 MB | html | 173.7 → 171.1 ms | 38.86 → 38.85 MB |

Timings vary across runs. The first 20 MB HTML median increased, so the same
binaries were compared again. The repeat open median changed from
102.5 to 91.3 ms, and the edit median from 107.4 to 103.9 ms.
The earlier increase did not persist. Both rounds are preserved in the
[repeat evidence](../bench/results/refactor-text/repeat-20/summary.json).
These results do not establish a general speedup or a consistent slowdown.
Settled memory is effectively unchanged. Peak memory remains about 125 MB at
40 MB input. The figures cover server processes only, excluding Zed and Python.

- [Raw comparison](../bench/results/refactor-text/comparison.json)
- [Summary, edit/readiness/startup timings and memory](../bench/results/refactor-text/summary.json)
- [Before protocol checks](../bench/results/refactor-text/before-checks.json)
- [After protocol checks](../bench/results/refactor-text/after-checks.json)
- [Implementation identity and scan accounting](../bench/results/refactor-text/implementation.json)

## Zig 0.17 and parser update (2026-10-20)

The current build uses Zig 0.17.0 `safe` and dot-parser `75ce950b`.
It replaces the identifier patch with upstream `assumeParsed` operations.
The outline patch remains. Early public observations are available but are not
enabled by this migration. No full AST or new retained index is added.

Three fresh processes per size/layout/build ran in alternating order. The previous
binary uses Zig 0.16.0 ReleaseSafe and parser `b58db00e` with two patches.
This comparison measures the compiler and parser update together. It does not
isolate which change causes a difference. Memory excludes Zed and Python.

| Size | Layout | Open diagnostics before → after | Settled server RSS before → after |
| --- | --- | ---: | ---: |
| 5 MB | plain | 43.6 → 43.6 ms | 7.37 → 7.50 MB |
| 5 MB | html | 40.4 → 36.2 ms | 7.21 → 7.34 MB |
| 20 MB | plain | 114.0 → 111.3 ms | 21.74 → 21.87 MB |
| 20 MB | html | 100.5 → 95.2 ms | 20.71 → 20.84 MB |
| 40 MB | plain | 196.9 → 191.9 ms | 40.86 → 40.99 MB |
| 40 MB | html | 179.0 → 171.8 ms | 38.73 → 38.86 MB |

At 40 MB, edit diagnostics changed from 205.7 to 192.3 ms for plain DOT,
and from 185.7 to 172.8 ms for HTML. Peak RSS stays about 125 MB.
Settled RSS is 0.13 MB higher across these fixtures. Startup remains about
7–9 ms in this harness. Treat the small timing gains as measurements, not guarantees.

- [Raw runs and binary identities](../bench/results/zig17/comparison.json)
- [Summary and method](../bench/results/zig17/summary.json)
- [Protocol checks](../bench/results/zig17/checks.json)


## Attribute help baseline (2026-10-20)

This earlier comparison introduced attribute-name completion and hover. The comparison uses
three fresh processes per size/layout/build, alternating the old and new builds.
Both use Zig 0.16.0 ReleaseSafe and the same allocator, parser and fixtures.
No full AST or source text is retained by attribute help.

| Size | Layout | Open diagnostics | Completion ready after open | Settled server RSS |
| --- | --- | ---: | ---: | ---: |
| 5 MB | plain | 46.2 ms | 68.9 ms | 7.37 MB |
| 5 MB | html | 40.3 ms | 65.2 ms | 7.21 MB |
| 20 MB | plain | 113.3 ms | 185.7 ms | 21.74 MB |
| 20 MB | html | 103.5 ms | 179.6 ms | 20.71 MB |
| 40 MB | plain | 196.3 ms | 341.3 ms | 40.86 MB |
| 40 MB | html | 168.0 ms | 326.0 ms | 38.73 MB |

At 40 MB, plain diagnostics changed from 196.2 to 196.3 ms, and HTML diagnostics
from 175.1 to 168.0 ms. Readiness changed from 310.5 to 341.3 ms for plain
DOT and from 311.9 to 326.0 ms for HTML. Readiness includes the completion reply,
not only one internal function. Attribute collection runs after DOT/HTML
diagnostics, alongside the existing completion-coordinate pass. Small diagnostic
differences varied across cases; do not claim a general speed improvement.

Settled RSS increased from 36.01 to 40.86 MB for plain DOT and from
35.54 to 38.73 MB for HTML. Actual peak RSS remained about 125 MB on both
40 MB fixtures. Additional retained memory holds compressed keys and extra
editing-context changes. Ready hover requests took about 0.07–0.08 ms. The old
build does not implement hover; its error timing is not a hover baseline.

Startup remained roughly 7–8 ms in this harness. Treat small timing differences
as machine measurements, not guarantees. Memory figures exclude Zed and Python.

- [Raw comparison and binary identities](../bench/results/attributes/comparison.json)
- [Summary and method](../bench/results/attributes/summary.json)
- [Protocol checks](../bench/results/attributes/checks.json)
- [Zed check status and UI-control limitation](../bench/results/attributes/editor-check.json)

The feature protocol tests pass. Automated capture failed during that run.
The user later supplied a Zed screenshot that confirms the hover popup works.

## Earlier parser comparison

The preceding controlled comparison was the parser migration from 2026-10-20.
That comparison used dot-parser `b58db00e` with two local patches.
These measurements describe one machine, not a performance guarantee.

Build: Zig 0.16.0, ReleaseSafe, page allocator with packed HTML entries and
buffered JSON intake. Both sides use the same compiler, settings and fixtures.
Each case uses three fresh server processes in alternating before/after order.
Sizes use decimal MB. Peak RSS comes from `wait4` and excludes Zed and Python.

## Parser migration baseline

Open means the first complete diagnostic publication after a full file open.
For HTML, it means the final merged publication. Edit medians combine a broken
tail and its repair. Input transfer and JSON intake are included.

| Size | Layout | Open diagnostics | Edit diagnostics | Peak server RSS |
| --- | --- | ---: | ---: | ---: |
| 5 MB | plain | 26.3 ms | 30.4 ms | 17.87 MB |
| 5 MB | html | 27.1 ms | 31.1 ms | 18.02 MB |
| 20 MB | plain | 87.5 ms | 91.3 ms | 63.83 MB |
| 20 MB | html | 74.9 ms | 80.9 ms | 63.98 MB |
| 40 MB | plain | 164.3 ms | 174.1 ms | 125.08 MB |
| 40 MB | html | 139.7 ms | 154.6 ms | 125.29 MB |

At 40 MB, plain open diagnostics changed from 157.3 to 164.3 ms. HTML open
diagnostics changed from 135.3 to 139.7 ms. Edit medians changed from 168.8 to
174.1 ms for plain DOT, and from 145.5 to 154.6 ms for HTML. The update has a
small measured time cost; do not describe it as a speed improvement.

Peak server memory stayed effectively unchanged: about 125 MB at 40 MB input.
Idle RSS changed from about 2.16 to 2.21 MB. The startup harness generally
measured about 7–8 ms; it includes harness setup and is not pure process startup.

## Reference construction and outline parity

At 40 MB, the reference stage changed from 63.9 to 65.2 ms for ordinary names.
A separate stress fixture repeats two quoted names. Its reference stage changed
from 72.3 to 76.3 ms with the retained trusted-identifier patch. The earlier
unpatched trial took about 121 ms on that stress fixture. These are separate
runs, not a precise isolation of one function. The timer includes reference
construction and publication; it excludes outer parsing and delayed HTML.

All 17 outline comparisons match the old names, hierarchy and ranges. The
unchanged outline protocol suite also passes, including broken input and limits.
Additional tests preserve full node ranges and exclude trailing comments from
the graph range. No full AST is retained.

The earlier outline study measured a 13.41 MB retained outline for the 40 MB
HTML fixture and a large response cost. This migration did not repeat response
serialization timing. The output/state mutex limitation still applies.

## Evidence and scope

- [Migration measurements and summary](../bench/results/upstream-migration-2026-10-20/patched/summary.json)
- [Raw process and phase measurements](../bench/results/upstream-migration-2026-10-20/patched/performance.json)
- [Build identities](../bench/results/upstream-migration-2026-10-20/patched/binary-identities.json)
- [Outline comparison](../bench/results/upstream-migration-2026-10-20/patched/parity.json)
- [Protocol checks](../bench/results/upstream-migration-2026-10-20/patched/protocol-results.json)
- [Earlier unpatched migration trial](../bench/results/upstream-migration-2026-10-20/audit.json)
- [Previous outline study](../bench/reports/DOCUMENT_OUTLINE.md)
- [Controlled comparison with dot-language-server](../bench/reports/SERVER_COMPARISON.md)
- [Isolated Zed performance](../bench/reports/ZED_EDITOR_PERFORMANCE.md)
- [Zed grammar memory investigation](../bench/reports/ZED_GRAMMAR_MEMORY.md)

Reference-stage logging exists only in the profiled copies. The installed
binary has no measurement logging. Do not combine editor and server results,
or compare numbers from different historical fixtures as a controlled pair.

## Future comparisons

Follow [bench/README.md](../bench/README.md). Keep first/final diagnostics,
background readiness, feature requests, idle/settled/peak memory and startup
separate. Record source and binary hashes, settings, fixture hashes and raw data.
Start at 5 MB, then 20 and 40 MB if responsive. Do not run competing builds or
tests during measurements. Preserve pilot and excluded runs with their reasons.

Current ownership and response limits are in [ARCHITECTURE.md](ARCHITECTURE.md).
Current feature limits are in [FEATURES.md](FEATURES.md). Do not infer current
limits from a historical report.
