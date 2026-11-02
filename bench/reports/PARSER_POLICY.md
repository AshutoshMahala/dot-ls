> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

# dot-ls DOT policy and streaming validation

Implemented 2026-10-15. `src/parser_policy.zig` defines the named `dot_ls`
policy. It starts from dot-parser's `standard` preset. It selects the block
scanner, metering, cancellation and a nesting limit of 256. It collects syntax
errors, preserves operators as written, and keeps no DOT AST.

| Check | dot-ls behavior |
| --- | --- |
| Malformed syntax and unsupported syntax | Existing parser errors |
| Ambiguous numerals | Existing parser warning |
| `->` in `graph`, or `--` in `digraph` | Error at each mismatching operator |
| Invalid UTF-8 source | Error at each invalid source unit |
| Repeated logical attribute key in one statement | Warning at the later key, with the first key as a related location |
| Valid graph kinds, ports and subgraphs | Allowed; restriction rules stay off |

Repeated keys are legal DOT. The warning asks the author to check the override.
It does not reject the statement. Separate statements can set the same key
without a warning. Combined attribute lists on one statement share one key
set. Quoted, concatenated and bare spellings use dot-parser's logical identifier
hash and exact comparison. Hash collisions alone never produce a warning.

## How the checks run

`MeasureSession` still performs count-only parsing. A local optional event
observer sends completed headers, attributes, edges, links and statement/scope
boundaries to `src/validation.zig`. No event stream or AST is retained. The
header supplies the expected edge kind. Continuation operators that lead into
subgraph endpoints are checked at scope entry. The other operators are checked
at their edge events. Nested statement state cannot leak into its parent.

The checker keeps a fixed 512-slot key table, about 12 KiB plus small state,
for the active statement. It records at most 256 distinct logical keys.
Generation tags reset the table without clearing it for every statement.
Keys longer than 4,096 source bytes and lookups requiring more than 16 probes
are skipped with an explicit incomplete notice. These bounds limit validation
work; they do not make otherwise valid DOT a syntax error. Later statements
still receive checks. No allocation depends on the number of statements.

Encoding uses a separate scan over the borrowed source, including comments,
quoted text and HTML bodies. ASCII blocks bypass scalar decoding. The scan
polls cancellation between chunks of at most 4,096 bytes, plus up to three bytes
for a UTF-8 sequence crossing a chunk boundary. It makes no source copy and
allocates no index. LSP text normally arrives as valid Unicode; the source check
also protects direct callers and is tested with malformed raw bytes.

The existing block parser, credit budget and cancellation checks stay active.
The parser's returned `MeasureResult` describes syntax parsing. The shared bag
also contains streaming validation findings and its explicit incomplete state.
The LSP layer maps those findings into negotiated positions and related notes.
DOT diagnostics publish before delayed HTML work. The merged HTML publication
preserves the DOT findings.

The shared DOT finding limit remains 1,000. Errors and warnings share this
budget; earlier warnings can consume space before later errors. Reaching it
reports validation as
incomplete. If syntax analysis already reports incomplete, one existing syntax
notice covers the incomplete analysis instead of adding a duplicate notice.
Syntax recovery can stop event delivery; checks after that point are not claimed
as complete. Existing generation checks prevent obsolete results from publishing.

The event bridge is a local vendored extension, recorded in
`vendor/patches/stream-validation.patch`. The project contains all required
sources. No separate parser checkout, new library, thread or editor setting is
required. The existing HTML policy is separate. Its Graphviz element/attribute
vocabulary checks remain deferred; this increment adds DOT validation.

## Verification

- Debug and ReleaseSafe project unit tests passed.
- ReleaseSafe vendored-parser tests passed.
- Streaming findings were compared with `parseAndValidate` on small retained
  documents used only as test oracles. Tests include directed and undirected
  graphs, mixed chains, scoped endpoints, nested statements, logical keys and
  combined attribute lists. Production retains no document.
- Unit tests cover invalid UTF-8 in comments, strings and HTML, valid non-ASCII
  text, encoding cancellation, bounded duplicate state and reset behavior. A separate
  regression test verifies that cancellation during source scanning clears
  successful parse capacities and marks the result incomplete.
- `tests/validation.py` checks wire severity, source ranges, related locations,
  UTF-8/16/32 positions, repair, key/table limits, 1,200 operator errors truncated
  explicitly to 1,000 findings, and preservation during HTML merging.
- Existing core LSP, HTML, reference and completion protocol tests passed.

## Controlled performance comparison

The measurements use `tools/policy_bench.py` and the resource client from
`tools/server_compare.py`. Both builds are native Zig 0.16.0 ReleaseSafe on the
same Apple M4 Pro. The page allocator, JSON storage, HTML cache and reference
index are unchanged. No Zed or other editor process is included.

