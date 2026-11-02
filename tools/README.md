# Development tools

These commands are not server dependencies. Run them from the project root.
Raw output belongs in `bench/results/`, never `docs/`.

| Tools | Purpose |
| --- | --- |
| `package_release.py` | Local native/compiled Zed candidate archives, license notices, version metadata and SHA256SUMS; no uploads |
| `check_release.py` | Archive/checksum/platform audit and clean extracted-binary protocol checks |
| `install_zed_local.py` | Seed a new isolated Zed profile with prebuilt extension and offline server cache |
| `check_vendor.py` | Reverse the declared parser patches in a temporary copy and verify exact upstream file hashes |
| `check_layout.py` | Check documentation links, directory policy, Python syntax and source import paths |
| `ci_report.py` | Run a check in GitHub Actions; on failure, show the last output lines as an annotation that needs no sign-in |
| `make_large_examples.py` | Write the large `examples/editor-*mb.dot` benchmark files, which are not in Git; checks their SHA-256 values |
| `stress.py` | macOS sustained full-text edits, queued cancellation, multi-document/error load, close/reopen cleanup and active shutdown; isolated server RSS |
| `server_compare.py`, `summarize_server_compare.py` | Controlled server comparison; macOS memory sampling; shared benchmark client |
| `attributes_bench.py`, `summarize_attributes_bench.py` | Before/after attribute-help diagnostics, readiness, hover latency and server memory |
| `outline_bench.py`, `summarize_outline_bench.py` | Outline diagnostics, request latency and memory comparison |
| `quickfix_bench.py`, `summarize_quickfix_bench.py` | Parser-fix cost and code-action response comparison |
| `policy_bench.py`, `summarize_policy_bench.py` | Stream validation comparison |
| `html_cap_bench.py` | Dense-label coverage, late findings and memory |
| `html_bench.py`, `html_control.py` | HTML reuse and label-free controls |
| `references_bench.py`, `references_startup.py`, `index_bench.py` | Reference/index and startup comparisons |
| `completion_bench.py`, `feature_bench.py`, `diagnostic_load_bench.py` | Completion, diagnostic presentation and error-load comparisons |
| `allocator_compare.py`, `intake_compare.py`, `intake_peak.py` | Existing allocator/JSON build-variant experiments |
| `zed_editor_bench.py`, `zed_memory_profile.py` | Editor process sampling and native memory profiles |
| `lsp_compare_proxy.py`, `compare_server_memory.py` | Editor LSP relay timing and separate server memory controls |
| `build_zed_grammar.py`, `zed_grammar_test.py`, `zed_grammar_edit_bench.py`, `zed_tree_memory.c` | Grammar experiment build, correctness, edit timing and allocation study |

Some runners require prepared binaries or native Tree-sitter/WASI tools. Check
the script's arguments and docstring before running it. macOS profiling commands
are development conveniences, not portable runtime requirements.

Run the server stress checks with:

```sh
python3 tools/stress.py zig-out/bin/dot-ls --output bench/results/stress-local
```

It tests 5/20/40 MB plain and HTML-heavy files in increasing size order. It stops
on failure. The default sends 30 edits per cycle, with three cycles per layout.
It also tests eight live files, completed 1,000-error checks, version reuse after
close/reopen and ten shutdowns during active work. Each input write and response
wait has a 15-second deadline. The shared monitor stops owned children at 6 GB RSS;
the workload also fails if its observed peak exceeds 1 GB. Normal builds must
return within 8 MB of initial idle RSS after each close. The debug-allocator mode
uses leak/error reports at clean exit instead of that RSS threshold.

Use a separate output folder for each invocation. A longer run can use
`--sizes 40 --cycles 3 --edits 200`. A separate debug-allocator binary can use
`--debug-allocator`. The sender targets 20 edits/s, but actual rates depend on
full-text encoding and pipe backpressure. Report measured rates, not the target.
Receipt latency includes client scheduling. The run is not a latency guarantee
or an exhaustive leak proof. Pair it with `python3 tests/output.py BINARY` for
paused readers, partial packets, intact large replies and bounded output failure.

The current outline comparison command is:

```sh
python3 tools/outline_bench.py before /absolute/path/to/before/dot-ls
python3 tools/outline_bench.py after zig-out/bin/dot-ls
python3 tools/summarize_outline_bench.py
```

Those fixed labels overwrite matching result files. Preserve an earlier run
before reuse. Follow [the measurement rules](../bench/README.md).

Old source-rewrite profilers were moved to `bench/history/tools/`. They are not
maintained and must not be presented as current reproducible commands.

`attributes_bench.py` also accepts `--errors N` for the broken edit (default 1).
Use a separate `--output` folder for each workload. It records diagnostic counts
and wire bytes. The summary reports broken-edit and repair medians separately.

Attribute-help comparisons accept `--hover-format markdown` or
`--hover-format plaintext` to advertise the requested hover format. Raw phases
record the returned kind and hover response bytes, so a legacy plain-text reply
cannot be mistaken for a Markdown rendering measurement.
