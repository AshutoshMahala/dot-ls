> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

# dot-ls editor feature requirements (2026-10-14)

Status: agreed feature plan. The current implementation status is recorded in CHECKPOINT.md.
The product and executable name is **dot-ls**. `dotls` remains a temporary
executable and editor-server-ID compatibility alias. The checkout folder does
not need to move, and dot-parser keeps its name.

- **R-FEAT-001, implemented:** diagnostics use typed parser details for
  expected/found constructs, concise repair guidance, and related locations.
  Do not invent a repair when the parser cannot establish one. Keep structured
  codes, severity, version checks, Unicode positions and cancellation.
- **R-FEAT-002, implemented:** advertise keyword completion and return the
  six DOT keywords as bounded static candidates for open documents. This first
  increment relies on editor prefix filtering; syntactic context filtering,
  attribute completion and label completion follow later. Retain no source or
  AST solely for this static list. Keyword coloring is a separate editor feature.
- **R-FEAT-003, references implemented; provenance planned:** references and first-occurrence navigation use logical
  node identities, including quoted forms and implicit creation through edges.
  Later provenance explains explicit updates and inherited defaults with source
  locations, respecting graph identity, statement order and subgraph rules.
- **R-FEAT-004, planned:** analyze DOT first and embedded markup afterward in
  cancellable units. Record raw spans and owner/context information; distinguish
  HTML-like identifiers from label content. Publish merged diagnostics for the
  current generation; later label results must preserve DOT diagnostics.
  Staged work may publish more than once per version, with merged diagnostics.
- **R-FEAT-005:** choose retained ASTs or compact feature indexes from measured
  costs. Neither representation is mandatory. Ownership, source lifetimes,
  cancellation, memory limits and partial/unavailable results must stay explicit.
- **R-FEAT-006:** measure startup, binary size, diagnostic open/error/repair
  latency, idle memory, actual process peak RSS, and request latency before and
  after each feature increment. Include valid and broken large files. Separate
  editor latency, protocol turnaround, and parser-only timings. Preserve raw
  evidence and avoid treating sparse RSS samples as exact peaks.

The first increment implements R-FEAT-001 and R-FEAT-002. It does not yet
implement HTML staging, provenance, semantic tokens, attribute
completion, or a retained document cache. Current fixed limits are 200 MiB per
source, 256 MiB per message, and 512 MiB of active/pending source storage.

## Node reference increment (2026-10-14)

R-FEAT-003 now includes `textDocument/references` within each open document.
Use a compact occurrence index instead of retaining the AST or source. Match
logical IDs across quoted, concatenated, HTML-like, bare and numeral spellings.
Node identity is graph-wide across subgraphs. Ports, attribute keys and values,
assignments, graph names and subgraph names do not count as node occurrences.

`includeDeclaration` includes the first occurrence, which implicitly creates the
node in DOT. If false, omit that occurrence. Return exact identifier ranges in
the negotiated position encoding. Return occurrences in source order.

Invalidate the index immediately on edits and close. Publish only a current
source generation. Return ContentModified while rebuilding; never return stale
locations. This increment makes references unavailable when syntax analysis is
incomplete or invalid. It does not return a partial index as complete results.
Index allocation failures must not suppress syntax diagnostics.

The retained index uses 20 bytes per occurrence. Limit it to 128 MiB per document
and 256 MiB across open documents. Construction limits unique node identities to
4,000,000. Transient construction storage is additional to retained index storage.
Report unavailable references when a limit prevents a complete index. These are
fixed implementation limits, with no new editor setting.

Provenance and a separate first-occurrence navigation command remain planned.
Measure clean and invalid edit latency, lookup latency, construction peak RSS,
retained RSS, and memory after close before accepting each representation change.

A reference response is limited to 10,000 locations. Larger results fail explicitly;
never silently truncate a node’s uses. This bounds temporary response storage.

## Diagnostics priority and smaller indexes (2026-10-14)

This amendment supersedes the initial reference-index scheduling and storage
rules above. Publish DOT diagnostics after parsing and span capture. Do not wait
for node identity interning or editor-range conversion. Run those steps as
lower-priority work on the existing worker. New syntax jobs and large packet
intake interrupt indexing. Cancel obsolete generations. Do not add a worker
thread per request or per document.

