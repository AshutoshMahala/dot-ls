> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

# Zed grammar memory study

Measured 2026-10-15. The compact grammar materially reduces editor memory.
At 40 MB, the full HTML editor case drops from 2.92 GB to 1.84 GB RSS.
The DOT-only baseline drops from 2.01 GB to 939 MB.
No dot-ls server ran in these editor tests. These numbers are Zed's memory.

## Method

Use the same machine, Zed 1.24.2, isolated profiles, theme, window size and
HTML-heavy files as [the earlier editor study](ZED_EDITOR_PERFORMANCE.md).
Each 170-byte record has one multiline HTML label and one edge.
The 5/20/40 MB files contain 29,411 / 117,646 / 235,293 HTML labels.
“DOT-only” means the same input with embedded HTML parsing disabled. It does
not mean a different file without HTML bytes.

Fresh processes were used for open comparisons. Test profiles kept language
servers and Zed's performance profiler disabled. The app was an isolated copy of
the installed app with a separate bundle identifier. Its code was not patched.
The user's settings and buffers were not changed.

Three measurements answer different questions:

- `proc_pid_rusage`: main-process RSS, footprint and CPU counters during normal runs.
- `vmmap`, `heap` and `malloc_history`: live allocation attribution in separate runs.
  Stack logging changes resource use. Logged RSS and CPU are not benchmark results.
- Native Tree-sitter allocator probe: requested live parser/tree bytes, allocation
  counts and node counts. Separate runs without the allocator hook measure parsing.
  This excludes source storage, HTML injection, renderer and all other Zed work.

The normal open results are single editor runs, not statistical timing estimates.
CPU deltas include editor work between manual UI markers. They are not elapsed
open latency, keyboard-to-paint latency or frame times. Two quiet one-second
intervals were used to settle new runs. Large unrelated applications can affect
scheduling. The direct parser timing is the median of three uninstrumented runs.

## Where memory goes

A fresh DOT-only 5 MB allocation profile gives this breakdown:

| Measurement | Empty window | File open |
| --- | ---: | ---: |
| Live malloc bytes from `heap` | 49.2 MB | 278.6 MB |
| Live malloc blocks | 93,864 | 2,170,091 |
| Physical footprint from `vmmap` | 146.0 MiB | 406.0 MiB |
| Graphics IOSurface dirty memory | 47.4 MiB | 71.1 MiB |

The empty editor already has UI, fonts, rendering and extension machinery.
Opening the file adds about 229 MB of live heap, mainly millions of small blocks.
The stack-logged DOT-only run attributes about **204 MiB and 2,058,791 live
allocations** to `ts_parser_parse_with_options` / `ts_parser_parse`.
The native allocation probe independently records 2,058,816 allocation calls
for the same DOT grammar and bytes. The close count supports the attribution:
the large DOT-only cost is chiefly the outer syntax tree.

With full HTML features, the corresponding parser stack group grows to about
**287 MiB and 2,875,254 live allocations** at 5 MB. This is about 83 MiB more
parser allocation, before other editor overhead. Some surrounding Rust frames
are stripped. We cannot label every remaining allocation precisely. The reports
also include tree handles, text storage and graphics; those are not all AST data.
The injected HTML trees remain an additional cost after compacting DOT.

The 12.2 GiB “Untagged” virtual region in `vmmap` has only about 3 MiB resident.
Do not count reserved address space as occupied RAM. Likewise, heap live bytes,
RSS and physical footprint use different accounting. Do not add these tables
or subtract one measure from another to obtain an exact remainder.
The current profiles do not establish a memory leak.

Raw reports are in [zed-grammar-study](../results/zed-grammar-study).
The full allocation call trees are compressed `.txt.gz` files. Their `.txt`
companions contain the first part for convenient inspection.

## Compact grammar

The candidate [source and release notes](../../editors/experiments/compact-dot/README.md)
retain the upstream MIT license. It uses a private `dot_ls` grammar name.
It inlines the `id` wrapper and treats each HTML body as one external token.
The outer delimiters remain separate nodes. The HTML injection still parses the
body with the existing HTML grammar. Existing editor queries compile unchanged.

Native retained allocations on the HTML-heavy workload:

| Grammar | 5 MB | 20 MB | 40 MB |
| --- | ---: | ---: | ---: |
| Original upstream | 192.3 MB | 768.5 MB | 1,536.5 MB |
| Same grammar regenerated with CLI 0.27.1 | 192.3 MB | 768.5 MB | 1,536.5 MB |
| One HTML body token, original ID wrappers | 84.7 MB | 338.4 MB | 676.3 MB |
| One HTML body token and inlined IDs | 66.6 MB | 265.7 MB | 531.1 MB |

The final candidate cuts native retained parser allocations by about **65%**.
Regeneration alone gives no memory saving. This control separates generator
changes from the actual grammar changes. All native runs release tracked bytes
to zero after tree and parser deletion. Allocator metadata and source bytes are
excluded. These figures are not expected to equal Zed RSS.

The earlier mostly plain-DOT examples also improve:

| Plain DOT input | Original native live bytes | Compact native live bytes |
| --- | ---: | ---: |
| 5 MB | 161.3 MB | 125.2 MB |
| 20 MB | 643.8 MB | 499.9 MB |
| 40 MB | 1,287.1 MB | 999.4 MB |

That is about 22% less for these files. The larger 65% saving depends on the
HTML-heavy layout; it is not a general memory ratio for arbitrary DOT files.

