> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

# Index construction: profile and optimization

Measured on 2026-10-14. DOT diagnostics now publish before node interning and
range conversion. The index uses less memory. Whole-index speed improved at
40 MB and on quoted IDs, but not substantially at 100 MB. There is no retained
AST or source cache, and no new library, editor setting, or worker thread.

## Where the old time went

The old observer interned names during the parse. It allocated a temporary decode
buffer for every quoted occurrence. Publication then waited for range conversion.
The profile separates a plain parse control from the indexed parse and finish.
These are medians of five instrumented runs on the same 40 MB example.

| Core stage | Original | Selected candidate |
| --- | ---: | ---: |
| Plain parse control, without an observer | 86.1 ms | 87.1 ms |
| Parse and collection | 148.4 ms, including interning | 91.8 ms, spans only |
| Name interning after parsing | included above | 53.7 ms |
| Source ordering | skipped, already ordered | skipped, already ordered |
| Editor-range conversion | 37.3 ms | 16.8 ms |
| Sum of parse/collection and finish medians | 185.7 ms | 162.4 ms |

Plain parsing is a control, not an extra pass in production. The old interning
and append overhead is about 62 ms above that control. The new span collector
adds about 5 ms. Instrumented stages exclude transport, JSON intake, diagnostic
formatting, and cleanup. Counters and trace writes can affect timings. Use the
normal-server results below for end-to-end latency.

## Where construction memory went

The following are requested allocator bytes live at the relevant stages, not
RSS. Arrays include their capacity. The source is a separate 40 MB allocation.

| Storage for 40 MB input | Original | Selected candidate |
| --- | ---: | ---: |
| Name table after interning | 22.02 MB | 13.63 MB |
| Collected occurrence buffer | 22.98 MB | 15.65 MB |
| Finished single-line occurrence entries | 32.65 MB | 26.12 MB |
| Additional source-order scratch for this ordered input | 0 MB | 0 MB |
| Peak live requested bytes, including source and growth overlap | 117.65 MB | 102.22 MB |

The old collector stored a span and identity number: 12 bytes per element. The
new collector stores only the 8-byte span. Names are interned later. Hash-table
keys are 8-byte source spans instead of 16-byte string slices. Logical hashes
and exact comparisons stream the parser-accepted ID spelling. A hash collision
cannot merge different node IDs. Quoted and concatenated forms do not require
decode allocations. Temporary source ownership keeps all spans valid.

The final common entry is 16 bytes: line, column, length, and identity number.
Multiline IDs use an extra 8-byte end-position record, for 24 bytes total per
such occurrence. This is a tradeoff: single-line entries are 20% smaller; a file
made entirely of multiline IDs can have a larger index than before. Both parts
count toward the existing retained-index budget. All temporary names and spans
are released at index completion or cancellation.

Independent category peaks must not be added together. Table growth can keep
old and new allocations live briefly. The requested-byte peak above records
that overlap. Full-server peak RSS below also includes JSON intake, stacks,
executable pages, and allocator effects.

## Experiments

The first compact span-key candidate reduced memory but took about 198.6 ms of
40 MB core work, versus 185.7 ms originally. Generic logical-ID handling and a
32-byte ASCII block were too costly for these short IDs and gaps.

The selected candidate uses direct hashing/comparison for bare and numeral IDs,
with the parser's streamed logical-value helpers for quoted and HTML-like IDs.
Eight-byte ASCII blocks fit the short spans better; Unicode and line endings use
the scalar path. Core time fell to about 162.4 ms. Cancellation checks remain in
capture, sorting, interning and conversion. Sorting uses 8-byte spans instead of
12-byte records. It is skipped for already ordered input.

Two additional synthetic 1 MB inputs check different costs. One repeats two
quoted IDs. The old build made 166,666 temporary decode allocations per build,
plus one arena allocation for stored values. The candidate makes none. Profiled
parse-plus-index work fell from about 221 ms to 10 ms. The other repeats short
edge chains, which require ordering. Core work changed from about 9.8 to 10.2 ms,
a small regression; diagnostics still move ahead of sorting and interning.
These workloads are not substitutes for the unique-node large-file examples.