Single-line occurrences use 16 bytes each. Multiline identifiers use an extra
8-byte end-position record. Include both in the 128 MiB per-document and 256 MiB
aggregate retained-index limits. Temporary hash-table keys use 8-byte spans and
compare exact logical values. No name strings, source or AST remain after index
completion. Queued index jobs keep temporary source ownership within the existing
512 MiB source limit.

A reference request can wait for its current index after diagnostics are sent.
Keep at most 64 deferred reference requests per document, with copied string IDs
limited to 8 KiB each. Support `$/cancelRequest` for deferred requests. Edits and
close fail obsolete requests with ContentModified; explicit cancellation uses
RequestCancelled. Syntax/index failure uses RequestFailed. Never return stale
or partial results as complete results. No new editor settings are needed.

Measure diagnostics latency separately from index readiness and ready-index
lookup latency. Report retained bytes, transient construction allocations and
actual server peak RSS separately. Preserve the pre-optimization measurements.

## Context completion and Zed editing (2026-10-15)

This amendment supersedes the static-candidate rule in R-FEAT-002.
Return graph, digraph and strict at the document header. After strict, return
only graph and digraph. Inside a graph or subgraph, return graph, node, edge
and subgraph. After an edge operator, return only subgraph. Suppress keywords
in graph/subgraph names, ports, assignments, attribute lists, quoted IDs,
comments and HTML-like content. The editor still filters the typed prefix.
These are conservative editing hints, not another syntax validator. Use the
public dot-parser lexer, including its bounded scans, for token boundaries.
Incomplete DOT must still permit completion in known contexts. After a lexical
failure, suppress completion in the unknown suffix.

Publish diagnostics first. Build compressed context transitions and position
metadata afterward, before reference interning, on the existing worker. Syntax
jobs and large input packets take priority. Cancel obsolete generations. Retain
no source, AST or token list after background work finishes. Bound the complete
context index to 64 MiB per document and 128 MiB across documents. Construction
capacity and growth overlap add temporary memory. Measure that cost separately.

A completion request can wait for its current context index. Share the limit of
64 deferred requests per document with references. Copy string IDs up to 8 KiB.
Support cancellation, ContentModified on edits/close, and RequestFailed when
resource limits prevent a complete index. Do not send stale candidates or a
broad static fallback. Return an empty list for an invalid/outside position.

The Zed adapter supplies its own pinned editor grammar and queries. Pair braces,
square brackets and quotes. Indent graph/subgraph blocks and attribute lists.
Exclude strings and comments from automatic pairing. Keep this work in the
editor. Add no LSP formatting request, server library, process or thread.
Use the distinct language name DOT (dot-ls) to avoid conflicts with the Graphviz
extension. The existing adapter and server configuration ID remains dotls.
Measure editor behavior separately from server latency and memory.

## Delayed HTML-like label checks (2026-10-15)

R-FEAT-004 now checks parser-recognized HTML operands in label, xlabel,
headlabel and taillabel attributes and assignments. Logical quoted/concatenated
key spellings count. Other HTML-like IDs and quoted label values do not.
Use the markup subsystem's untrusted limits, block scanning and cancellation.
Use Graphviz's case-insensitive tag matching. Vocabulary checks for allowed tags
and per-element attributes remain deferred. This is not browser HTML validation.

Publish DOT diagnostics first. Then check labels as background work and publish
one merged set for the same current version. Preserve DOT findings and related
locations. Run completion context and reference indexing after this label stage.
New syntax and large packet intake interrupt background work. Obsolete jobs
cannot publish. Completed label checks survive a yield; an interrupted fragment
is retried. Position mapping must also yield to new syntax.

Keep a bounded exact-content cache of fragment-local diagnostics, including clean
results. Reuse byte-identical labels after outer edits. Rebase ranges and related
locations against the new source. Identical labels in one document share one
check and payload. A changed label is checked again; unchanged siblings reuse
results. Store no AST and no complete document source. The current full-sync
implementation still parses outer DOT on every edit. Skipping that parse is not
part of this increment; edits can change lexical boundaries and source positions.

Limit cached payload to 8 MiB and 4,096 entries per document. Limit live retained
payload across published and in-flight generations to 32 MiB and 16,384 entries.
Hash tables and selected-span storage are additional bounded metadata. Cache
pressure must cause rechecking, not skipped validation. Release all document
cache ownership on close; jobs release their own references on completion or
cancellation. Exact byte comparison is required after hashing.

