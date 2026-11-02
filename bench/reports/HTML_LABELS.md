> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

# Delayed HTML-like label checks

Implemented on 2026-10-15. DOT diagnostics publish first. The worker then checks
selected HTML-like labels and sends a merged set for the same current version.
Completion context and reference indexing follow. No AST is retained.

## What is checked

The DOT count session reports complete attribute and assignment key/value spans.
The analysis layer selects logical keys `label`, `xlabel`, `headlabel` and
`taillabel` whose values are HTML-like IDs. Quoted and concatenated key spellings
are supported. The DOT wrapper is excluded from the markup fragment. Quoted
values stay ordinary DOT strings. HTML-like node IDs and unrelated attribute
values are not checked as labels.

The existing markup subsystem checks tag balance, mismatched/unclosed tags,
malformed references and local validation such as duplicate attributes. It uses
untrusted limits and Graphviz case-insensitive tag matching. Allowed-tag and
per-element attribute vocabulary checks remain deferred. This is not browser
HTML validation or complete Graphviz label validation.

## Reuse and source positions

The cache keeps exact HTML bytes and fragment-relative diagnostics, including
clean results. It checks content equality after hashing. Equal-length edits
cannot incorrectly reuse a result. Identical fragments in one document share a
check and payload. Outer-only edits reuse unchanged labels; changing one label
rechecks it and reuses unchanged siblings. Moving a label requires new document
positions, but not a new markup check. Ranges and related locations use the new
source and negotiated UTF-8/16/32 encoding.

The current full-sync implementation still parses all outer DOT on each edit.
An edit inside HTML can change quotes, angle boundaries or token recognition.
A newline can change content and later line/column positions. This increment
does not prove that the outer parse can be skipped. It avoids redundant inner
checks without retaining an entire previous document.

DOT findings stay in the later merged publication. Every publication checks the
current document generation under the server lock. New DOT work and large packet
intake interrupt HTML parsing, validation and coordinate mapping. Completed
fragment results survive a yield; the interrupted fragment is retried. The markup
measure and local-validation calls are cancellable one-shot operations, not fully
resumable validation sessions. The complete 5 ms cancellation/cleanup release
gate remains unproven. A changed
or closed document cancels obsolete work. The first DOT publication can briefly
clear earlier HTML underlines until the merged result arrives.

## Ownership, allocation and limits

Documents own published caches. Jobs retain an immutable previous cache and own
a new cache under construction. Entries have explicit reference counts and their
own allocator. Unchanged entries can be shared across generations. Close drops
document ownership; completed/cancelled jobs drop their own references.

The first candidate allocated every small cache object directly with the page
allocator. On this macOS machine, that cost roughly 33 MB of added settled RSS
for 4 MB of payload. The selected design packs small cache entries into shared
pages with a local, thread-safe `std.heap.DebugAllocator`, with stack traces
disabled. Its backing allocator is the selected process allocator. Empty buckets
are returned. Source, protocol and large index storage keep the existing
allocator. This adds no library, thread or global hidden allocator.

- Cached payload: 8 MiB and 4,096 entries per document.
- All live retained payload, including in-flight generations: 32 MiB and 16,384
  distinct entries. Shared entries count once. Payload includes entry records,
  exact fragment bytes and cached diagnostics. Hash-table/bucket capacity and
  selected-span storage are additional bounded metadata.
- Selection: ordered spans use unsigned gap/length varints, with no label-count
  cap. Requested capacity is at most `source_bytes / 4 + 16` per job. At the
  existing 200 MiB file ceiling, this is 50 MiB plus 16 bytes of retained metadata
  in the worst case. Real dense fixtures use much less. A resize may briefly
  hold old and new buffers; allocator page rounding adds physical overhead.
  Selection still comes from the outer parser in one pass.
- Untrusted fragment: 8 MiB, 256 nested elements, 100,000 nodes and 200,000
  attributes. Parsing uses fixed nesting scratch and a counting sink, not a tree.
- Local validation scratch: at most 1,024 attributes in an opening header.
- Findings: 64 per fragment, 1,000 combined findings, plus incomplete notices.

Cache pressure causes later rechecking, not skipped checks. Checking/resource
limits produce an explicit `dot-ls:html-incomplete` notice. Known labels before a
DOT failure can still be checked; recovery after that failure remains a parser
limitation. No document text is written to logs.


The label-count cutoff was removed after the initial measurements below. See
[full-label coverage and bounded selection storage](HTML_LABEL_CAP.md) for the
20/40 MB repeated/unique results and tail-error checks.

## Validation

Unit tests cover parser-selected positions, exact reuse, duplicate fragments,
equal-length content changes, local coordinates, cancellation, yields, allocation
failure cleanup, shared ownership and live-generation budgets. Protocol tests
cover staged merge, all label keys, ordinary quoted values, UTF-8/16/32,
BOM/CRLF/lone CR, moved labels, related positions, repairs, limits and obsolete
versions. The same protocol suite passes with debug allocation and in-place
JSON. Existing diagnostics, completion and references regressions also pass.
In Zed, the example showed the mismatched `</TABLE>`/`<TR>` message and related
opener underline. Inserting `</TR>` cleared it without saving. The intentional
error was restored afterward. Other user buffers were not edited.

The vendored parser change is a small optional count-session attribute observer.
It changes no grammar and cannot stop syntax parsing on a consumer limit. See
[the local patch](../history/vendor-patches-9ea41c81/html-label-spans.patch).

