> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

# Zed editing and context-aware completion

Measured on 2026-10-15. The Zed adapter now pairs braces, square brackets and
quotes. Enter indents blocks and attribute lists. DOT keyword completion now
uses lexical context, including incomplete documents. There is no retained AST,
source cache, extra server library or extra worker thread.

## Editor behavior

The adapter uses the distinct language name **DOT (dot-ls)**. This avoids a name
collision with the installed Graphviz extension's DOT configuration. The project
file-type mapping selects it for `.dot`, `.gv` and `.DOT`. The adapter includes
its own pinned Tree-sitter grammar and small queries for indentation, brackets,
highlights and string/comment exclusions. These run inside Zed, outside the LSP
server. The grammar is the same pinned upstream revision used by Graphviz 0.2.1.
See [Zed's language extension documentation](https://zed.dev/docs/extensions/languages).

Verified in the running Zed instance: typing `{` inserts `}`; Enter creates an
indented body line and a separate closing line. Nested subgraphs and `[]`
attribute lists also pair and indent. The status bar shows DOT (dot-ls).
The adapter was reinstalled and the local language server restarted.
User buffers with unsaved changes were left intact. In Zed, body completion
showed four keywords and endpoint completion showed only subgraph. A brace typed
inside a quoted string did not insert a closing brace.

## Completion behavior and storage

| Location | Candidates |
| --- | --- |
| Document header | graph, digraph, strict |
| After strict | graph, digraph |
| Graph/subgraph statement body | graph, node, edge, subgraph |
| After an edge operator | subgraph |
| Names, ports, attributes, assignments, strings, comments, HTML-like content | none |

The editor filters prefixes. It can also offer its own word candidates. The
server's context machine provides conservative editing hints; dot-parser remains
the syntax validator. It uses the public block lexer with bounded scanning.
A lexical failure masks the unknown suffix. Known contexts before it still work.

The worker publishes diagnostics first, then builds completion context, then
interns node references. Context transitions use delta varints with a sparse
anchor every 128 transitions. Position metadata stores four-byte line starts,
including CRLF flags, plus sparse Unicode byte/unit corrections. Lookups need
no document source. The complete context index is limited to 64 MiB per document
and 128 MiB across documents. Growth/capacity overlap is additional temporary
memory. New syntax or large packet intake makes background construction yield;
obsolete generations are cancelled. Yielded context construction restarts.

Completion requests can wait for the current index. They share the existing
64-request queue per document with references. Cancellation, edit/close
invalidation, copied request IDs, and explicit resource failures are supported.
There is no broad static fallback when context is unavailable.

## Normal server comparison

Both binaries use Zig 0.16.0 ReleaseSafe, page allocation, buffered JSON, the
same vendored parser and fixtures. One fresh process per size receives a
pre-encoded open and three error/repair pairs. Diagnostic values below are edit
medians. Completion readiness is measured after the final repair diagnostic.
Memory values use decimal MB. Peak RSS comes from actual macOS `time -l`, not
sparse samples. Zed remained open with the user's existing buffers. No build or
other benchmark ran concurrently. These are local samples, not performance gates.

| Input | Repair diagnostics, before → after | Error diagnostics, before → after | Completion ready after diagnostics | Settled server RSS, before → after | Peak server RSS, before → after |
| --- | ---: | ---: | ---: | ---: | ---: |
| 5 MB | 20.5 → 19.7 ms | 24.9 → 22.8 ms | 15.8 ms | 5.65 → 6.73 MB | 19.86 → 19.82 MB |
| 20 MB | 81.8 → 77.4 ms | 93.4 → 86.6 ms | 63.4 ms | 15.45 → 19.74 MB | 70.76 → 70.76 MB |
| 40 MB | 159.3 → 159.0 ms | 178.5 → 181.5 ms | 125.6 ms | 28.51 → 37.08 MB | 140.87 → 140.85 MB |
| 100 MB | 396.0 → 398.3 ms | 445.2 → 452.9 ms | 315.1 ms | 67.68 → 89.08 MB | 343.79 → 344.47 MB |

Diagnostics show no material regression. Ready completion requests measured
about 0.03–0.04 ms. Idle RSS remained 2.13 MB; RSS after close remained about
2.36 MB. The binary grew from 679,096 to 714,728 bytes (35,632 bytes).
Protocol initialization in the standalone smoke test measured a 2.55 ms median.
The time-wrapped benchmark's launch measurements include its wrapper overhead;
see raw samples rather than comparing those directly with the smoke test.

The new context pass is a measurable cost. It delays the first completion after
an edit and also delays reference readiness. At 40 MB, reference work then takes
another 81.6 ms after context readiness, for about 207 ms after diagnostics in
total. At 100 MB, it takes another 304.4 ms, for about 620 ms in total. Before,
references were ready about 76.5 ms and 297.6 ms after diagnostics. Ready
reference lookups remain about 0.48 ms and 1.08 ms. The source snapshot now lives
through the extra pass. Peak RSS stays close because JSON intake still dominates
these fixtures. This does not mean the new index has no memory cost.

## Context-only profile

Five isolated runs per file. These exclude transport, JSON, parsing diagnostics,
and reference interning. Allocation counters include array capacities and growth
overlap. The `positions` category contains only context construction; the input
category is the separate source and its read-buffer growth. These allocator
numbers are not RSS and must not be added to independent RSS peaks.

| Input | Lexical regions | Position metadata | Transitions | Anchors | Line starts | Retained context | Construction peak |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 5 MB | 14.9 ms | 1.0 ms | 0.612 MB | 0.048 MB | 0.408 MB | 1.068 MB | 1.892 MB |
| 20 MB | 58.0 ms | 3.7 ms | 2.449 MB | 0.191 MB | 1.633 MB | 4.273 MB | 6.476 MB |
| 40 MB | 119.3 ms | 7.8 ms | 4.898 MB | 0.383 MB | 3.265 MB | 8.546 MB | 14.374 MB |
| 100 MB | 291.8 ms | 19.2 ms | 12.245 MB | 0.957 MB | 8.163 MB | 21.365 MB | 32.791 MB |

The examples are ASCII, so their Unicode correction array is empty. Non-ASCII
files can cost more. Dense newlines or Unicode can reach the context limit
before the source limit. Diagnostics remain independent of context success.

## Validation and reproduction

Debug and ReleaseSafe unit tests cover context selection, incomplete input,
sparse-anchor lookup, Unicode/line endings, cancellation, yielding and allocation
failure cleanup. Protocol tests cover UTF-8/16/32, current-generation responses,
request cancellation, edit/close invalidation, references and diagnostics. The
same protocol checks also passed with the debug allocator and in-place JSON.
The real Neovim client attached, received diagnostics/completion/references,
repaired syntax and shut down. Zed pairing and indentation were checked manually.

Run from the project root:

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseSafe
python3 tests/lsp.py
python3 tests/completion.py
python3 tests/references.py
python3 tools/completion_bench.py after zig-out/bin/dot-ls 5 20 40 100
python3 tools/prepare_context_profile.py
# In the printed temporary folder:
zig build profile-context -Doptimize=ReleaseSafe
# Run context-profile with an absolute example path; it emits JSON on stderr.
```

Raw evidence: [baseline](../results/legacy/completion-context-before-5-20-40-100.json),
[current server](../results/legacy/completion-context-after-5-20-40-100.json),
[context stage profile](../results/legacy/completion-context-profile.json).
