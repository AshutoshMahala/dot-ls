> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

# Allocator experiment and selected configuration

Measured on 2026-10-14 with Zig 0.16.0, ReleaseSafe, native arm64 macOS.
All candidates use block scanning, metering, per-step atomic cancellation,
and count-only sessions. The source is the same 39,999,996-byte edge fixture.
No AST is allocated.

See [Memory by processing stage](MEMORY_STAGES.md) for the current buffer-lifetime
breakdown, including the diagnostic line-index path.

## Selected defaults

- `std.heap.page_allocator` for process-owned heap resources.
- One fixed backing region for each decoded JSON request.
- 4,096-credit block-scanner pumps with cancellation enabled.
- Caller-owned 256-frame nesting scratch; no parser heap or syntax pools.

SMP did not show a dependable speed benefit on this workload, and retained
more idle memory. The debug allocator is useful for allocation/ownership tests,
but is not selected for the normal binary. It is Zig 0.16's general-purpose
debug allocator; it is not a performance-oriented GPA baseline.

Build-time experiment flags, not editor settings:

```sh
zig build -Doptimize=ReleaseSafe -Dallocator=page -Djson-storage=buffer
zig build -Doptimize=ReleaseSafe -Dallocator=smp -Djson-storage=arena
zig build -Doptimize=ReleaseSafe -Dallocator=debug -Djson-storage=buffer
```

## Allocator matrix

Two passes run in opposite orders. Each process receives four identical
pre-encoded full-sync requests. The medians below contain eight samples.
They start before pipe writing, and exclude client JSON encoding. Memory
sampling runs separately and can miss short peaks.

| Backing allocator | JSON storage | Median request | Idle RSS | RSS after close |
| --- | --- | ---: | ---: | ---: |
| Page | Arena | 305.3 ms | 2.08 MB | 2.29 MB |
| Page | Request buffer | 305.3 ms | 2.10 MB | 2.28 MB |
| SMP | Arena | 305.0 ms | 2.29 MB | 2.67 MB |
| SMP | Request buffer | 301.8 ms | 2.24 MB | 2.57 MB |
| Debug | Arena | 303.5 ms | 2.13 MB | 2.36 MB |
| Debug | Request buffer | 299.8 ms | 2.13 MB | 2.34 MB |

These small timing differences are not enough to rank the backing allocators
confidently. The reason to select the request buffer is lower temporary memory,
not a claimed large speed gain. Raw samples, including ranges and sparse RSS
peaks, are in `allocator-comparison.json`.

## JSON lifetime storage

The old decoder's arena retains intermediate buffers as an escaped string
grows. The new request buffer gives that string room to grow in place. Its
capacity is twice the packet length plus 16 KiB. This is a conservative fast-path
budget, not an exact prediction of decoded metadata size.

Metadata-heavy messages can exceed that budget. The owner releases the region
and retries the original immutable packet with the standard arena decoder.
No partially decoded value escapes. Tests cover successful decoding, Unicode
escapes, arrays, fallback, malformed input, and allocation failure.

The region uses checked `rawAlloc`/`rawFree` with the same extent and alignment.
It is uninitialized backing capacity; the JSON parser initializes the portions
it uses, and unused capacity is never read. This avoids ReleaseSafe poisoning
of the whole spare region on allocation/free. Bounds and runtime safety checks
remain enabled. The message owner must stay at a stable address while managed
JSON containers borrow its allocator context.

Early candidates were rejected: a packet-sized region filled during geometric
string growth and paid for a second decode. Ordinary allocation of a twice-sized
region touched unused capacity through undefined-memory poisoning and raised
RSS. The selected backing-region implementation avoids both costs.

## Final selected profile

Five profiled requests give these medians:

| Stage | Time |
| --- | ---: |
| Server body read | 6.57 ms |
| JSON decode | 69.81 ms |
| Snapshot allocation/copy | 3.37 ms |
| Count-only block/metered/cancellable parser | 216.80 ms |
| Full request, including Python encoding | 360.23 ms |

The independent uninstrumented matrix above measures about 305 ms after the
payload has been pre-encoded. Do not subtract medians from different runs to
claim exact client or scheduler overhead. Transfer and cleanup can overlap.

A paused memory run gives about **127.2 MB RSS** at snapshot copying, versus
about **159.9 MB** in the earlier arena profile. Requested live capacity falls
from about **217.4 MB to 175.0 MB**. Those totals include 45 MB framed input,
90 MB request-buffer capacity, and a 40 MB snapshot. Capacity and resident pages
are different metrics. At parser completion, input/JSON have been released,
and RSS is about 42.4 MB, mostly the source. No parser heap allocation is needed.
The fixed diagnostic bag and nesting scratch use about 80 KB and 30 KB of stack.

The paused run establishes stage memory, not valid timings. Its timestamps
include deliberate waits and sampler interference. Raw selected-profile files:

- `profile-metered-buffer-timing.json`
- `profile-metered-buffer-memory.json`
- `profile-metered-buffer-idle-vmmap.txt`

## Reproduce

Build the six combinations of `page`, `smp`, `debug` with `arena`, `buffer`,
using prefixes `/private/tmp/dotls-allocator-NAME-STORAGE`. Then run:

```sh
python3 tools/allocator_compare.py
```

Do not run builds, tests, or other benchmarks during the comparison. The script
uses `ps` for RSS. `tools/prepare_profile.py` and `tools/run_profile.py` provide
separate stage-timing and paused-memory builds. No profiling code is imported
by the normal executable.

## Verification

The selected default passes Debug and ReleaseSafe unit tests, the vendored
parser regression tests, the scripted LSP suite, and the real Neovim smoke test.
The debug-allocator buffer build also passes the protocol suite without a leak
report. Differential tests cover both scanners, budgets of 1/17/4,096, every
truncation of a nested fixture, terminal cancellation, sink stops, scratch
exhaustion, and runtime reset. The local patch passes a reverse-apply dry check.

The final normal executable is 638,456 bytes. A later protocol-suite sample
measures about 2.09 ms warm startup and 7.12 ms for an 800 KB edit. These are
local samples, not release-wide performance guarantees.
