# Benchmark evidence

This directory stores development evidence, not server runtime input.
Current design and behavior are in [docs](../docs/README.md).

| Path | Purpose |
| --- | --- |
| `results/outline/` | Latest measured executable: diagnostics, retained/peak server memory and outline turnaround |
| `results/quick-fixes/` | Quick-fix before/after comparison |
| `results/parser-policy/` | Custom policy validation comparison |
| `results/html-label-cap/` | Full-label coverage and bounded selection work |
| `results/server-comparison-2026-10-15/` | Controlled dot-ls / dot-language-server comparison |
| `results/zed-*` | Editor measurements; separate from server-only RSS |
| `results/legacy/` | Earlier flat measurement files, retained without changing their raw contents |
| `reports/` | Historical narratives, marked with the build/time context |
| `history/tools/` | Retired instrumentation that patched earlier source layouts |
| `history/layout-migration.json` | Old/new paths and original hashes for the documentation cleanup |

Useful historical reports:

- [Latest outline increment](reports/DOCUMENT_OUTLINE.md)
- [Parser policy](reports/PARSER_POLICY.md) and [quick fixes](reports/CODE_ACTIONS.md)
- [Reference index construction](reports/INDEX_OPTIMIZATION.md)
- [HTML reuse](reports/HTML_LABELS.md) and [full-label coverage](reports/HTML_LABEL_CAP.md)
- [Controlled server comparison](reports/SERVER_COMPARISON.md)
- [Isolated Zed measurements](reports/ZED_EDITOR_PERFORMANCE.md) and
  [grammar memory experiment](reports/ZED_GRAMMAR_MEMORY.md)

A report can be correct for its measured build and still be obsolete as product
documentation. Its statements about missing features, defaults and limits are
historical. Use current feature and requirement documents for those facts.

## Measurement rules

1. Preserve the before binary and its hash. Record both build options.
2. Use identical fixture bytes, protocol capabilities and client timing boundaries.
3. Start with 5 MB. Increase to 20 and 40 MB only when the earlier case is responsive.
   Create the large fixtures with `python3 tools/make_large_examples.py`; Git does not track them.
4. Include clean, broken and repaired versions when relevant. For diagnostics caps,
   count errors and incomplete notices, not only the final response time.
5. Measure diagnostics, index readiness and feature response time separately.
6. Report idle, settled and actual peak server RSS. Requested allocator bytes and
   periodic RSS samples are different measurements. Do not call either an exact
   process peak. State whether editor memory is included.
7. Preserve raw records and their summary. Record excluded or overlapping runs.
8. Use a new case/date directory for new experiments. Existing scripts with fixed
   before/after paths need their previous results snapshotted before reuse.

Recompute the latest outline summary without launching servers:

```sh
python3 tools/summarize_outline_bench.py
```

The measurement runners are listed in [tools/README.md](../tools/README.md).
No production build or protocol test may require this directory. The Zig package
file list does not include these raw benchmark records.
