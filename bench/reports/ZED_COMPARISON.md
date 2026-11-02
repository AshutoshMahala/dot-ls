> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

# Zed comparison: dotls and dot-language-server

Measured on 2026-10-14, native arm64 macOS. MB and GB are decimal units.

For the newer server-only comparison with current dot-ls features, plain and
HTML-heavy inputs, startup measurements and error-count sweeps, see
[the controlled server comparison](SERVER_COMPARISON.md).


## Installed software and selected server

- Running Zed: 1.23.3 (confirmed in its startup log).
- Graphviz marketplace extension: 0.2.1.
- npm `dot-language-server`: 3.2.1, installed globally with lifecycle scripts disabled.
- Its `dot-language-support` dependency: 4.4.2; Node: 26.11.1.
- dotls: current ReleaseSafe build with page allocation, buffered JSON,
  block scanning, metering and cancellation. This is the normal build, not the
  optional in-place JSON experiment.

The extension is [Graphviz](https://zed.dev/extensions/graphviz). Its
[adapter](https://github.com/gabeins/zed-graphviz/blob/main/src/dot.rs) requires
`dot-language-server` on PATH and launches it with `--stdio`. It does not install
that npm package automatically.

After testing, `.zed/settings.json` selects **dotls only** for DOT. Measurement
relay overrides were removed. Graphviz remains installed, including its syntax
highlighting grammar. To switch the project to the other server, replace
`"dotls"` with `"dot-language-server"` in `languages.DOT.language_servers`.
Select one server at a time. Zed normally reacts to the setting change; use
`editor: restart language server` if needed. No global Zed settings were changed.

## In-editor diagnostics

These are actual notifications from Zed, relayed to the chosen server. Each
size used a fresh server process. Both runs used the same examples in the same
Zed session, with Graphviz installed and syntax highlighting present. The 100 MB
file was closed before installing/testing Graphviz. We tested 5 MB first and
proceeded to 20 MB after navigation and editing remained responsive.

| File | Server | Open → first diagnostics | Insert `@` near EOF → error | Undo → clear error |
| --- | --- | ---: | ---: | ---: |
| ~5 MB | dotls | 22.34 ms | 27.13 ms | 26.80 ms |
| ~5 MB | dot-language-server | 865.31 ms | 596.75 ms | 650.52 ms |
| 20 MB | dotls | 86.64 ms | 91.58 ms | 82.88 ms |
| 20 MB | dot-language-server | 3,021.75 ms | 1,617.92 ms | 1,676.75 ms |

Each cell is one observation, not a median or tail-latency estimate. This is a
manual editor comparison, not a repeated statistical benchmark. Node/JIT warmup
and garbage collection affect these results. The ~5 MB file on disk was already
4,999,953 bytes at comparison time; the 20 MB file was 20,000,000 bytes. Small
buffer indentation changes from Zed add a few bytes to some edited notifications.

The reported clock starts immediately before the relay forwards a full LSP
notification and ends when it receives the corresponding diagnostics. It does
not include the earlier keystroke, Zed debounce/serialization, relay input JSON
decoding, or the final UI paint. It is diagnostic turnaround, not a measured
key-to-screen latency. RSS polling and relay work add some measurement overhead.

The single-character error/repair phases were spaced apart until the prior
result arrived. dot-language-server does not include a version in its diagnostic
notification, so that spacing is important. An earlier multiline paste generated
multiple changes; its diagnostic times were excluded from the latency table.
A dotls close notification clears diagnostics too; that clear is also excluded.

Navigation and edit commands continued to work with both servers. The Graphviz
server had a noticeable wait before diagnostics caught up, especially at 20 MB.
We did not measure frame latency or claim exact human typing latency. We did
not advance Graphviz to 40 MB or 100 MB. The last test edit was undone.

## Server memory

Two methods were used. The editor relay samples the **server process only** at
approximately 20 ms plus `ps` overhead. It excludes the editor and Python relay.
It can miss brief allocation overlaps, especially in dotls.

| File | dotls sampled peak in Zed | dot-language-server sampled peak in Zed |
| --- | ---: | ---: |
| ~5 MB | 8.91 MB | 1.33 GB |
| 20 MB | 41.44 MB | 2.56 GB |

The 5 MB Graphviz live peak includes the exploratory multiline paste as well
as the selected single-character edits. The separate check below uses the same
three-step sequence for both servers.

Do not interpret those dotls sampled values as actual high-water memory. We also
ran a separate stdio client with macOS `/usr/bin/time -l` to capture brief peaks.
Each case used a fresh process, opened the same file, inserted an error near EOF,
repaired it, and shut down. This second check was **outside Zed** and did not
include its extra LSP requests or the measurement relay.

| File | dotls actual peak RSS, separate check | dot-language-server actual peak RSS, separate check |
| --- | ---: | ---: |
| ~5 MB | 17.68 MB | 1.22 GB |
| 20 MB | 63.57 MB | 3.20 GB |

The difference between Graphviz's live and separate peaks shows why one RSS
sample is not enough. Garbage collection, request sequence, and retained ASTs
change its peak. Neither table measures total editor-plus-server memory.

## Scope of the comparison

This dotls checkpoint performs count-only syntax diagnostics and retains no AST.
dot-language-server advertises completion, hover, references, definition and
declaration, selection ranges, rename, code actions, colors, folding, and document
symbols. Its installed implementation rebuilds an AST and validates on document
content changes. We did not disable those features or claim equal feature scope.
The extra capabilities were identified from initialization and source, not all
functionally tested in this session.

On these fixtures, dotls catches up substantially faster and uses much less
server memory. This does not establish the same ratio for other documents or
richer operations. A server-only comparison can explain diagnostic turnaround;
smooth editor typing alone cannot show whether analysis has caught up.

## Records and reproduction

`zed-comparison/summary.json` selects the in-editor latency observations.
`zed-comparison/environment.json` records versions and final project selection.
`zed-comparison/high-water-memory.json` records exact peaks and macOS time output.
The directory also contains per-process relay traces and empty server stderr
files. Timing traces store metadata only, not full document contents.

For another live comparison, set a server's `lsp.<id>.binary.path` to
`/usr/bin/python3` and arguments to the absolute path of
`tools/lsp_compare_proxy.py`, a label, the real server path, and its arguments.
Use `lsp` for dotls and `--stdio` for dot-language-server. Keep exactly one
outstanding edit per measured diagnostic. Remove relay overrides when finished.

Run the separate memory check from the project root:

```sh
python3 tools/compare_server_memory.py
```

This helper uses the installed macOS/Homebrew server location. Adjust it for
another machine. It tests 5 MB and then 20 MB; do not use it to bypass the manual
responsiveness check for a new server/build. No production server code changed
as part of this comparison.
