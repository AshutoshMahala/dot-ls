> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

# Memory by processing stage

Measured on 2026-10-14. Zig 0.16.0, ReleaseSafe, native arm64 macOS.
Defaults: page allocator, buffered JSON, block scanner, metering and cancellation.
All MB values use 1,000,000 bytes. RSS covers the server process only.

See [Source-copy removal experiment](INTAKE_EXPERIMENT.md) for the subsequent
optional in-place path and before/after measurements. This page describes the
buffered default.

## Main finding

The 127.21 MB observed peak comes from overlapping message buffers.
It is not a parser tree or metering allocation. The 40 MB source exists as:

- A 45.00 MB JSON packet. Escaped newlines increase its size.
- A 40.00 MB decoded string in the JSON owner's backing region.
- A 40.00 MB worker-owned source snapshot.

These account for about 125 MB, plus about 2.2 MB of process overhead.
The snapshot is copied so the protocol thread can destroy the message while
an independent worker reads the source.

## Valid source: stage checkpoints

The source contains 39,999,996 bytes and about five million lines.
Each row is a checkpoint, not an additional allocation to sum with other rows.

| Stage | Packet capacity | JSON backing capacity | Worker source | Observed RSS |
| --- | ---: | ---: | ---: | ---: |
| Initialized, idle | — | — | — | 2.13 MB |
| Packet read | 45.00 MB | — | — | 47.14 MB |
| JSON decoded | 45.00 MB | 90.02 MB | — | 87.15 MB |
| Snapshot copied | 45.00 MB | 90.02 MB | 40.00 MB | 127.21 MB |
| JSON owner released | 45.00 MB | — | 40.00 MB | 87.41 MB |
| Packet released | — | — | 40.00 MB | 42.40 MB |
| Worker job released | — | — | — | 2.36 MB |

Only 40,002,164 bytes of the 90,016,682-byte JSON region were consumed by
its fixed allocator. Unused mapped capacity is not touched. Therefore the
175.02 MB peak requested backing capacity is larger than resident memory.
The extra 50 MB of capacity is not an extra 50 MB of measured RAM.
Allocator counters include this capacity; they do not measure physical pages.

The count-only parser adds zero heap bytes for this fixture. It reads the worker
snapshot. The fixed diagnostic bag and nesting scratch use about 80 KB and 30 KB
of stack. Stack use contributes to RSS and is not in heap allocation counters.
Valid input does not build the line index. Its diagnostics response allocates
122 bytes. Small document/job metadata uses hundreds of requested heap bytes;
page granularity and process overhead are reflected separately in RSS.
The source snapshot is released after analysis even while the document remains
open; the current full-sync checkpoint does not retain a document text cache.

## Diagnostic path

A second fixture adds an invalid `@` near the end. It has 39,999,997 bytes.
The intake peak is again 127.21 MB. After packet cleanup:

| Stage | Source | Line-index capacity | Observed RSS |
| --- | ---: | ---: | ---: |
| Before diagnostic conversion | 40.00 MB | — | 42.40 MB |
| Line index ready | 40.00 MB | 22.63 MB | 65.04 MB |
| Job released | — | — | 2.36 MB |

The index stores one `u32` offset per line. About five million lines need about
20 MB of entries; geometric growth leaves 22.63 MB of final capacity. Its tagged
allocator recorded a 37.72 MB peak while old and new allocations overlapped
during growth. That transient is an allocation measurement, not a sampled RSS
measurement. The index is freed before response publication. The response uses
314 bytes, and converted diagnostic metadata is small for this single error.
This shows why a valid-only benchmark misses a significant allocation path.

## Improvement priorities

1. Remove a full source copy from message intake. A dedicated text owner that
   can move to the worker could avoid the 40 MB snapshot copy. Transferring the
   entire 90 MB JSON region would retain unnecessary capacity and metadata.
2. Decode source directly into owned storage, or safely decode the packet in
   place. This requires a carefully tested JSON/ownership path. It could remove
   another source-sized temporary buffer. These are proposals, not implemented
   savings or performance promises.
3. Reduce line-index storage for diagnostics. A scan over sorted diagnostic
   offsets or a sparse index may avoid a full offset array. Measure latency and
   cancellation behavior before selecting an approach.

Changing the parser allocator is not the main lever for this workload: it owns
no heap here. Message ownership and diagnostic position conversion are the
useful targets.

## Method and limits

`tools/prepare_profile.py` creates a separate instrumented source copy. The
normal binary has no profiling code. Tagged allocator counters track requested
live capacity and transient allocation peaks. The JSON fixed allocator also
reports consumed capacity. RSS comes from `ps` at paused stage boundaries.

Enable `src/pause.zig` in that temporary copy and build with ReleaseSafe.
Run from the project directory, replacing `<profile-binary>` with its path:

```sh
env DOTLS_PROFILE_LABEL=stages-valid- python3 tools/run_profile.py <profile-binary> memory
env DOTLS_PROFILE_LABEL=stages-error- DOTLS_PROFILE_ERRORS=1 python3 tools/run_profile.py <profile-binary> memory
```

The profiler deliberately pauses threads at selected stages. These runs verify
memory ownership/lifetime and expose overlapping buffers; they do not measure
normal timing or establish an exact production high-water RSS. Thread pauses
change overlap: the parser checkpoint in these runs occurs while the protocol
thread still holds the packet. Raw event order records this. No continuous RSS
trace is claimed. Use the unpaused timing mode for latency comparisons.

Raw records: `profile-stages-valid-memory.json` and
`profile-stages-error-memory.json`. Idle memory mappings are saved with the
same prefixes. This covers one full-sync request and one active source.
Rapid replacements, multiple documents, metadata-heavy JSON fallback, and other
input shapes require separate peak measurements. Do not treat 3.18x as a fixed
memory multiplier for every workload.