## Editor memory

Decimal MB below; RSS includes the empty editor baseline.
Original results come from the earlier isolated study on the same installed Zed.

| File | Original DOT-only | Compact DOT-only | Original full HTML | Compact full HTML |
| --- | ---: | ---: | ---: | ---: |
| 5 MB | 488.3 MB | 338.0 MB | 598.1 MB | 455.4 MB |
| 20 MB | 1,139.7 MB | 594.2 MB | 1,591.2 MB | 1,052.6 MB |
| 40 MB | 2,011.6 MB | 938.6 MB | 2,916.6 MB | 1,839.9 MB |

The full 40 MB case saves **1.08 GB RSS, or 37%**. DOT-only saves about 53%.
The full-minus-DOT-only difference remains about 901 MB at 40 MB. This experiment
reduces the outer tree; it does not eliminate the per-label HTML injection cost.
An optimization to the remaining HTML cost needs another controlled study.

After one 40 MB HTML text insert and undo, compact full RSS was about 2.24 GB.
Its sampled peak during the run was 2.39 GB. Editing still raises retained memory.
This sequence is not equivalent to the earlier repeated-edit peak experiments;
do not compare those peaks as a precise percentage saving.

## Performance

Native full-parse elapsed time, median of three runs without allocation hooks:

| HTML-heavy file | Original | Compact |
| --- | ---: | ---: |
| 5 MB | 0.303 s | 0.139 s |
| 20 MB | 1.199 s | 0.560 s |
| 40 MB | 2.445 s | 1.120 s |

Native parsing is about 54% faster for this workload. On mostly plain DOT,
40 MB takes 2.113 s originally and 1.920 s compact, about 9% faster.

Measured editor CPU between pre-open and opened markers:

| File | Original DOT-only | Compact DOT-only | Original full | Compact full |
| --- | ---: | ---: | ---: | ---: |
| 5 MB | 0.773 s | 0.738 s | 1.418 s | 1.249 s |
| 20 MB | 2.250 s | 1.554 s | 4.682 s | 3.814 s |
| 40 MB | 4.060 s | 2.765 s | 9.442 s | 7.422 s |

Editor gains are smaller than native parser gains because other editor work
remains. These single-run CPU figures are directional, not exact UI latency.
For one 40 MB HTML text insert, full editor CPU was 2.429 s original versus
2.294 s compact. Undo was 2.222 s versus 2.611 s. This does **not** establish
a consistent typing or undo speed improvement. The 20 MB undo interval was
interrupted by a long measurement pause and is excluded from timing claims.
The raw markers remain available. Smaller edit cases are not timing evidence.

A separate native incremental test edits the first text in one very large HTML
label with repeated tags. At about 1 MB, original/compact medians are 60.7/4.6 ms;
at about 5 MB, 313.9/21.6 ms. This checks an important whole-token tradeoff but
excludes HTML injection and the editor. It does not bound all malformed-input
behavior. Source and timing rows are retained for reproduction.

## Verification and provenance

- All 11 upstream corpus cases pass with snapshots adjusted for ID inlining.
- 51 additional checks pass: exact HTML ranges, quoted DOT strings, empty bodies,
  nested tags, multiline content, quoted angle brackets, XML comments, CDATA,
  Unicode, malformed input recovery, incremental-versus-fresh trees, and all DOT queries.
- In live isolated Zed, colors, outer pairing and wrapper fold/unfold were checked.
  The full 20 MB case remained responsive, then testing advanced to 40 MB.
  Typing, undo, folding and file navigation remained usable at 40 MB.
- The final scanner cleanup removes a duplicate branch for malformed `<!-[CDATA[`.
  Editor table runs used the immediately preceding build, SHA-256
  `6c48a503ff813e576a07613a183df633ab33520aca198653cde581c8d6820965`.
  The valid-input paths and tree schema are unchanged. Native candidate tables
  and the final 51/11 test runs use the cleaned source.
- Final WASM: ABI 14, 28,977 bytes, SHA-256
  `181be83c11fd2a80dcf2979812fbc03fdaa224363ce363dc8e7c785659df8c15`.
  The earlier compact heap profile uses a first build before the error sentinel;
  it is supporting allocation evidence, not the main editor comparison table.

Raw open/edit counters are `compact-{dot,full}-{5,20,40}.json`.
Native tables are `native.json` and `native-plain-dot.json`.
The native single-label edit rows are `native-large-label-*.json`.

## Shipping

This is a normal portable WASM grammar change, not a custom Zed memory patch.
Customers do not need the copied app, native probes, macOS profiling tools,
local extension-index edits or special allocator settings. The source, license,
ABI, build helper, tests and release steps are included in the project.

The candidate remains experimental. The production manifest still pins the
original grammar. A customer release must publish the candidate source, pin a
real immutable Git revision in `[grammars.dot_ls]`, select `dot_ls` in the language
configuration, and verify a normal Zed extension build. Cross-platform release
checks remain; these live measurements cover macOS only. Do not ship the
benchmark profile as an extension package.

The relevant public mechanisms are documented in
[Zed's language extension guide](https://zed.dev/docs/extensions/languages),
[Zed's extension builder](https://github.com/zed-industries/zed/blob/main/crates/extension/src/extension_builder.rs),
and [Tree-sitter's external scanner guide](https://tree-sitter.github.io/tree-sitter/creating-parsers/4-external-scanners.html).
