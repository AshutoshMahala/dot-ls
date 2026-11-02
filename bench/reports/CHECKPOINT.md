> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

# First development checkpoint

## Scope and layers

The executable runs a small stdio dispatcher and one analysis worker. The worker
starts on the first accepted document. It waits on a condition when there is no
work. There is no server polling loop.

`src/analysis.zig` calls the locally patched public dot-parser count-only session API. It owns no
I/O, threads, atomics, protocol types, or source storage. The caller supplies its
fixed nesting scratch, diagnostic bag, borrowed source, and cancellation hook. No AST is
retained. Parser capacities are not used to make a second parse.

The LSP facade owns document generations, scheduling, position conversion, and
JSON presentation. `src/positions.zig` creates one line index when diagnostics
need positions. Clean syntax results need no line index. It uses binary search
for line lookup and scans that line for Unicode columns. LF, CRLF, lone CR, BOM,
and astral characters are covered by tests. Position conversion and index
construction check cancellation during long scans.

## Ownership and scheduling

The process uses an explicitly passed page allocator by default. Small HTML
cache entries use a separate, explicitly owned packed allocator backed by it. JSON messages
use a bounded request backing region and fall back to an arena when needed.
Decoded values are released after dispatch. Source snapshots are still copied;
this is not a zero-copy protocol implementation.

Each document owns its URI and one pending job at most. Each job owns immutable
text and its own URI. A worker has exclusive ownership of its active job. An
atomic flag permits the protocol thread to request cancellation. The parser
receives that flag through its public cooperative hook.

A new edit frees the earlier pending job and cancels active work for that URI.
A server-wide generation distinguishes close/reopen from an earlier document,
even when editor version numbers restart. Only the current generation can
publish diagnostics. Backward editor versions are applied as supplied.

The worker frees source after analysis. Parser scratch is a caller-owned
256-frame stack buffer. Block scanning uses metered 4,096-credit pumps and a
per-step atomic cancellation hook. No retained syntax pool is allocated. This checkpoint stores no
finished AST or whole-document source cache. Selected HTML fragment bytes have a bounded result cache. It retains a compact node occurrence index. A mutex protects document state and serialized
stdout writes. Both threads can write protocol messages under that mutex.

## Fixed limits

- 200 MiB per document source.
- 512 MiB for pending and active job source bytes combined.
- 128 tracked documents.
- 8 KiB per URI and message headers.
- 256 MiB per framed JSON message.
- 256 levels of DOT nesting.
- 1,000 retained parser diagnostics, followed by an incomplete-analysis notice
  when the diagnostic sink stops parsing.

These are internal defaults, not editor settings. Source limits do not bound
total process memory: framed input, JSON decoding, copies, line indexes, and
output serialization add costs. Oversized sources receive an information
message. Opens beyond the document count and invalid sync payloads are ignored.
Fatal framing errors close the transport; malformed JSON with valid framing gets
a parse-error response. No document text is written to logs.

## Current limits and later work

This checkpoint is not M0. It does not claim all release requirements.

- No graph semantic resolution. Compact recovery outlines and parser-provided quick fixes
  are now available (see the code-action increment below). Diagnostics use typed expected/found details, catalog repair guidance, and
  related source locations when the client supports them.
- A local Zed adapter is included. There is no published extension, CLI checker, or layout dependency.
- No parent-process monitoring or trace support yet.
- No debounce or request-priority scheduler. Pending jobs are selected in document
  order; fairness needs review before broader use.
- Generic JSON parsing and full sync make source copies. Their measured cost
  should guide the next decoder and text-buffer work.
- A slow reader of stdout can block writes while the state mutex is held.
  Output backpressure needs a bounded design before claiming typing guarantees.
- Cooperative cancellation is implemented. The complete 5 ms release bound,
  including allocation, cleanup, conversion, and output, is not established.
- Memory and latency results are local samples, not release performance gates.
- Only native macOS execution was tested. Cross-platform execution and release
  distribution remain future work.

The vendored parser includes a documented local count-only session extension.
It reuses the existing grammar and counting sink; no grammar is implemented in
the facade. The source delta is in `vendor/patches/count-only-sessions.patch`.
New language analysis belongs in the parser layer rather than protocol handlers.


## Editor feature increment

The executable and displayed server name are now `dot-ls`; `dotls` remains an
installed compatibility executable and the existing Zed adapter ID. The checkout
folder has not moved. Zig uses `dot_ls` as its internal package identifier.

`textDocument/completion` selects static keyword lists from a compressed lexical
context index. Header, graph body and edge endpoint contexts have separate lists.
Names, attributes, strings, comments and HTML-like content suppress keywords.
The editor filters the typed prefix. No attribute, value, node-name or HTML
completion is provided. No trigger characters or resolve requests are advertised.
Diagnostics publish before context construction; references build after it.
The context index retains no source, token list or AST. It stores varint context
transitions, sparse lookup anchors, line starts and Unicode unit corrections.
It has a 64 MiB document limit and 128 MiB aggregate limit. Temporary allocation
capacity is additional. Completion and reference requests share a 64-request
queue per document and support cancellation. See [the measurements](COMPLETION_CONTEXT.md).

Diagnostic messages have a concise explanation and a second line of guidance.
Expected/found constructs, reserved words and unterminated constructs use typed
parser details. Other codes use their catalog summary and hint. Related notes
point to parser-provided source locations, negotiated in the client's position
encoding. Message and related-note storage is owned by one analysis-local arena
and released after publication or cancellation. The arena has no allocations
on clean input. Structured parser codes are preserved.