At 100 MB, old core work was about 501.7 ms and the candidate about 496.7 ms.
Interning alone still takes about 223 ms. The table's capacity steps and large
unique-node population matter here. Do not claim that the whole index became
much faster at this size.

## Normal-server diagnostics latency

Both binaries use Zig 0.16.0, ReleaseSafe, the page allocator, buffered JSON intake,
and the same metered/cancellable block scanner. The baseline is the original
reference-enabled binary. Each process opens one existing example and receives
three pre-encoded error/repair pairs. The table shows edit-to-publication medians
of three samples. MB means decimal MB. No editor rendering time is included.

| File | Clean edit, original → optimized | Error edit, original → optimized |
| --- | --- | --- |
| 5 MB | 29.6 → 19.8 ms | 27.5 → 22.6 ms |
| 20 MB | 118.1 → 75.7 ms | 114.1 → 89.8 ms |
| 40 MB | 246.9 → 152.2 ms | 230.6 → 168.9 ms |
| 100 MB | 665.7 → 396.0 ms | 606.8 → 449.6 ms |

A separate preserved binary without references measured 151.0 ms for a clean
40 MB edit and 168.6 ms for an error edit. The optimized build measured 152.2 and
168.9 ms. At 100 MB that control measured 377.9 and 427.1 ms, versus 396.0 and
449.6 ms with span capture. Diagnostics are close to the control, but capture is
not free. These are small development samples, not a statistical release gate.

## Readiness is separate from diagnostics

| File | First reference wait after diagnostics | Ready lookup median | Final clean edit through first reference result, original → optimized |
| --- | ---: | ---: | ---: |
| 5 MB | 7.0 ms | 0.08 ms | 28.4 → 25.8 ms |
| 20 MB | 32.2 ms | 0.22 ms | 116.4 → 107.9 ms |
| 40 MB | 70.0 ms | 0.45 ms | 248.9 → 222.2 ms |
| 100 MB | 284.7 ms | 1.00 ms | 665.2 → 680.6 ms |

The readiness column uses one final clean edit plus its first reference request.
It is not a median or the sum of unrelated medians. The following 20 lookups
select a node with two uses. At 100 MB, total readiness is slightly slower in this
sample. The benefit is much earlier diagnostics and a smaller retained index.
A request made immediately after diagnostics can now wait for index completion.
It does not need an editor retry merely because the index is still building.

## Normal-server memory

| File | Exact retained index, original → optimized | Actual peak RSS, original → optimized | Optimized settled RSS |
| --- | ---: | ---: | ---: |
| 5 MB | 4.08 → 3.27 MB | 17.84 → 19.82 MB | 5.65 MB |
| 20 MB | 16.33 → 13.06 MB | 64.63 → 70.76 MB | 15.45 MB |
| 40 MB | 32.65 → 26.12 MB | 136.13 → 141.02 MB | 28.51 MB |
| 100 MB | 81.63 → 65.31 MB | 368.38 → 344.82 MB | 67.68 MB |

Idle RSS stayed at 2.13 MB in these runs. RSS after close returned to about
2.36 MB. Index storage shrank by 20% on these single-line fixtures. Peak RSS did
not shrink at every size: it rose by about 4.9 MB at 40 MB and fell by about
23.6 MB at 100 MB. Diagnostics now let the next update arrive before the prior
index job releases its temporary source. This can overlap intake and background
storage. The larger sizes and retained index must be assessed separately.

Peak RSS is macOS `/usr/bin/time -l` maximum resident set size, not a sampled peak.
Idle, settled and close RSS are `ps` samples. Client and Zed memory are excluded.
The source/input allocation budgets are unchanged. Queued index jobs retain
source temporarily and count toward the existing 512 MiB source budget.

The binary grew from 678,024 to 679,096 bytes: 1,072 bytes. Fifteen direct warm
starts measured about 2.30 ms before and 2.51 ms after. This small sample does not
establish a startup regression or improvement; cold starts were not measured.

## Scheduling and request ownership

