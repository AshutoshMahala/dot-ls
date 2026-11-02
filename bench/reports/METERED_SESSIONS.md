> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

# Metered-session experiment

Historical experiment. The current server configuration and allocation results
are in [ALLOCATOR_EXPERIMENTS.md](ALLOCATOR_EXPERIMENTS.md). Its local count-only
session patch avoids the retained syntax pools measured in the session experiment.

Measured on 2026-10-14 with Zig 0.16.0, ReleaseSafe, native arm64 macOS and
vendored dot-parser 0.5.0 revision `9ea41c81`. The normal server is unchanged.

The source is 39,999,996 bytes, with 4,999,998 occurrences of `a -> b;`.
This experiment uses the public fixed-storage session API. Unlike the current
server's count-only path, it retains a syntax document.

## Total parsing time

All rows do the same retained parsing into the same preallocated pools. Each
mode has two warm-up rounds and three timed rounds, with order rotated. Source
construction, pool allocation, session initialization, output, and cleanup are
outside the timer. Times include each `advance()` call and the pump loop.

Medians, in milliseconds:

| Mode | Budget | Scalar | Block |
| --- | ---: | ---: | ---: |
| Run to completion, no cancellation hook | — | 162.71 | 214.47 |
| Run to completion, atomic cancellation hook | — | 255.67 | 236.59 |
| Metered, no per-step hook | 256 | 196.85 | 247.01 |
| Metered, atomic per-step hook | 256 | 284.55 | 242.10 |
| Metered, no per-step hook | 4,096 | 199.56 | 245.49 |
| Metered, atomic per-step hook | 4,096 | 281.46 | 239.53 |
| Metered, no per-step hook | 65,536 | 194.85 | 244.77 |
| Metered, atomic per-step hook | 65,536 | 282.88 | 240.91 |

With a 4,096-credit budget, metering without a per-step hook adds about 23% to
the scalar retained baseline. It is still faster than the scalar run-to-completion
variant with an atomic hook. The small block differences between hook on/off
are not dependable improvements; compilation layout and local noise can matter.

The no-hook loop does not poll an external request flag in this benchmark. A
server using it would check for new work/cancellation between calls and invoke
`session.cancel()` when needed. That scheduler cost is not included here.

Do not compare these numbers directly with the earlier count-only measurements
to isolate metering cost: retaining millions of records is additional work.

## Pause, resume, and cancellation

All metered modes repeatedly yield and resume, and must produce a successful
document with exactly 4,999,998 statements and no diagnostics. A separate
quantum test checks that `work_used` never exceeds the supplied budget. It then
cancels a paused session and checks that the terminal result is `.cancelled`
and exposes no document.

Each quantum row samples 256 calls on the source prefix, with no per-step hook:

| Budget | Scalar p95 per call | Block p95 per call |
| --- | ---: | ---: |
| 256 | 0.708 microseconds | 1.333 microseconds |
| 4,096 | 10.791 microseconds | 21.208 microseconds |
| 65,536 | 172.542 microseconds | 328.792 microseconds |

The largest observed call is about 0.189 ms for scalar and 0.359 ms for block
at 65,536 credits. Cancelling between calls takes less than one microsecond
in these samples. Those very small timings are near clock-resolution limits.

Credits are work units, not bytes or time. Scalar uses 79,999,988 credits for
this full input, and block uses 51,249,990. At 4,096 credits, that means 19,532
scalar calls or 12,513 block calls. Equal budgets do not mean equal source
progress or equal wall time.

These measurements establish pause/resume for this fixture. They do not establish
a universal 5 ms server cancellation bound, callback latency, or bounded JSON
processing and validation. No real scheduling waits are inserted between pumps.

## Memory

| Storage | Bytes |
| --- | ---: |
| Borrowed source | 39,999,996 |
| Fixed statement-ID pool (8 bytes per statement) | 39,999,984 |
| Fixed edge pool (36 bytes per edge) | 179,999,928 |
| Diagnostic bag | 80,016 |
| Metered scalar session, no hook / hook | 1,168 / 1,192 |
| Metered block session, no hook / hook | 1,256 / 1,280 |

The pools total **219,999,912 bytes**, and are allocated once before timing.
They do not grow or allocate during parsing. Every round reuses them only after
its preceding session/document is finished. `time -l` reports **262,307,840
bytes peak RSS** and **261,653,008 bytes peak physical footprint**. This process
contains no LSP JSON buffers or decoder arena.

Most memory comes from retaining five million syntax statements, not from the
metered driver's roughly 1.2 KB state. The current diagnostics-only server does
not retain those statements. The public API supplies retained sessions and
one-shot count-only measurement; a resumable count-only path is not currently
exposed. Such an upstream API would let us evaluate bounded scheduling without
requiring this syntax pool for the first checkpoint.

## Reproduce

```sh
python3 tools/prepare_session.py
# In the temporary folder printed above:
zig build -Doptimize=ReleaseSafe
/usr/bin/time -l zig-out/bin/session-profile
```

Run with no other builds or benchmarks active. The source generator and all
profile choices are in `tools/session_bench.zig`. Raw results are in
`profile-sessions.jsonl` and `profile-sessions-resource.txt`.
