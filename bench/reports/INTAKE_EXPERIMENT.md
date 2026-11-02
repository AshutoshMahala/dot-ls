> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

# Source-copy removal experiment

Measured on 2026-10-14 with Zig 0.16.0, ReleaseSafe, native arm64 macOS.
Both builds use page allocation, block scanning, 4,096-credit metering,
per-step cancellation, and count-only syntax analysis. No external dependency
was added. MB means 1,000,000 bytes.

## Result

The experiment removes both source-sized allocations from message intake.
The incoming packet is decoded in place and becomes the worker's source owner.
The default remains the buffered path. Select the experiment with
`-Djson-storage=inplace`; it is not an editor setting.

| Workload / measure | Before: buffered JSON + source copy | In-place packet owner | Change |
| --- | ---: | ---: | ---: |
| 40 MB repeated edges: median request latency | 311.02 ms | 293.41 ms | 5.7% lower |
| 40 MB long comment: median request latency | 58.69 ms | 50.46 ms | 14.0% lower |
| Repeated edges, valid: actual peak RSS | 127.34 MB | 47.42 MB | 62.8% lower |
| Repeated edges, one syntax error: actual peak RSS | 127.34 MB | 85.10 MB | 33.2% lower |
| Executable size | 638,488 bytes | 638,104 bytes | 384 bytes smaller |

The edge source is 39,999,996 bytes; its JSON request is about 45 MB because of
escaped newlines. The error fixture adds one byte near the end. The comment
source is 39,999,998 bytes with no source-string escapes. These are synthetic
fixtures; the percentages are not promises for every DOT document.

Latency uses ten requests per variant: two fresh processes with five requests
each, and reverse variant order on the second pass. Payloads are encoded before
timing. The interval starts before writing and ends at diagnostic receipt.
No builds, RSS sampling, or instrumented servers ran during the final timing
comparison. Min/max and all samples are saved in the raw reports.

Actual peak RSS comes from macOS `/usr/bin/time -l` on uninstrumented binaries,
one fresh process per variant and fixture. It covers startup through shutdown.
It includes short allocation overlaps that paused stage sampling can miss.
This run reports one peak per case, not a distribution across repeated trials.

## Where memory went

Paused stage measurements identify live buffers. They are separate from the
actual high-water measurements above and change thread overlap.

| Stage | Before RSS | In-place RSS | In-place ownership |
| --- | ---: | ---: | --- |
| Idle | 2.13 MB | 2.13 MB | Process only |
| Packet read | 47.14 MB | 47.14 MB | Incoming 45 MB packet |
| JSON decoded | 87.15 MB | 47.17 MB | Same packet + about 4.2 KB metadata capacity |
| Source ready for worker | 127.21 MB | 47.22 MB | Transfer packet; allocate no snapshot |
| During analysis after intake cleanup | 42.40 MB | 47.37 MB | Worker retains packet until done |
| Valid job released | 2.36 MB | 2.33 MB | Source storage released |

Before: packet + decoded string + source copy overlap at intake. The JSON region
reserves about 90 MB and consumes about 40 MB. Total peak requested backing
capacity is about 175 MB, while resident memory is about 127 MB.
After: peak tracked live heap capacity is about 45 MB for the valid fixture.
There is no 90 MB JSON backing region and no 40 MB worker snapshot allocation.
Escaped bytes are compacted inside already consumed packet space.
Plain strings borrow their validated span without a same-buffer copy.

There is a tradeoff: during analysis the experiment retains the entire 45 MB
packet, rather than the old 40 MB snapshot. This increases that stage by about
5 MB. It still removes about 80 MB from the intake peak. A packet containing
other large fields or multiple full changes retains those bytes until the job
ends. The active/pending memory limit now counts the full retained allocation,
not just the selected source length. At measurement time, the decoded-file limit was 64 MiB. It has since been
raised to 200 MiB, with a 256 MiB message limit and 512 MiB combined job budget.