Feature requirements and deferred provenance/HTML work are recorded in
FEATURE_REQUIREMENTS.md. No new editor settings or runtime dependencies were added.

Measurements and validation for this increment are in [FEATURE_PERFORMANCE.md](FEATURE_PERFORMANCE.md).

## Node references

`textDocument/references` is advertised. A local count-session observer records
node occurrences during the same metered/cancellable parse. Construction interns
logical names temporarily, then releases those names and source views. Each
retained occurrence has five u32 fields: start line/column, end line/column and
node identity. Sorted ranges support binary search for the selected node; one
linear scan gathers matching occurrences. No AST or source cache is retained.

The document owns its index. Edit, close, shutdown, failed analysis and cancelled
source generations release or discard it. The worker transfers ownership only
under the document-generation lock. Complete indexes are ready before diagnostics
are published. Syntax errors make references unavailable in this increment.
Fixed limits and exact reference semantics are in FEATURE_REQUIREMENTS.md.
[Measurements](REFERENCES_PERFORMANCE.md) include the construction cost.

## Diagnostics priority and index optimization

The initial reference increment above is historical. The worker now publishes
DOT diagnostics after parsing and span capture. It then builds identities and
ranges as lower-priority work. Pending syntax jobs and large packet intake pause
indexing. An interrupted build releases its temporary hash table and output;
its source spans can be retried once foreground work is done. The job owns that
source until completion/cancellation, and it stays within the source budget.

The retained layout uses 16-byte entries and sparse 8-byte end coordinates for
multiline IDs. Name-table keys are source spans, with exact streamed logical-value
hashing/comparison. There are no per-quoted-occurrence decode allocations. The
range scan uses short ASCII blocks and scalar Unicode conversion. Source-order
radix sorting remains cancellable; a yield preserves a complete permutation.

References submitted before readiness wait in a bounded document-owned queue.
String IDs are copied out of intake storage. Edit/close, explicit cancellation,
shutdown, failure and successful reply all release queued request storage. See
[stage profiles and measurements](INDEX_OPTIMIZATION.md).

## Delayed label stage

HTML-like label support now follows DOT diagnostics and precedes completion
context construction. Parser attribute callbacks capture accepted label spans
without retaining syntax. The standalone markup counter and source validator
check each selected fragment with untrusted limits, fixed scratch and cooperative
cancellation. There is no markup AST. The worker yields to syntax during checking
and position mapping. Later results merge DOT and HTML findings for the same
current generation.

Document caches keep exact HTML fragment bytes and relative findings. Immutable
entries are shared across cache generations with explicit reference counts.
Outer edits reuse unchanged labels and map findings to current positions. Inner
edits recheck changed content only. Full outer DOT parsing still runs on each
full-sync change. Cache payload limits include published and in-flight owners;
hash tables and selected-span arrays add bounded metadata. Close and shutdown
release document ownership, while cancellation releases job ownership. See
[HTML_LABELS.md](HTML_LABELS.md) for limits, measurements and remaining work.

## Full HTML label selection (2026-10-15)

The independent 65,536-label cutoff is removed. Selected positions use a
bounded delta/length varint stream owned by the analysis job. All 117,646 and
235,293 labels in the dense 20/40 MB fixtures are checked, including unique
bodies beyond cache capacity and errors at EOF. Cache and fragment limits
remain explicit. See [the implementation and measurements](HTML_LABEL_CAP.md).

## DOT editor policy and streaming validation (2026-10-15)

`src/parser_policy.zig` now defines the named dot-ls policy. The count-only DOT
pass checks edge operators and repeated logical attribute keys through a local
syntax-event observer. A separate bounded, cancellable source scan checks UTF-8.
Production still retains no DOT AST. Duplicate checking uses a fixed 12 KiB key
table with explicit work limits and an incomplete notice. Diagnostic capacity
and syntax recovery remain explicit. Graphviz HTML vocabulary checks are still
separate and deferred. See `PARSER_POLICY.md` for coverage, tests and the
controlled 5/20/40 MB before/after delay and memory comparison.


## Parser-provided code actions (2026-10-15)

The server now supports `textDocument/codeAction` for `quickfix` offers from
DOT diagnostics and delayed HTML diagnostics. It keeps compact numeric edit
records, not an AST or a source copy. Requests filter the published catalog
without parsing. Edits carry document versions; echoed old diagnostic tokens
are rejected. Optional fix-storage failure does not suppress diagnostics.
Real Zed checks covered operator replacement, HTML reference termination,
quotation and a missing delimiter. See `CODE_ACTIONS.md` for tests and the
5/20/40 MB before/after server delay, memory and action-request measurements.

## Compact document outline increment

`textDocument/documentSymbol` now returns graph, subgraph and explicit node
symbols. Clusters use a distinct kind. Anonymous scopes use `{…}`. A local parser
observer keeps recognized structure across recoverable syntax errors. Attribute
keys and edge uses do not become outline entries. No full AST is retained.

Temporary byte spans are captured during parsing. Position conversion and name
storage run after DOT and delayed HTML diagnostics, using the completion index's
coordinate tables. Published outlines own only numeric ranges, subtree bounds,
symbol kinds and bounded names. Edits and close retire the index and pending
requests. See [DOCUMENT_OUTLINE.md](DOCUMENT_OUTLINE.md) for limits and comparisons.