Capture selected labels without an independent count cap. Encode ordered body
spans as unsigned gap/length varints. Bound requested span capacity to
`source_bytes / 4 + 16` per job; the existing 200 MiB source limit therefore
bounds retained selection capacity to 50 MiB plus 16 bytes. Resizing can briefly
hold both old and new buffers. Do not retain an AST or add a second DOT parse.
Allocation failures must report incomplete checking. Cache pressure must still
cause rechecking rather than skipped labels. Verify complete selection and tail
error reporting on the 20/40 MB dense repeated and unique-label fixtures.

Use the untrusted fragment limits: 8 MiB,
256 nested elements, 100,000 nodes and 200,000 attributes. Keep 64 findings per
fragment, 1,000 total findings, and explicit incomplete-check notices when limits
or resource failures prevent coverage. Source validation uses fixed scratch for
1,024 attributes in a header. Known labels before a DOT failure can be checked;
recovery beyond that failure still depends on the outer parser.

Measure first DOT publication, merged label publication, fragment checks versus
reuse, retained payload, transient allocations and server RSS separately. Keep
label-free before/after results as a regression control.

HTML entry storage uses an explicitly owned, thread-safe packed allocator backed
by the selected process allocator. It has no stack traces and returns empty
buckets. Large source and index allocations keep their existing allocator.
This avoids one macOS page per small cache object. Count packed allocation
capacity separately from logical cache payload; verify memory after close.

## Explicit DOT editor policy (2026-10-15)

- **R-FEAT-012, implemented:** define a named dot-ls parser policy. Keep block
  scanning, metering, cancellation, collected diagnostics and bounded nesting.
  Add graph/operator agreement and source-encoding errors. Warn on repeated
  logical keys across the attribute lists of one statement. Allow valid ports,
  subgraphs and graph kinds. Retain no full AST for these checks.
- Use parser events and bounded temporary key state. Keep source encoding checks
  cancellable. If key work, finding capacity or syntax recovery prevents full
  coverage, report incomplete checking. Do not silently claim complete validation.
- Preserve current-generation diagnostics in delayed HTML results. Measure
  diagnostics delay, startup and server memory before and after the change.

See [PARSER_POLICY.md](PARSER_POLICY.md) for rules, limits and measurements.


## Parser-provided quick fixes (2026-10-15)

- **R-FEAT-013, implemented:** expose parser-provided DOT and HTML repairs as
  `quickfix` code actions. Retain compact edit records and no full AST or source
  for this feature. A request must not parse the document again.
- Return versioned document changes. Retire records on edits and close. Reject
  stale diagnostic generations and report when current offers are unavailable.
  Do not send unversioned fallback edits to a client that lacks version support.
- Preserve DOT offers when delayed HTML diagnostics arrive. Rebase markup fixes
  to document positions in the negotiated encoding. Offer no guessed repairs.
- Mark machine-applicable offers preferred. Keep possible repairs selectable
  without that flag. Fix-all and automatic application are outside this increment.
- Test applying the edits and rechecking diagnostics, stale generations,
  Unicode positions, the Zed UI, and before/after diagnostics delay and memory.

See [CODE_ACTIONS.md](CODE_ACTIONS.md) for ownership, limits and measurements.

## Compact document outline (2026-10-15)

- **R-FEAT-014, implemented:** provide `textDocument/documentSymbol` from a
  compact declaration index. Retain no full AST, document source, attributes,
  ports or edge lists for this feature. Group explicit node declarations under
  their graph and subgraph scopes. Show anonymous subgraphs as `{…}`. Give
  clusters a distinct symbol kind.
- Keep parser-recognized declarations before and after recoverable errors.
  Keep a node prefix when its attributes are incomplete. Do not treat attribute
  keys, values or edge uses as declarations. Recovery does not guess structure
  inside an unterminated token or a skipped malformed statement.
- Capture byte spans during parsing. Convert positions after diagnostics, using
  existing completion coordinate data. Bound storage, check cancellation, reject
  stale generations, and return explicit errors if limits prevent a complete
  index. Support hierarchical and flat LSP clients.
- Test recovery, nesting, Unicode positions, lifecycle, resource failures and
  real Zed navigation. Compare server diagnostics delay and memory with the
  preceding quick-fix build on 5/20/40 MB plain and HTML-heavy files.

See [DOCUMENT_OUTLINE.md](DOCUMENT_OUTLINE.md) for behavior, limits and evidence.
