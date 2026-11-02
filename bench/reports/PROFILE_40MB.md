> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

# 40 MB checkpoint profile

Historical experiment. The current server configuration and allocation results
are in [ALLOCATOR_EXPERIMENTS.md](ALLOCATOR_EXPERIMENTS.md). Its local count-only
session patch avoids the retained syntax pools measured in the session experiment.

Measured on 2026-10-14 with Zig 0.16.0, ReleaseSafe, native arm64 macOS.
The fixture is 39,999,996 bytes of valid DOT, with about 5 million occurrences
of `a -> b;`. This measures syntax checking only, not retained AST construction,
HTML-label validation, graph resolution, or rendering.

The normal server source and executable were not instrumented. A temporary
source copy used timestamp probes and category-specific wrappers around the same
page allocator. The wrappers count requested allocation sizes and capacities.
They do not equate virtual allocation capacity with resident physical pages.

## Time

Five full-sync requests produced these medians:

| Stage | Median |
| --- | ---: |
| Client JSON serialization | 59.33 ms |
| Client pipe write | 9.31 ms |
| Server body read | 6.49 ms |
| Server JSON decoding | 73.19 ms |
| Immutable source copy | 2.87 ms |
| Worker queue delay | 0.009 ms |
| dot-parser count-only syntax analysis, cancellation enabled | 279.48 ms |
| Diagnostic conversion | below 0.001 ms (no diagnostics) |
| Response JSON encoding | 0.007 ms |
| Response pipe write | 0.001 ms |
| End-to-end request | 425.86 ms |

Client pipe writing and server body reading overlap. Do not add both to an
end-to-end total. JSON/input cleanup takes about 0.83/0.68 ms and can overlap
worker parsing. Medians of individual stages do not sum to a median request.
Header parsing, allocation, thread startup, probe overhead, and scheduling also
contribute to the remainder. These probes use wall time, not CPU time.

The payload is about 45 MB because JSON escapes the source's newlines. The JSON
stage includes escape decoding, generic value construction, and arena growth.
The copy stage measures allocation plus copying the decoded source into its job.

An independent parser-only control used the same source and limits. Six
interleaved pairs gave:

| Parser configuration | Median |
| --- | ---: |
| Cancellable count-only parsing with the atomic hook | 250.83 ms |
| Count-only parsing with cancellation compiled out | 151.06 ms |

The hook-enabled control is about 66% slower. This isolates the compile-time
cancellation variant and its polling overhead, not just one atomic load. The
current hook is polled before parser microsteps. The 279 ms integrated result
also includes concurrent activity and source/cache state; it should not be
subtracted directly from the 151 ms control to isolate hook cost.

Raw results: `profile-timing.json` and `profile-parser-only.jsonl`.

## Memory during a request

A separate memory build pauses for 300 ms at selected boundaries. Those pauses
make sampling possible but invalidate its timing results. It gave:

| Stage | Requested live allocations | Process RSS |
| --- | ---: | ---: |
| Idle after initialize | small; 32 bytes in the instrumented application allocator at the last lifecycle trace | 2.15 MB |
| Body read | 45.0 MB framed input | 47.1 MB |
| JSON decoded | 45.0 MB input + 132.4 MB JSON arena | 119.8 MB |
| Snapshot copied | above + 40.0 MB source | 159.9 MB |
| Parser finished | 40.0 MB source; JSON and input released | 42.3 MB |

Tracked peak requested live allocation is about **217.4 MB**. The largest
observed stage RSS is about **159.9 MB**. The JSON arena's capacity includes
unused room and earlier string-growth buffers, so it is larger than its
resident, touched data. These figures exclude the Python client's memory.

For this flat source, dot-parser makes **zero heap allocations**. The fixed
1,000-entry diagnostic bag occupies **80,016 bytes** on the worker stack.
No line index is built because there are no diagnostics. Nested or invalid
sources can require parser scratch, position indexes, and result allocations;
zero parser heap usage is not a claim for every input.

The source exists in three forms at the copy boundary: escaped JSON bytes,
JSON-decoded string storage, and immutable job text. The JSON arena also holds
intermediate growth buffers. This is a protocol-decoder cost, not an AST cost.

Raw results: `profile-memory.json`.

## Idle process memory

`vmmap -summary` on the idle instrumented process reports a physical footprint
of **1,360 KiB**, while a nearby `ps` sample reports about **2.15 MB RSS**.
These are different accounting measures. Selected resident region categories:

| Category | Resident size |
| --- | ---: |
| Malloc metadata and metadata bookkeeping | 512 KiB |
| Malloc small and tiny regions | 96 KiB |
| Main stack | 48 KiB |
| Untagged mappings | 36 KiB |
| Writable library/executable data | additional pages; see raw map |
| Kernel page tables | 240 KiB, separately reported by vmmap |

This is not an additive reconciliation to RSS. `vmmap` also lists large shared
system-cache mappings. Their virtual or shared-resident sizes are not private
memory owned by dotls. The executable links to macOS `libSystem.B.dylib`.

The application allocator counter does not cover process initialization,
platform malloc, runtime-managed allocations, executable mappings, or stacks.
The two protocol I/O buffers occupy 16 KiB on the main stack. The analysis worker
has not started at this idle point, and no AST or document is retained.

Raw map: `profile-idle-vmmap.txt`. It is a region breakdown, not allocation
call-stack attribution. Establishing who made each platform allocation requires
an allocation-stack profiler.

## Reproduce

```sh
python3 tools/prepare_profile.py
# Use the temporary path printed above:
cd /private/tmp/dotls-profile-EXAMPLE
zig build -Doptimize=ReleaseSafe
# Run from the project root:
python3 tools/run_profile.py /private/tmp/dotls-profile-EXAMPLE/zig-out/bin/dotls timing
/private/tmp/dotls-profile-EXAMPLE/zig-out/bin/parser-profile
```

For memory sampling, change the temporary `src/pause.zig` to
`pub const enabled = true;`, rebuild it, and run `run_profile.py` with `memory`.
That mode needs permission to run `ps` and `vmmap`. Do not use its timings.
The profiling code is not imported by the normal build.

The evidence points to two priorities for later optimization: control JSON
string allocation/growth, and reduce cancellation polling cost while preserving
measured responsiveness. No such optimization was applied in this profile.
