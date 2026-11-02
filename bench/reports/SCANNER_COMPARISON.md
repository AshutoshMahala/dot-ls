> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

# Scalar and block scanner comparison

Historical experiment. The current server configuration and allocation results
are in [ALLOCATOR_EXPERIMENTS.md](ALLOCATOR_EXPERIMENTS.md). Its local count-only
session patch avoids the retained syntax pools measured in the session experiment.

Measured on 2026-10-14 with Zig 0.16.0, ReleaseSafe, native arm64 macOS.
The parser revision is the unchanged vendored `9ea41c81` (0.5.0).
Only temporary builds used block; the normal checkpoint still uses scalar.

## What the library reports

The dot-parser 0.5.0 performance report, measured at revision `2ea1311`, says
scalar is generally faster for end-to-end parsing. Block is useful on long
runs and very small metered budgets. Its ReleaseSafe results include:

| Test | Scalar | Block |
| --- | ---: | ---: |
| 2.733 MB parse and validate, growing arena | 8.91 ms / 306.8 MB/s | 10.06 ms / 271.7 MB/s |
| Same, exact size hints | 7.36 ms / 371.4 MB/s | 8.42 ms / 324.6 MB/s |
| 0.400 MB repeated edges, fixed-buffer policy benchmark | 1.667 ms / 240.0 MB/s | 2.003 ms / 199.7 MB/s |

Those are different workloads and operations from this server's cancellable
count-only syntax path. They do not guarantee a specific time for a 40 MB file.
The documented lexer states are 64 bytes for scalar and 152 bytes for block in
ReleaseSafe on the library's reference machine.

## Matched parser-only test

The fixture is 39,999,996 bytes. The edge case repeats `a -> b;` about 5 million
times. The long-comment case puts almost all bytes inside one block comment.
Neither retains an AST. Cancellation uses the same never-set atomic flag.

Two warm-up rounds precede eight measured rounds. Variant order rotates each
round. Both sources must parse successfully with no diagnostics.

| Fixture | Cancellation | Scalar median | Block median | Block change |
| --- | --- | ---: | ---: | ---: |
| Short edges | off | 145.91 ms | 193.76 ms | 32.8% more time |
| Short edges | on | 239.83 ms | 223.86 ms | 6.7% less time |
| One long comment | off | 18.25 ms | 15.03 ms | 17.6% less time |
| One long comment | on | 108.51 ms | 15.25 ms | 85.9% less time (7.1x throughput) |

With cancellation on, block changes the balance by reducing scanner microsteps
and therefore polling work on long runs. Grammar transitions still cost work;
block does not remove the grammar cost of millions of short statements.

Raw data is in `profile-scanners.jsonl`. The control is `tools/scanner_bench.zig`.

## Full LSP comparison

Both temporary profiling servers use cancellation, full sync, the same JSON
decoder, and the same 40 MB edge fixture. Five requests per server:

| Stage | Scalar median | Block median |
| --- | ---: | ---: |
| JSON decoding | 73.16 ms | 72.95 ms |
| Snapshot allocation and copy | 2.80 ms | 2.80 ms |
| Parser stage | 265.03 ms | 222.04 ms |
| Client request to diagnostics | 412.87 ms | 370.40 ms |

The observed full-LSP gain is about 10.3%. These are sequential local samples,
not a confidence interval or a promise for every DOT file. Parser-only controls
and worker-stage timings are separate measurements with different code and
source/cache states; do not treat their absolute differences as isolated costs.

The uninstrumented temporary block server passed the protocol suite, including
position encodings, repair, cancellation/burst edits, limits, close/reopen, and
shutdown. Its executable is 638,392 bytes versus 620,696 for scalar: 17,696 extra
bytes. No new external dependency is used.

Changing scanner does not fix the JSON arena's temporary memory cost. Both
scanner variants use count-only parsing with no AST allocation for these flat
fixtures. Scanner state adds only tens of bytes, not source-sized storage.

## Reproduce

`tools/prepare_profile.py` creates a temporary tree with `scanner-profile` as
an additional executable. Build it in ReleaseSafe and run it with no other
builds or benchmarks active. Output is JSON Lines. To profile the full server,
set `.scanner = .block` in the temporary `src/analysis.zig` profile, leave
`src/pause.zig` false, rebuild, and run `tools/run_profile.py` from the project
root. `DOTLS_PROFILE_LABEL` gives its result file a distinct prefix.

Block is promising for this cancellable checkpoint. Choosing it as the general
default needs broader generated, nested, invalid, and label-heavy inputs plus
cancellation-latency checks. This experiment does not change the normal default.
