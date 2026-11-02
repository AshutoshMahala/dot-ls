> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

# Parser-provided quick fixes

Implemented 2026-10-15. dot-ls exposes `textDocument/codeAction` with the
`quickfix` kind. It uses DOT diagnostic `fix` offers and markup diagnostic
`suggestedFix()` offers. It does not invent repairs, reparse on a request,
retain an AST, or retain document source for code actions.

## Available actions

Depending on the parser diagnostic, actions can replace an edge operator or a
mistyped keyword, insert a missing delimiter or `=`, remove unexpected text,
quote a reserved name, or insert a missing HTML reference semicolon. A repeated
attribute warning does not carry a parser repair, so it has no removal action.
HTML tag mismatch repairs are not synthesized. The library does not provide one
for that diagnostic.

The user chooses an action. Only fixes marked machine-applicable by the parser
are marked `isPreferred`. Possible repairs remain available without that flag.
This is more conservative than the original M0 proposal to prefer every sole
fix. No fix-all command, automatic repair, resolve endpoint or execute command
is added.

In Zed, place the cursor inside the primary error underline and press `Cmd+.`.
Choose the offered action. `examples/quick-fixes.dot` provides an operator error
and a missing semicolon in an HTML label. It intentionally starts with errors.
The extension and its settings require no change. Restart the language server
once after replacing an older binary so Zed learns the new capability.

## State, ownership and stale edits

The analysis worker converts parser byte ranges to the negotiated UTF-8,
UTF-16 or UTF-32 positions. Common edits reuse the diagnostic's converted
positions, avoiding another walk along a long line. A retained record contains
only compact numeric ranges, an edit kind, a static replacement enum and the
parser's preference flag. Tests require each record to be at most 40 bytes.

The published catalog contains at most one record per retained finding, capped
by the existing 1,000-finding budget: at most 40 KB of record payload per open
document. Empty catalogs allocate no record storage. The document limit remains
128. Array capacity, allocator rounding, job-owned construction records, HTML
merge records, diagnostic metadata and response serialization add temporary
costs. The payload limit is not a claim about total process RSS.

DOT publishes a catalog with its first diagnostics. The delayed HTML result
preserves those offers and adds its own, with rebased ranges. Temporary merge
storage is discarded on a yield. Published records contain no borrowed pointers
to the source or to HTML cache entries. Syntax-only job records are freed after
publication; HTML jobs free their DOT prefix after the merged publication.
Edits, close, reopen and shutdown invalidate or release catalogs. A new edit
immediately retires the previous generation's records.

Diagnostics with a fix carry a namespaced generation token in `data`. A request
that echoes an obsolete token gets `ContentModified`, including after reopening
the same URI with the same version. Requests made before current diagnostics
are ready also get `ContentModified`. Without echoed data, only the current
catalog is queried. Every returned edit uses `documentChanges` with the current
URI and exact version. The client must reject an edit when that version no
longer matches. Clients that do not advertise versioned document changes get
no actions; the server does not fall back to an unversioned edit.

A request filters the current catalog by diagnostic range and requested kind.
It reads no source and performs no parsing. Context is bounded to 1,024
entries and 64 requested kinds. Each action contains one edit, except quoting,
which inserts two static quotation marks. Quoting does not copy a large name
into the response. The usual request arena is released after serialization.

If optional offer storage or snapshot allocation fails, diagnostics still
publish. Code actions for that generation return a resource failure instead
of hiding diagnostics or returning a partial catalog as complete. Cancellation
and priority yields during range conversion retain their existing behavior.

## Verification

`tests/code_actions.py` applies the returned edits and requests fresh diagnostics.
The operator, delimiter, `=`, quotation, deletion and keyword fixtures become
clean. Cases use multibyte text and CRLF before the edit, with each negotiated
position encoding. HTML tests cover fragment-to-document rebasing and repair.
Additional tests cover kind and range filters, malformed/bounded contexts,
unsupported clients, stale edits and close/reopen with the same version.

Debug and ReleaseSafe unit tests cover compact record size, the two-insertion
quotation representation and snapshot allocation failure. Existing LSP, HTML,
validation, references and completion protocol suites pass.

In real Zed, `Cmd+.` displayed and applied these actions in the dedicated test
buffer:

1. Replace `--` with `->` in a `digraph`.
2. Insert `;` after `&amp` inside an HTML label.
3. Quote the reserved node name in `a -> node` as `a -> "node"`.
4. Insert `]` before the closing graph brace.

Each repair removed its diagnostic without saving. Zed applied both quotation
insertions correctly. The reusable example was restored and saved afterward.
Other open buffers were not edited or saved. The final benchmarked binary was
reloaded in Zed and its operator action was applied again. Undo restored the
example for manual use.

## Performance method

`tools/quickfix_bench.py` runs old and new native ReleaseSafe binaries using the
same server-only resource client and fixture layouts as previous comparisons.
There is no editor in the measured process. Both builds retain the same parser
policy, source storage, reference index and HTML cache behavior.

