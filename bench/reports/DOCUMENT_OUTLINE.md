> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

# Compact document outline

`textDocument/documentSymbol` returns graph scopes, subgraphs and explicit node
statements in source order. Graphs use `Namespace`, subgraphs use `Package`,
clusters use `Module`, and nodes use `Variable`. A cluster name starts with the
case-sensitive logical prefix `cluster`. Anonymous subgraphs display `{…}`.
Unnamed graphs display their graph keyword. Quoted and concatenated names are
decoded for display. Empty logical names display their raw spelling, so LSP
labels remain non-empty. Repeated explicit declarations remain separate entries.

Edges do not create outline entries. References still include implicit node
creation through edges. Attribute keys, values, ports and HTML elements are not
DOT declarations. This keeps the outline focused and avoids an entry per edge
endpoint. Hierarchical clients receive `DocumentSymbol[]`. Older clients receive
flat `SymbolInformation[]` with container names and document locations.

## Recovery

A local count-session observer reports parser-recognized structure. It remains
active after the normal syntax sink aborts. The ordinary sink's terminal contract
is unchanged. This adds no independent DOT parser and changes no recovery rules.

A node prefix is captured when its attribute list opens or a complete node ID
reaches EOF in an open scope. The final accepted node
statement updates that record, instead of adding a duplicate. Thus `d [sha;`
keeps `d`, excludes `sha`, and permits `e; f;` after the recovery boundary. A bad
edge such as `broken -> ;` does not invent a node declaration. Later declarations
and scopes remain available. Unclosed recognized scopes end at EOF.

An unterminated string, comment or HTML token can consume later source. Recovery
cannot expose declarations inside that token. A skipped malformed statement is
not reinterpreted as valid declarations. Resource, diagnostic-stop and cancelled
parse outcomes do not publish a silently truncated outline.

## Storage and scheduling

The syntax pass captures 24-byte records with byte spans, a kind and subtree
bounds. A fixed 257-entry scope stack records hierarchy. It stores no node hash
table, attributes, ports, edges, decoded names or source copies for the outline.
The job owns the existing immutable source snapshot.

After DOT and delayed HTML diagnostics are published, the worker builds the
completion index. The outline reuses that local index's line and Unicode tables
to convert byte offsets. Binary searches avoid scanning a long line for every
symbol. Name conversion and position work check cancellation and yield to new
syntax work. Construction buffers are freed before requests are answered.

The published payload uses 48 bytes per symbol plus its display-name bytes.
It stores numeric ranges, selection ranges, subtree bounds, kinds and names.
It retains no source and no full AST. The document owns the payload. Edits,
close and shutdown free it. The generation check also covers close/reopen.
Queued requests support cancellation and receive `ContentModified` on edits.

Limits:

- 250,000 symbols, including graph and subgraph entries.
- 32 MiB retained payload per document; 64 MiB across published outlines.
- Display names use at most 128 UTF-8 bytes plus an ellipsis. Full identifier
  selection ranges are retained. Decoding is limited to raw names of 4,096 bytes;
  larger spellings use a bounded raw prefix for display.
- A conservative 128 MiB JSON response bound. Flat responses also account for
  escaped URI and container-name repetition. Serialization needs temporary
  capacity beyond the retained index; process peak measurements include it.
- 64 pending feature requests per document, shared with completion and references;
  string request IDs are limited to 8 KiB.

Allocation or index limits return `RequestFailed`, not a partial successful list.
They do not suppress syntax diagnostics. Completion coordinate allocation must
succeed for outline conversion. Published completion and outline budgets are
separate. Current response serialization and stdout writes hold the state mutex;
a large outline response or slow client can delay dispatch and later publication.
This existing output-path limitation still needs a separate scheduling change.

## Tests and Zed

Debug and ReleaseSafe unit tests, the vendored parser tests and all seven Python
protocol suites pass. Outline checks cover nesting, anonymous scopes, clusters,
recovery, incomplete attributes, unclosed scopes, HTML, logical names, UTF-8/16/32,
CR/LF/CRLF, long names, flat clients, size limits, edits and close/reopen. Unit
checks cover compact layouts and allocation-failure isolation from diagnostics.