## Reproduction

Run from the project root with Zig 0.16.0:

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseSafe
python3 tests/html.py
python3 tests/lsp.py
python3 tests/completion.py
python3 tests/references.py
python3 tools/html_bench.py after zig-out/bin/dot-ls
python3 tools/html_bench.py fixtures /private/tmp/dot-html-fixtures
python3 tools/prepare_html_profile.py
# In the printed temporary folder:
zig build profile-html -Doptimize=ReleaseSafe
# Pass the initial, outer_only, one_html_edit and outer_newline fixture paths
# to html-profile in that order. It writes counts/timings/allocations to stderr.
```

The example [html-labels.dot](../../examples/html-labels.dot) has an intentional
mismatched label for editor testing. Add `</TR>` before `</TABLE>` to repair it.

## Measured results

All figures are local macOS samples, using Zig 0.16.0 ReleaseSafe. MB means
1,000,000 bytes. RSS is server process memory, not Zed memory. The server's
background work finishes before settled RSS is sampled. Actual peak RSS uses
macOS `time -l`. Zed stayed open with its existing user buffers. Benchmarks and
builds did not run concurrently. The fixture generator and all raw data are
preserved. These measurements are not a release performance guarantee.

### What was rechecked

The HTML-heavy fixtures contain 1,000 distinct labels with about 4 MB total HTML.
The last label has a mismatched closer. Five fresh core-profile runs per size
perform four successive source versions. Results for the 40 MB file:

| Edit | Fragment checks | Reused fragments | HTML check/cache work |
| --- | ---: | ---: | ---: |
| First check | 1000 | 0 | 2.538 ms |
| Outer DOT edit | 0 | 1000 | 0.906 ms |
| One HTML edit | 1 | 999 | 0.892 ms |
| Outer newline | 0 | 1000 | 0.905 ms |

These times exclude DOT parsing, protocol/JSON, source-position mapping, and
completion/reference indexing. HTML/cache work takes about the same time in
the 5 MB file because the HTML content is the same. The retained payload is
4,062,072 bytes. Payload excludes hash-table capacity and allocator buckets.

### Complete server and memory

Each size uses a fresh process and four successive full-sync versions. The
following timings are the outer-only edit sample, measured from a pre-encoded
request through each publication. The merged result includes cached HTML
findings and new source-position mapping. Completion and references follow.
Before this feature, the server did not check HTML at all.

| File | First DOT publication | Merged HTML publication | Settled RSS, before → after | Peak RSS, before → after |
| --- | ---: | ---: | ---: | ---: |
| 5 MB | 9.6 ms | 12.9 ms | 3.29 → 8.03 MB | 17.51 → 22.27 MB |
| 40 MB | 162.5 ms | 184.6 ms | 33.64 → 38.37 MB | 124.78 → 129.53 MB |

The selected allocator adds about 4.7 MB settled RSS for the 4.06 MB cached
payload. The page-allocation candidate instead reached 36.27 MB settled RSS
on the 5 MB fixture and 66.60 MB on the 40 MB fixture. Packing reduced those to
8.03 MB and 38.37 MB. The corresponding peaks fell from 50.51/157.76 MB to
22.27/129.53 MB. The candidate is preserved; it is not the installed binary.

For an outer edit on the 40 MB fixture, the merged publication arrives about
22 ms after DOT findings. Actual cached HTML work is about 0.9 ms; mapping the
relative findings into current document positions accounts for most of the
remaining time. This scan remains an optimization opportunity. Clean labels
with no findings do not need that position index.

Idle RSS is about 2.15 MB. RSS after closing the HTML-heavy document is about
2.46 MB, compared with 2.36 MB before the feature. Cache entries and source are
released; small allocator bookkeeping and process pages account for the RSS
floor. The binary grew from 714,728 to 800,824 bytes.

### Label-free regression control

Separate before/after runs showed higher error-edit latency. An interleaved
control isolated a larger regression introduced by sharing background-yielding
position conversion with the foreground path. Compile-time specialization keeps
that extra check out of foreground conversion. The earlier results are kept.

The final control alternates binaries, reverses their order on alternate rounds,
and waits for all background work after every sample. Five error/repair pairs:

| File | Repair diagnostics, before → after | Error diagnostics, before → after |
| --- | ---: | ---: |
| 40 MB | 155.6 → 161.1 ms | 177.3 → 182.9 ms |
| 100 MB | 401.7 → 420.7 ms | 448.8 → 467.7 ms |

The remaining local overhead is about 3–5%. Label-free settled RSS remains about
37.1 MB at 40 MB and 89.1 MB at 100 MB. Actual peaks remain about 141 MB and
345 MB. The separate RSS runs are not the interleaved timing test, so their
latencies must not be mixed with this table. Larger corpus and release targets
still need calibration.

Raw evidence:

- [HTML baseline](../results/legacy/html-before.json), [selected server](../results/legacy/html-after.json),
  [page-allocation candidate](../results/legacy/html-page-candidate.json).
- [Fragment counts and allocator profile](../results/legacy/html-cache-profile.json).
- [Final interleaved control](../results/legacy/html-label-free-interleaved.json),
  [before position specialization](../results/legacy/html-label-free-before-position-specialization.json).
- [Label-free baseline RSS](../results/legacy/completion-context-html-before-40-100.json),
  [selected server RSS](../results/legacy/completion-context-html-after-40-100.json).