For each 5/20/40 MB plain DOT and repeated-HTML file, three fresh processes get
five versions: clean open, one wrong operator, repair, 1,000 wrong operators and
final repair. Both builds must report the same errors. The 1,000-finding case
also produces the existing incomplete notice. Messages are encoded before
measurement. Each size must finish successfully before the next size begins.

After the one-error and 1,000-error publications settle, the client separately
requests quick fixes across the document. The old build must return MethodNotFound.
The new build must return exactly one or 1,000 versioned operator fixes. A broad
request tests the maximum output path; a normal cursor request usually selects
one offer. Action timing starts before the stdio write and ends on receipt of
the complete response, including JSON handling in the client reader.

Diagnostic time includes transport, intake, parsing, validation, position
conversion and serialization. HTML timing includes the merged publication.
The actual macOS `wait4` RSS peak covers the whole process, including action
requests; it is not a diagnostic-stage-only peak. Settled RSS is sampled after
background work becomes quiet. Startup is launch-to-initialize-response time.
All MB values are decimal. Raw results are in `quick-fixes/before.json` and
`quick-fixes/after.json`. `quick-fixes/restore-baseline.patch` records the main
server source change needed to rebuild the baseline with the same build options.
Small local timing differences can be scheduling noise.

### Results

Apple M4 Pro, 14 logical CPUs and 48 GiB RAM; Zig 0.16.0 ReleaseSafe, page
allocator and buffered JSON. The clean-open table uses medians of three runs.
RSS is the maximum actual process peak across those runs, not a sampled peak.
HTML figures refer to the merged result and repeated label bodies.

| File | Layout | Old clean open | New clean open | Old peak RSS | New peak RSS |
| --- | --- | ---: | ---: | ---: | ---: |
| 5 MB | plain | 34.0 ms | 30.9 ms | 17.84 MB | 17.89 MB |
| 5 MB | html | 31.1 ms | 29.5 ms | 17.96 MB | 17.99 MB |
| 20 MB | plain | 106.5 ms | 97.5 ms | 63.83 MB | 63.91 MB |
| 20 MB | html | 88.9 ms | 92.3 ms | 63.91 MB | 63.98 MB |
| 40 MB | plain | 185.5 ms | 179.0 ms | 125.16 MB | 125.21 MB |
| 40 MB | html | 161.4 ms | 163.2 ms | 125.21 MB | 125.24 MB |

| File | Layout | One error, old -> new | 1,000 errors, old -> new | One action request | 1,000-action request |
| --- | --- | ---: | ---: | ---: | ---: |
| 5 MB | plain | 38.0 -> 35.8 ms | 40.3 -> 36.9 ms | 0.22 ms | 2.51 ms |
| 5 MB | html | 33.5 -> 30.9 ms | 38.6 -> 36.8 ms | 0.22 ms | 2.40 ms |
| 20 MB | plain | 116.5 -> 111.0 ms | 114.9 -> 112.4 ms | 0.27 ms | 2.19 ms |
| 20 MB | html | 106.5 -> 101.6 ms | 109.0 -> 104.9 ms | 0.15 ms | 1.50 ms |
| 40 MB | plain | 207.7 -> 206.6 ms | 207.4 -> 210.1 ms | 0.16 ms | 2.11 ms |
| 40 MB | html | 187.2 -> 196.4 ms | 190.6 -> 187.0 ms | 0.20 ms | 1.62 ms |

There is no consistent diagnostic slowdown across these small samples. Some
new-build medians are lower; no speed improvement is claimed. At 40 MB, one
HTML-heavy error rises from 187.2 to 196.4 ms while the 1,000-error result falls
from 190.6 to 187.0 ms. Repeat and release p95 measurements are still needed to
make a typing-latency guarantee.

The largest peak RSS increase is about 0.082 MB across the measured cases.
At 40 MB, settled RSS after requesting all 1,000 actions is 35.95 -> 36.04 MB for
plain DOT and 22.04 -> 22.12 MB for repeated HTML. After the final repair, it is
35.95 -> 36.00 MB and 22.04 -> 22.07 MB respectively. This includes binary pages,
worker state and existing indexes; it is not just the edit catalog's payload.

Median initialized idle RSS is 2.179 MB for both builds. Initialize turnaround
is 5.23 -> 4.67 ms; no startup improvement is claimed. Binary size is
801,368 -> 836,312 bytes. Retained AST memory remains zero.

Single-offer requests take 0.15-0.27 ms across the case medians. Broad requests
returning all 1,000 offers take 1.50-2.51 ms. At 40 MB the broad responses are
about 290 KB. These are LSP request measurements, not Zed popup timing.

All 36 server processes completed normally. All 180 document versions produced
the expected diagnostic counts. The new build returned the expected versioned
edits for all 36 measured action requests. The old build correctly returned
MethodNotFound for the same requests. No benchmark overlapped compilation,
protocol tests or the interactive Zed checks.
