> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

# Full HTML label coverage with bounded selection storage

Measured 2026-10-15. The current server checks all 117,646 labels in the 20 MB
fixture and all 235,293 labels in the 40 MB fixture. Errors in the last label
are reported. Neither file produces the former HTML label-count notice.
This holds for both repeated bodies and distinct bodies beyond cache capacity.

The change replaces the fixed list of 65,536 eight-byte spans with unsigned
varints: the gap from the previous body end, then the body length. Selection
still comes from the same outer DOT parser pass. There is no extra DOT parse,
retained AST, library, thread, editor setting or change to the cache allocator.

## Bounds and ownership

The encoded stream has an explicit source-derived capacity limit of
`source_bytes / 4 + 16`. A selected attribute has at least the eight bytes in
`label=<>`. The gap and length encodings fit within one quarter of the source;
16 extra bytes cover the first record and small-input allowance. Longer keys,
bodies and gaps supply enough source bytes for their larger encodings.
The shortest-attribute regression test exercises this tight bound.

Capacity growth is clamped to that limit, not only the number of used bytes.
At the existing 200 MiB file limit, retained requested span capacity therefore
cannot exceed 50 MiB plus 16 bytes per job. This is a worst-case ceiling, not
an allocation made for each file. A resize can briefly hold old and new buffers;
allocator rounding adds physical overhead. This bounds storage by input size,
not by a constant independent of input size.

The job owns the stream and frees it on completion or cancellation. The delayed
reader commits its position only after a fragment finishes, so interrupted
checks retry the same label. Generation checks, position mapping and cache
ownership remain in place.

Cache limits are unchanged: 8 MiB / 4,096 entries per document, and 32 MiB /
16,384 entries across live retained payload. Cache pressure causes rechecking,
not skipped labels. Fragment limits, diagnostic limits, allocation failures and
outer-DOT recovery limits remain explicit. In particular, a fragment that
exceeds its untrusted limits or enough errors to fill the finding budget can
still produce an incomplete notice. This change removes the independent label-
count cutoff; it does not remove those other safeguards.

## Controlled before/after server measurements

Apple M4 Pro, 14 logical CPUs, 48 GiB RAM, native arm64 macOS 27.0.1. Both servers
use Zig 0.16.0 ReleaseSafe, the page allocator, buffered JSON and the same packed
HTML entry allocator. These are two versions of dot-ls, not two different LSPs.
No editor is part of the measurements.

The files are exactly 5/20/40 million bytes and use the dense HTML layout from
[the controlled server comparison](SERVER_COMPARISON.md). Each record has one
multiline label and one edge. One workload repeats the exact body. The other
uses a distinct eight-digit text ID in every body, preserving file size and
layout. All selected labels are unique in that second workload.

Each case uses three fresh server processes. Each process receives six versions:
clean open, outer-only edit, last-label mismatch, repair, another last-label
mismatch and repair. The two mismatches change `</B>` to `</I>` without changing
outer DOT validity. The harness checks that the reported error is on the last
label's line and that repairs clear it. Both stages must refer to the current
version. It also checks that the new build reports no incomplete notice.

Messages are pre-encoded. Time starts before writing to stdio and ends when the
whole diagnostic frame is received. Client JSON encoding and editor costs are
excluded; transport and backpressure are included. DOT publishes first; the
merged result includes HTML checking and coordinate mapping. The resource
client and timing boundaries are the same for both builds.

Open times below are medians of three observations. Tail-error times are medians
of six observations across three processes. Peak RSS is the highest actual
process high-water RSS from macOS `wait4`, not a sparse sample. It covers the
whole six-version process. MB below is decimal. These are small local samples;
minor differences do not demonstrate a performance improvement.

### Complete clean-file result

**Old 20/40 MB results are incomplete:** they stop at 65,536 labels. New results
cover the full label count. The 5 MB cases already fit the old cap.

| Bodies | File | Old merged delay | New merged delay | Old peak RSS | New peak RSS |
| --- | --- | ---: | ---: | ---: | ---: |
| Repeated | 5 MB | 37.3 ms | 38.4 ms | 17.96 MB | 17.97 MB |
| Repeated | 20 MB | 94.6 ms, partial | 91.9 ms | 63.86 MB | 63.90 MB |
| Repeated | 40 MB | 156.6 ms, partial | 155.9 ms | 125.14 MB | 125.30 MB |
| Unique | 5 MB | 133.5 ms | 130.2 ms | 19.28 MB | 19.28 MB |
| Unique | 20 MB | 302.4 ms, partial | 441.6 ms | 65.21 MB | 65.34 MB |
| Unique | 40 MB | 354.0 ms, partial | 888.3 ms | 126.48 MB | 126.53 MB |

For repeated content, exact-content reuse keeps the extra checks cheap.
For unique content, full coverage takes more CPU: the server now parses the
labels that the old implementation skipped. Memory remains almost unchanged.
The unique workload is important: the result is not based only on cache hits.

### Error in the last label

| Bodies | File | Old final publication | New error publication |
| --- | --- | ---: | ---: |
| Repeated | 20 MB | 95.9 ms, error missed; limit notice | 108.1 ms, error reported |
| Repeated | 40 MB | 154.7 ms, error missed; limit notice | 182.5 ms, error reported |
| Unique | 20 MB | 305.0 ms, error missed; limit notice | 483.1 ms, error reported |
| Unique | 40 MB | 358.3 ms, error missed; limit notice | 971.7 ms, error reported |

