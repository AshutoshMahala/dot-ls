> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

# Diagnostics and keyword completion: performance

Measured on 2026-10-14 on the same host, with ReleaseSafe builds, the page
allocator, buffered JSON intake, and the existing metered/cancellable scanner.
The parser configuration did not change. MB below means decimal MB.

## Large documents

Each binary ran in a fresh process for each file size. The client prepared JSON
before timing. Each run opened the valid file, then sent three full-text error
and repair pairs. Error and repair times are medians of three samples. Times
include transport, JSON intake, analysis and diagnostic publication. Peak RSS is
macOS `/usr/bin/time -l` maximum resident set size for the server process, not a
sampled estimate. Editor memory and rendering time are excluded.

| File | Error before → after | Repair before → after | Peak RSS before → after |
| --- | --- | --- | --- |
| 5 MB | 22.02 → 22.35 ms | 18.54 → 19.37 ms | 17,661,952 → 17,711,104 B |
| 20 MB | 84.02 → 87.93 ms | 74.07 → 75.00 ms | 63,569,920 → 63,619,072 B |
| 40 MB | 171.24 → 175.07 ms | 152.07 → 158.01 ms | 124,796,928 → 124,846,080 B |

Peak RSS increased by 48 KiB in each run. Idle RSS before the first document
increased from 2,097,152 to 2,129,920 bytes (32 KiB). The small timing differences
need more samples before they can establish a regression. These measurements
cover one error at a time. They do not represent the maximum diagnostic load.

Keyword completion took a median 0.046, 0.042 and 0.037 ms on the three sizes,
from 20 requests per size after parsing. The response contains six static items.
It has no document-size-dependent lookup. These are protocol round trips, not
editor popup times. No AST or source cache was added for completion.

## Maximum diagnostic count

A separate 8,412-byte input produces 1,000 parser diagnostics plus the incomplete
analysis notice. Across five document versions, median response time changed
from 1.595 to 1.922 ms. Peak RSS changed from 2,719,744 to 3,080,192 bytes, an
increase of 352 KiB. Richer message storage and larger JSON output have a visible
cost at this cap. Message storage is released after publication or cancellation.

## Startup and binary size

Fifteen direct warm starts per binary measured process creation through LSP
initialization. Median startup changed from 2.453 to 2.338 ms. This does not show
a startup regression. It does not measure a cold filesystem cache or Zed startup.
The large-file raw records also contain startup fields from the time wrapper;
the first copied baseline binary had a cold start. Do not compare those fields
as a feature startup cost.

The executable grew from 638,456 to 659,592 bytes: 21,136 bytes, or 3.3%.
The compatibility executable is a second installed copy of the same binary.

## Validation and reproduction

Debug and ReleaseSafe unit checks passed. Protocol checks passed with the normal
and debug allocators. Neovim checks passed for diagnostics, repair and completion.
Zed loaded the canonical executable after restarting its language server; typing
`di` and requesting completion showed `digraph` with its detail text. The same
buffer showed the new expected/found diagnostic. The dev extension keeps the
`dotls` adapter ID for compatibility.

Run `python3 tools/feature_bench.py before PATH_TO_BASELINE`, then run it with
`after PATH_TO_NEW_BINARY`. Run `python3 tools/diagnostic_load_bench.py
PATH_TO_BASELINE PATH_TO_NEW_BINARY` for the cap and warm-start measurements.
Keep the binaries and parser/build settings fixed when comparing increments.

Raw records: [before](../results/legacy/features-before.json), [after](../results/legacy/features-after.json), and
[diagnostic load and startup](../results/legacy/features-diagnostic-load.json). These tools retain
raw samples so later increments can use the same procedure.
