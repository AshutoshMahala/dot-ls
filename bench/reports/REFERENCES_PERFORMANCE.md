> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

# Initial node references: memory and performance

These measurements describe the first 20-byte index. See [index optimization](INDEX_OPTIMIZATION.md) for current diagnostics priority, compact ranges, and costs.

Measured on 2026-10-14 on the same arm64 macOS host. Both binaries use Zig 0.16.0,
ReleaseSafe, the page allocator, buffered JSON intake, and the same block/vector
scanner with metering and cancellation. The baseline is the preserved diagnostics
and keyword-completion build. No new library or runtime dependency was added.
MB means 1,000,000 bytes; MiB means 1,048,576 bytes.

## Latency

| File | Clean edit before → after | Error edit before → after | Reference lookup after |
| --- | --- | --- | --- |
| 5 MB | 18.4 → 28.5 ms | 21.1 → 27.1 ms | 0.09 ms |
| 20 MB | 75.0 → 120.8 ms | 83.5 → 119.2 ms | 0.23 ms |
| 40 MB | 150.2 → 249.5 ms | 173.3 → 243.0 ms | 0.43 ms |
| 100 MB | 376.6 → 651.1 ms | 435.9 → 621.0 ms | 1.15 ms |

Clean and error edit times are medians of three full-text requests per file.
The client encodes JSON before starting the clock. Times include pipe transfer,
JSON intake, parsing, index work and publication. A clean index is ready before
publication. Invalid syntax does not publish a partial index as complete results,
so error edits collect occurrences but skip final index construction.

Reference times are medians of 20 protocol requests after the final clean edit.
Each selects a node with two occurrences. They include the small client request
encoding, server lookup and response. Large reference lists cost more to encode.
These are protocol measurements, not Zed rendering or perceived typing latency.
There is one process per file size, not enough samples to establish a precise
regression percentage. The repeated increases still show a substantial index
construction cost. The baseline has no node-reference feature.

## Memory

| File | Exact retained entry bytes | RSS after clean analysis | Peak RSS before → after | RSS after close |
| --- | --- | --- | --- | --- |
| 5 MB | 4.08 MB | 6.49 MB | 17.71 → 18.74 MB | 2.38 MB |
| 20 MB | 16.33 MB | 18.73 MB | 63.62 → 67.76 MB | 2.38 MB |
| 40 MB | 32.65 MB | 35.05 MB | 124.85 → 133.96 MB | 2.38 MB |
| 100 MB | 81.63 MB | 84.03 MB | 308.53 → 364.81 MB | 2.38 MB |

The retained index uses exactly 20 bytes per node occurrence. Fixture entry counts
come from their simple edge-only structure: two occurrences per edge. RSS also
includes executable pages, stacks and allocator overhead. The baseline settled
near 2.34 MB after analysis. Source text, decoded names and the name hash table
are released after analysis; they are not included in retained entry bytes.

Peak RSS is the actual macOS `/usr/bin/time -l` maximum resident set size over the
open/edit/repair/lookup/close run. It is not a sampled peak. Idle and settled RSS
are `ps` samples of the server process. Peak RSS includes overlapping construction
storage and protocol intake. It is not the retained index size. Existing buffered
JSON intake can dominate the peak, so adding a 32.65 MB index does not necessarily
raise the old 40 MB peak by 32.65 MB. Client and editor memory are excluded.

The 100 MB example remains within the node and retained-index limits. Memory
returns near baseline after close. Warm idle RSS remains around 2.1 MB. Separate
15-run direct warm starts measured about 2.45 ms before and 2.38 ms after. They do
not establish a startup improvement or measure a cold cache. The binary grew
from 659,592 to 678,024 bytes, an increase of 18 KiB (2.8%).

## Representation and ownership

A small local parser patch observes completed node statements and edge endpoints
in the existing count-only parse. It does not introduce a second DOT parser.
Names are interned by exact decoded logical value in temporary storage; hash
collisions still require full equality. Bare/numeral spellings borrow the job's
source. Quoted, concatenated and HTML-like IDs use the parser's decoding rules.

Each retained entry has five u32 fields: start line, start column, end line, end
column, and node identity number. Entries use the negotiated position encoding.
No source text, name strings, hash table, AST, attributes, or syntax tree pointers
remain. Ordered statements skip sorting. Chains and scopes can arrive out of
order; a cancellable four-pass radix sort restores source order. Position
conversion walks source bytes once, with an ASCII fast path. Selecting a node
uses binary search; gathering its uses scans the entries once.

The worker builds an index for one source generation. The document takes ownership
only under its generation lock. Edits immediately free the old index and cancel
obsolete work. Close and shutdown free retained indexes. Cancellation and failure
release temporary construction storage. Index allocation failure does not stop
syntax diagnostics. The representation avoids a full AST; this report does not
claim a measured comparison against an AST implementation.

## Scope and limits

References cover the current open document's graph, including nested subgraphs.
They exclude graph/subgraph names, attribute keys/values, assignments and ports.
The first occurrence implicitly creates the node; `includeDeclaration=false`
omits it. Results are in source order. The initial feature requires a complete,
valid syntax parse. During rebuilding, requests return ContentModified; retry
after diagnostics. An invalid or incomplete parse returns RequestFailed instead
of stale or silently partial locations.

Retained indexes are capped at 128 MiB per document and 256 MiB across open
documents. Construction permits up to 4,000,000 unique identities. These limits
do not include temporary construction memory. Over-limit or failed indexes are
unavailable; syntax diagnostics remain available. Reference responses above
10,000 locations fail explicitly. There are no new editor settings.

## Validation and reproduction

Protocol tests cover logical ID forms, escaped quotes, empty IDs, edge chains,
scoped endpoints, ports, attributes, assignments, mixed line endings, multiline
IDs, Unicode position encodings, multiple documents, edits, close/reopen,
invalid syntax, pending generations, and response limits. Debug-allocator runs
passed with no leak report in buffered and experimental in-place JSON modes. Unit tests cover allocation failure, cancellation,
and isolation of index failure from syntax analysis. Debug and ReleaseSafe unit
checks and the vendored parser regression tests passed. Neovim verified actual
LSP attachment, diagnostics, completion and references. Zed Find All References
showed all five uses of `build` in [the example](../../examples/references.dot),
including the quoted ID and port-qualified node.

Use `python3 tools/references_bench.py before BASELINE` and then
`python3 tools/references_bench.py after CANDIDATE`. Add `100` as a final argument
for the 100 MB fixture. Optional sizes select their own report suffix.
Use `python3 tools/references_startup.py BASELINE CANDIDATE` for warm starts.
Run builds and checks before measurements, not concurrently. The baseline binary
is preserved locally at `/private/tmp/dot-ls-references-before/dot-ls`; it is not
a build or test dependency. The JSON records contain binary SHA-256 hashes.

Raw records: [before](../results/legacy/references-before.json), [after](../results/legacy/references-after.json),
[100 MB before](../results/legacy/references-before-100.json), [100 MB after](../results/legacy/references-after-100.json),
and [warm startup](../results/legacy/references-startup.json).