The new error publication also maps the HTML findings into whole-document line
positions. The old capped result did not perform that work for the tail error.
Do not interpret the old publication as a successfully checked clean document.

DOT-first publication remains separate. On the unique 40 MB clean input, its
median is 155.6 ms before and 157.9 ms after, while the merged result now takes
888.3 ms. The full HTML work therefore does not hold back the first DOT result.
These are protocol timings, not key-to-paint or editor-responsiveness measurements.

## Selection and cache allocation profile

Separate disposable instrumented builds measure requested allocation bytes,
without LSP intake or reference-index construction. Do not equate them with RSS
or sum independent allocation peaks. A fresh profile process is used per file.

| File | Old selected labels | New selected labels | Old span bytes / capacity | New span bytes / capacity |
| --- | ---: | ---: | ---: | ---: |
| 20 MB | 65,536 | 117,646 | 524,288 / 610,400 | 235,292 / 283,574 |
| 40 MB | 65,536 | 235,293 | 524,288 / 610,400 | 470,586 / 638,201 |

The same selection sizes apply to repeated and unique bodies. The 40 MB stream
uses fewer encoded bytes than the old capped list while covering 3.6 times as
many labels. Its reserved capacity is only about 28 KB larger.

In the unique 40 MB profile, all **235,293** bodies are parsed. The cache retains
only 4,096 entries and 708,608 logical payload bytes, the same as before.
The remaining bodies are still checked and their temporary entries released.
For repeated bodies, one parsed result is reused for every other label.
All profiled after cases finish without an incomplete notice.

Settled server RSS is unchanged in these observations: about 12.29 / 22.02 MB
for repeated 20/40 MB files, and 13.63 / 23.36 MB for unique files. Selection
storage and the full source belong to the job and are released after background
work; bounded feature indexes and the result cache remain.

## Regression and lifecycle checks

- Debug and ReleaseSafe unit tests pass, including variable-width offsets,
  overflow/order/budget rejection, allocation-failure cleanup and the shortest
  selected attribute repeated 70,000 times within its capacity bound.
- The HTML protocol suite passes, including 70,000 labels, a final-label error,
  newline rebasing, exact-content reuse, repair, UTF-8/16/32 and obsolete versions.
- The core LSP protocol suite passes.
- The label-free 5/20/40 MB control does not show a material regression. Plain
  40 MB clean-open medians are 179.7 ms before and 180.1 ms after. Tail syntax
  error medians are 206.0 / 201.8 ms. Peak RSS is 125.12 / 125.50 MB. Small RSS
  and timing differences are within the variation of these runs.
- A unique 40 MB close/reopen check settles at 23.38 MB open and 2.47 MB closed
  in both rounds, compared with 2.18 MB initial idle RSS. Storage is not retained
  in proportion to the labels after closing the document.
- Replacing that document while HTML work is pending produces only the new
  version's two publications afterward. The small replacement's final result
  arrives in 0.71 ms in this one probe. That is a cancellation check, not a
  general latency estimate. Settled RSS falls to 2.67 MB.

The first lifecycle probe used a change notification after close instead of an
open notification. That client mistake was corrected; its timeout is not a
server failure. An initial plain-DOT candidate control overlapped a unit-test
build. It was excluded and the whole control rerun after compilation finished.
The excluded control is retained separately and is not used in these tables.

## Evidence and reproduction

[Raw records and summary](../results/html-label-cap) include:

- `before.json` / `after.json`: repeated and unique HTML cases.
- `plain-before.json` / `plain-after.json`: label-free regression control.
- `allocation-profiles.json`: selected, checked/reused counts and allocator data.
- `lifecycle.json`: close/reopen and cancellation evidence.
- `environment.json`: build configuration, fixture and source provenance.
- `restore-baseline.patch`: current-to-old server patch for a disposable copy.

The final rebuild includes a stronger minimum-size metadata test. Its executable
text is identical to the measured HTML candidate; whole-file hashes differ.
`final-build.json` records both hashes. Tests and comments do not change the
measured runtime algorithm.

From the project root, with Zig 0.16.0 and the macOS resource APIs:

```sh
/path/to/zig-0.16.0/zig build test
/path/to/zig-0.16.0/zig build test -Doptimize=ReleaseSafe
/path/to/zig-0.16.0/zig build -Doptimize=ReleaseSafe
python3 tests/html.py zig-out/bin/dot-ls
python3 tests/lsp.py zig-out/bin/dot-ls
python3 tools/html_cap_bench.py before /path/to/preserved-before-binary
python3 tools/html_cap_bench.py after zig-out/bin/dot-ls
python3 tools/html_cap_bench.py before /path/to/preserved-before-binary --plain
python3 tools/html_cap_bench.py after zig-out/bin/dot-ls --plain
python3 tools/html_cap_bench.py after zig-out/bin/dot-ls --lifecycle
```

Prepare allocation profilers with `tools/prepare_html_profile.py`. Build its
`profile-html` step in the returned disposable directory, then run the profiler
against the generated `/private/tmp/dot-ls-server-comparison/cap-*.dot` fixtures.
Apply `restore-baseline.patch` only in a disposable source copy to reconstruct
the old server; do not restore the cap in the working project.

The implementation adds no platform-specific runtime behavior. macOS APIs are
used only by the measurement tools. The normal server build is the deliverable;
no customer-side configuration or editor extension change is required.