In Zed, `document_symbols: "on"` is enabled only for **DOT (dot-ls)** in project
settings. Zed defaults to Tree-sitter outlines; see the
[official setting reference](https://zed.dev/docs/reference/all-settings#lsp-document-symbols).
This uses the LSP index and adds no Tree-sitter outline grammar or machine-only
adapter patch. Customers can use the same language setting with the adapter.

Native Zed checks passed with `examples/outline.dot`: the picker and persistent
panel show nested scopes and declarations after the intentional bad edge.
Selecting `output` jumps to line 15. A live replacement with `d [sha; e; f;`
kept `d`, `e`, and `f` and excluded `sha`. The saved example was restored.

## Measurement method

`tools/outline_bench.py` compares the preserved quick-fix ReleaseSafe build with
the outline build. Both use the same 5/20/40 MB fixtures and UTF-16 protocol.
Each case has three fresh processes and open, broken-tail edit and repair phases.
Each phase waits for expected diagnostics, then background work to settle, then
requests the outline. Before-build requests correctly return MethodNotFound.

The plain fixture contains edges and has one outline symbol. The HTML-heavy
fixture has one explicit node per label, so it measures a large real outline.
The broken edit damages the last edge endpoint. It keeps earlier declarations
and tests recovery without changing the expected outline size. Sizes are decimal
MB. These are server-only measurements; Zed and Python client memory are excluded.
No builds or editor activity ran during the controlled runs.

Raw results and binary hashes are in `outline/before.json` and `outline/after.json`.
`tools/summarize_outline_bench.py` writes `outline/summary.json`. Latencies are
three-run medians. Peak RSS is the actual maximum from `wait4`, across all phases
and requests, rather than the maximum of periodic samples. RSS after quiet is a
separate retained-process reading. Small differences can be run variation.

## Results

| Size | Layout | Final diagnostics before → after | Peak RSS before → after | Settled RSS before → after | Outline request |
| --- | --- | ---: | ---: | ---: | ---: |
| 5 MB | plain | 32.0 → 38.3 ms | 17.86 → 17.89 MB | 6.70 → 6.73 MB | 0.2 ms |
| 5 MB | html | 33.4 → 29.5 ms | 17.97 → 18.06 MB | 5.05 → 6.78 MB | 25.6 ms |
| 20 MB | plain | 107.3 → 101.1 ms | 63.85 → 63.88 MB | 19.25 → 19.28 MB | 0.2 ms |
| 20 MB | html | 94.3 → 95.4 ms | 63.98 → 64.03 MB | 12.32 → 19.07 MB | 74.9 ms |
| 40 MB | plain | 189.9 → 193.2 ms | 125.21 → 125.16 MB | 35.96 → 36.00 MB | 0.3 ms |
| 40 MB | html | 169.6 → 168.6 ms | 125.17 → 125.29 MB | 22.05 → 35.52 MB | 125.8 ms |

| Size | Layout | Broken edit diagnostics before → after | Repair diagnostics before → after | Symbols | Response bytes |
| --- | --- | ---: | ---: | ---: | ---: |
| 5 MB | plain | 35.3 → 32.3 ms | 34.5 → 33.8 ms | 1 | 229 |
| 5 MB | html | 38.2 → 38.3 ms | 31.5 → 35.4 ms | 29,412 | 6,073,067 |
| 20 MB | plain | 119.2 → 115.9 ms | 106.5 → 107.9 ms | 1 | 230 |
| 20 MB | html | 112.4 → 109.7 ms | 100.2 → 95.8 ms | 117,647 | 24,514,182 |
| 40 MB | plain | 212.4 → 212.9 ms | 192.3 → 196.2 ms | 1 | 230 |
| 40 MB | html | 195.8 → 193.3 ms | 172.3 → 167.7 ms | 235,294 | 49,376,911 |

Spawn-to-initialize turnaround was 5.60 → 6.41 ms median.
This includes harness setup and uses a warm filesystem. Idle server RSS stayed
at 2.18 MB. Binary size changed from 836,312 to
854,920 bytes, an increase of 18,608 bytes. No external server libraries were added.

On the 40 MB HTML fixture, 235,294 entries need 13,411,759 bytes of retained
outline payload: about 57 bytes per node with these nine-byte names. The settled
RSS increase is about 13.47 MB. The source is already freed at that point.
The largest before/after process peak increase across all six cases is under
0.12 MB. Intake remains the peak allocation stage for these fixtures.

The 40 MB HTML response contains about 49.4 MB of JSON and takes 125.8 ms to
return, including serialization and pipe transport. A compact retained index does
not make a large LSP result free. Editor allocations for consuming that list are
not included in server RSS. Small Zed navigation/recovery checks passed; this
increment does not claim a new isolated large-file editor memory profile.

Diagnostics remain in the same general range at 20/40 MB. The 5 MB plain open
median increased by 6.3 ms in this run; individual samples varied from about
24 to 40 ms. The samples are too small to attribute every difference to the
feature or claim a speed improvement. The table preserves the measured costs.

The first implementation run is also preserved as `outline/after-initial.json`.
It preceded final EOF/empty-name and response-bound checks. The main comparison
and build metadata refer to the final executable hash.