Each build runs three fresh processes for each of the 5/20/40 MB plain DOT and
HTML-heavy fixtures. Files use the previous controlled comparison layout;
HTML bodies repeat to exercise the same cache behavior in both builds. Each
process receives six versions: clean open, one wrong operator, repair, 1,000
wrong operators, 1,000 repeated keys and a final repair. Messages are encoded
before timing. Operator variants preserve file size. Repeated-key variants add
8,000 bytes in plain DOT and 10,000 bytes in HTML-heavy DOT.

Time runs from the start of the stdio write to receipt of the full diagnostic
frame. It includes intake, parsing, validation and diagnostic presentation.
HTML results include the delayed merged publication. Startup runs from process
launch to initialize response. RSS uses the child's actual macOS `wait4`
high-water mark for the whole process, including all six versions; settled RSS
is sampled after work becomes quiet. MB means decimal MB.

Old builds do not report either class of inserted validation finding. Their
broken-file times therefore measure intake and parsing, without the new
reporting work. At 1,000 findings, the new build conservatively emits an
incomplete notice because the finding budget is full. All versions and expected
counts are checked by the harness.

Raw results are in `parser-policy/before.json` and `parser-policy/after.json`.
The initial development run overlapped compilation and protocol tests. It is
preserved as `parser-policy/excluded-before-overlapping-development.json` and
is excluded. `parser-policy/candidate-before-cancellation-fix.json` preserves an
  earlier candidate; it is also excluded from the final tables. Both reported
  runs have no overlapping build or test workload.
Small local timing differences can be scheduling noise. These samples are
comparisons, not release performance guarantees.

### Results

| File | Layout | Old clean open | New clean open | Old peak RSS | New peak RSS |
| --- | --- | ---: | ---: | ---: | ---: |
| 5 MB | plain | 40.1 ms | 43.3 ms | 17.84 MB | 17.86 MB |
| 5 MB | html | 37.9 ms | 39.8 ms | 17.96 MB | 17.96 MB |
| 20 MB | plain | 95.8 ms | 109.4 ms | 63.82 MB | 63.83 MB |
| 20 MB | html | 95.3 ms | 96.6 ms | 63.93 MB | 63.90 MB |
| 40 MB | plain | 177.3 ms | 187.3 ms | 125.08 MB | 125.08 MB |
| 40 MB | html | 155.8 ms | 160.4 ms | 125.17 MB | 125.17 MB |

| 40 MB layout | Inserted findings | Old delay (missed) | New delay (reported) |
| --- | --- | ---: | ---: |
| plain | operator-1 | 181.4 ms | 204.4 ms |
| plain | operator-1000 | 174.5 ms | 205.2 ms |
| plain | duplicates-1000 | 182.0 ms | 202.4 ms |
| html | operator-1 | 154.8 ms | 184.5 ms |
| html | operator-1000 | 156.4 ms | 191.8 ms |
| html | duplicates-1000 | 154.1 ms | 183.7 ms |

Clean-open medians use three observations per case. At 40 MB, the added checks
raise measured delay by about 10.0 ms for plain DOT and 4.6 ms for the merged
HTML result. At 20 MB, plain clean-open delay rises by 13.6 ms. Individual trials
and repair times show visible scheduling variation. For example, the 20 MB
plain final-repair medians are 103.4 ms before and 100.1 ms after. These timings
include the entire server path and do not isolate the validator's CPU cost.

The new erroneous-file results include line-index creation, related locations,
wording and JSON output that the old build did not need. One wrong operator at
40 MB takes 204.4 ms in plain DOT and 184.5 ms in HTML-heavy DOT. Reporting 1,000
operator errors takes 205.2 ms and 191.8 ms respectively. The warning workloads
also include 1,000 related locations. The counts do not imply that the cost per
finding is zero; these are small samples with shared scan and transport costs.

Peak RSS is effectively unchanged. The largest measured increase across these
cases is about 0.016 MB. Median initialized idle RSS is 2.179 MB for both builds.
Median initialize turnaround is 7.01 ms before and 5.53 ms after; no startup
improvement is claimed. The executable grows from 800,760 to 801,368 bytes.
The fixed validation table lives in the analysis stack frame, not in each
retained document. Stack pages can stay resident after return. At 40 MB, settled
RSS after the final repair is 35.93 -> 35.95 MB for plain DOT and 22.04 -> 22.04 MB
for HTML-heavy DOT. Retained AST memory remains zero.

All 36 reported server processes completed and shut down cleanly. All 216
versions returned the expected diagnostics. No responsiveness gate stopped a
larger case. This workload uses repeated HTML bodies; the separate full-label
coverage study remains the evidence for large unique HTML bodies.