The existing worker runs syntax before queued index work. New syntax jobs
interrupt an index build at cooperative checks. Packets of at least 64 KiB also
pause indexing while the dispatcher reads, decodes and releases intake storage.
This avoids letting index work compete with large editor changes. That threshold
is an internal scheduling choice, not a document or feature limit.

A yielded index attempt releases its hash table and partially built output.
The job keeps source spans for a retry. Source-order sorting preserves a complete
permutation on yield. An edit to the same document cancels the obsolete job.
Every publication checks the document generation. No old source locations are
returned for a new document version.

A bounded queue holds reference requests submitted before index readiness.
String request IDs are copied out of intake storage. Success, edit/close,
explicit cancellation, failure and shutdown all release request storage.
`$/cancelRequest` returns RequestCancelled for a queued request. Edit/close
returns ContentModified. Invalid syntax or failed construction returns
RequestFailed. The existing 64-request, 8 KiB-ID, 10,000-location, source and
retained-index limits are documented in FEATURE_REQUIREMENTS.md.

The index is still built eagerly after diagnostics. This change does not retain
an AST or add an indefinite source cache. It does not remove all reference cost:
large unique-name tables remain the next main optimization target. A single
logical-ID hash/comparison is not resumable inside the helper; the index polls
between groups of occurrences. Large individual IDs can therefore delay a yield.

## Validation and reproduction

Debug and ReleaseSafe unit checks passed. Protocol checks passed with the page
allocator and debug allocator, including the experimental in-place JSON mode.
Tests cover queued string IDs, edit invalidation, explicit cancellation,
foreground-document priority, malformed large packet recovery, allocation failure,
yield/retry, compact multiline ranges, logical-ID forms, and all position
encodings. Existing protocol and reference checks still pass. Neovim verified
attachment, diagnostics, completion and references. Zed was restarted on the
optimized binary and showed the same five `build` references.

Production has no profiling timers or allocation counters. To create a disposable
instrumented copy, run `python3 tools/prepare_index_profile.py [SOURCE_SNAPSHOT]`.
In the printed directory, run `zig build profile-index -Doptimize=ReleaseSafe`.
Capture it with `python3 tools/run_index_profile.py BINARY LABEL INPUT`.
Use a pipe, as the runner does; do not redirect the Zig trace writer directly to
a seekable file. The profile executes five parse controls and index builds.

Run `python3 tools/index_bench.py before BASELINE` and then the same command with
`after CANDIDATE`. Add `100` to run only the 100 MB case. Use label `syntax` for a
control binary without reference support. Builds, tests, and other benchmarks
must finish before measurements. Warm starts use
`python3 tools/references_startup.py BASELINE CANDIDATE docs/index-optimized-startup.json`.

The original source and binary are preserved locally in
`/private/tmp/dot-ls-index-study`. The syntax-only control is
`/private/tmp/dot-ls-references-before/dot-ls`. These are experiment artifacts,
not project build/test dependencies. Protocol records include binary hashes.
The synthetic fixtures are `digraph {\n` plus repetitions of either
`"a" -> "b";\n` or `a -> b -> c -> d;\n`, then `}\n`; repeat each line
`1_000_000 // len(line)` times.

Raw evidence: [40 MB original stages](../results/legacy/index-profile-before.json),
[first compact candidate](../results/legacy/index-profile-compact.json),
[selected stages](../results/legacy/index-profile-fast.json),
[100 MB original stages](../results/legacy/index-profile-hundred-before.json),
[100 MB selected stages](../results/legacy/index-profile-hundred-after.json),
[quoted original](../results/legacy/index-profile-quoted-before.json),
[quoted selected](../results/legacy/index-profile-quoted-after.json),
[chain original](../results/legacy/index-profile-chains-before.json),
[chain selected](../results/legacy/index-profile-chains-after.json),
[protocol before](../results/legacy/index-optimized-before.json),
[protocol after](../results/legacy/index-optimized-after.json),
[100 MB before](../results/legacy/index-optimized-before-100.json),
[100 MB after](../results/legacy/index-optimized-after-100.json),
[syntax control](../results/legacy/index-optimized-syntax-40-100.json),
[warm startup](../results/legacy/index-optimized-startup.json).