The parser still allocates zero heap for these fixtures. In separate unpaused
stage runs, JSON decode fell from 71.46 to 62.92 ms; the 2.90 ms source copy was
removed. Parser times were 222.17 and 220.70 ms; this small difference does not
show a parser change. These stage runs are supplementary measurements, not
components to subtract from the ten-sample comparison as if from one request.

## Remaining diagnostic peak

With an error near the end, the line index retains 22.63 MB for about five
million line offsets. Its growth briefly overlaps old and new allocations,
reaching 37.72 MB of requested index storage. The in-place packet remains live:
about 45 MB packet + 37.72 MB transient index storage + process overhead explains
the actual 85.10 MB peak. The stable line-index checkpoint is only 70.01 MB RSS.
This is why reporting only that checkpoint would understate the new peak.
The index algorithm was not changed in this experiment.

## Ownership and validation

The standard Zig JSON scanner still validates grammar, UTF-8, escape sequences,
and surrogate pairs. A small token-source adapter compacts decoded string
fragments into the mutable packet after the scanner consumes them. Numbers and
container construction continue through the standard JSON APIs. This is a
specialized adapter for `std.json.Value`'s leaky parser: allocated-string tokens
have packet lifetime and must not be individually freed. The adapter must not
be reused with a parser that frees tokens. A future Zig upgrade needs these
assumptions checked again.

JSON metadata has a stable arena owner. URI/job metadata is copied before the
packet transfers. Transfer occurs only after all fallible job setup succeeds.
A skipped/rejected/failed message keeps packet ownership on the protocol side.
An accepted job frees its exact packet allocation on completion, cancellation,
pending replacement, close, or shutdown. JSON metadata teardown does not read
the borrowed string views, so it can safely release metadata after transfer.

Checks passed:

- Debug and ReleaseSafe unit checks, including allocator failure injection.
- Differential JSON checks against the standard decoder, every truncation of
  the fixtures, Unicode/surrogates, invalid UTF-8, malformed input, duplicate
  keys, and all ASCII string bytes.
- Protocol suite with the normal path and experimental debug-allocator build:
  escaped keys/text, multi-change packets, rapid replacements, multi-document
  work, close/reopen, EOF and shutdown. No debug-allocator leak report.
- Real Neovim attach, diagnostics, repair and shutdown with the experimental
  page-allocator server.

## Reproduce and raw records

Build the two paths into separate output directories with Zig 0.16.0:

```sh
zig build -Doptimize=ReleaseSafe -Djson-storage=buffer --prefix /tmp/dotls-before
zig build -Doptimize=ReleaseSafe -Djson-storage=inplace --prefix /tmp/dotls-inplace
python3 tools/intake_compare.py /tmp/dotls-before/bin/dotls /tmp/dotls-inplace/bin/dotls
DOTLS_INTAKE_WORKLOAD=comment python3 tools/intake_compare.py /tmp/dotls-before/bin/dotls /tmp/dotls-inplace/bin/dotls
python3 tools/intake_peak.py /tmp/dotls-before/bin/dotls /tmp/dotls-inplace/bin/dotls
```

The recorded before build used a preserved source copy from before the ownership
change; the buffer build option retains that decode/copy strategy for comparison.
Exact measured binary hashes and sizes are in `intake-binaries.json`.
The temporary profiler is created by `tools/prepare_profile.py`; enable its
`src/pause.zig` only for memory stage runs. Memory runs deliberately pause;
do not use their latency numbers. Normal binaries contain no profile hooks.

Raw data:

- `intake-comparison.json`, `intake-comparison-comment.json`: final timings.
- `intake-peak-memory.json`: actual peaks and full macOS time output.
- `profile-intake-before-timing.json`, `profile-intake-inplace-timing.json`:
  separate unpaused stage timings.
- `profile-stages-valid-memory.json`, `profile-stages-error-memory.json`:
  before stage records.
- `profile-intake-inplace-memory.json`, `profile-intake-inplace-error-memory.json`:
  after stage records and corresponding idle mapping files.

This experiment covers single full-sync requests and protocol ownership checks.
It does not establish memory peaks for concurrent large documents, large edit
bursts, or metadata-heavy messages. Keep those separate from this result.
