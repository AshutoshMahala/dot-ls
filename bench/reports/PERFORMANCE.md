> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

For the current diagnostics-first index, see [index construction profiling](INDEX_OPTIMIZATION.md).

# Local checkpoint measurements

For the current node-reference increment, see [reference memory and performance](REFERENCES_PERFORMANCE.md).

**Parser configuration:** block/vector, metering, cancellation, and count-only
sessions with bounded JSON request storage. See
[the current allocator results](ALLOCATOR_EXPERIMENTS.md). The earlier sections
below are historical measurements of the first scalar/unmetered checkpoint.

Measured on 2026-10-14, on an arm64 macOS 27.0.1 host.
Build: Zig 0.16.0, ReleaseSafe, native target. These are development samples,
not release gates or measurements of Graphviz validation.

| Measurement | Result |
| --- | ---: |
| Executable size | 620,696 bytes |
| Warm launch to initialize response, median of 15 runs | 2.24 ms |
| Warm launch to initialize response, slowest sample | 2.63 ms |
| Full-sync edit to diagnostics, 800,012-byte file, median of 10 runs | 8.09 ms |
| Same edit test, slowest sample | 9.16 ms |
| Idle RSS after initialize | 2,113,536 bytes |
| Sampled peak RSS, 4,400,012-byte document and 10 edits | 14,368,768–18,907,136 bytes across two runs |
| RSS after document close | 2,277,376 bytes |

The startup script includes Python process creation and client-send time. The
launches are warm; filesystem cold-start behaviour was not tested separately.
The edit test includes client JSON serialization and pipe transfer. Its generated
source repeats `a -> b;`; it is not the release acceptance corpus.

Memory is sampled with `ps` while a separate thread sends edits. Sampling can
miss short peaks, and running `ps` affects timing. Memory and latency tests run
separately. RSS includes framed JSON, decoded strings, immutable job copies,
parser scratch, the worker stack, and runtime overhead. It is not a measurement
of allocator-owned bytes alone. No AST is retained in this checkpoint.

Reproduce with:

```sh
python3 tests/lsp.py
python3 tests/bench.py
```

Protocol acceptance checks and the real Neovim smoke test passed. Unit tests
passed in Debug and ReleaseSafe. Vendored parser files were compared byte for
byte with the pinned Git commit. Zed and VS Code were not tested.

## Large files

Additional measurements on the same host and ReleaseSafe build:

| Source size | End-to-end time, three runs | Median | Time after the client finishes writing |
| --- | --- | --- | --- |
| 40,000,000 bytes (approximately) | 407–440 ms | 439 ms | 347–368 ms |
| 100,000,000 bytes (approximately) | 1,039–1,069 ms | 1,049 ms | 864–899 ms |

These valid files repeat `a -> b;` and contain about 5 million and 12.5 million
edge statements. Results do not cover malformed files, HTML labels, or semantic
validation. End-to-end time includes client serialization, pipe transfer, server
JSON decoding, source copying, and cancellable count-only syntax parsing.
Client serialization alone took 51–64 ms at 40 MB and 143–151 ms at 100 MB.
Newlines are escaped in JSON, so framed payloads were about 45 MB and 112.5 MB.

At the time of these measurements, the normal build accepted at most 64 MiB
of source and 80 MiB per message. Current limits are 200 MiB of source and
256 MiB per message. The
100 MB test used a temporary source copy with limits of 128 MiB per source,
160 MiB per message, and 256 MiB of active/pending source. The normal project
and binary limits were not changed. It is an experimental measurement, not a
claim that the normal build supports 100 MB.

`tests/large_bench.py` reproduces the 40 MB test. Its `DOTLS_BENCH_BYTES`
environment variable selects a size; its optional first argument selects a
binary. A larger size requires a separately built binary with suitable limits.

A 40 MB run sampled 1,998,848 bytes RSS before initialization and 2,113,536
afterward. After analysis/close it was about 2.3 MB. These are whole-process
resident pages, not live application heap accounting. The large-file script
samples memory between analyses, so it does not report peak processing memory.

## Detailed stage and memory profile

See [the 40 MB profile](PROFILE_40MB.md). Stage-boundary sampling found about
160 MB RSS during snapshot copying and about 217 MB of live requested allocation
capacity. The earlier sparse RSS samples are not reliable peak-memory bounds.
Most of that temporary memory belongs to framed JSON, decoding, and the snapshot
copy; this fixture needs no parser heap or retained AST.

The [scanner comparison](SCANNER_COMPARISON.md) measures scalar and block with
matched cancellation settings. Block reduced local 40 MB full-sync latency by
about 10%, while scalar remained faster in the parser-only edge test with
cancellation compiled out.

The [metered-session experiment](METERED_SESSIONS.md) measures retained parsing,
pause/resume quanta, and fixed-pool memory. Scalar metering without a per-step
hook takes about 200 ms at 4,096 credits per call on the 40 MB edge fixture.
The retained session needs 220 MB of syntax pools, so it is not a memory-equivalent
replacement for the current count-only server path.
