# Development

This guide is for people who change dot-ls. It shows how to build it, test it,
measure it and release it.

Before you change behavior, read [Architecture](ARCHITECTURE.md) and
[Requirements](REQUIREMENTS.md). Update the documents in `docs/` in place when
behavior changes.

## Tools you need

| Task | Tools |
| --- | --- |
| Build and test the server | Zig 0.17.0, Python 3.9 or later |
| Test the Zed extension's download cache | `rustc` |
| Install the Zed extension from source | Zed, Rust installed with rustup |
| Build the release archives | Zig 0.17.0, Python, rustup with the `wasm32-wasip2` target, Git, WASI SDK `clang` |

The server build needs no network access. The parser source is in `vendor/`.
The Zed archive build needs network access: it clones the grammars and downloads
Rust crates. Users of the release archives need none of these tools.

To prepare the Zed archive build:

- Add the Rust target: `rustup target add wasm32-wasip2`.
- Get WASI SDK 34 for your system from the
  [wasi-sdk releases](https://github.com/WebAssembly/wasi-sdk/releases) and
  extract it. Its compiler is `bin/clang` inside the extracted folder.

## Project layout

| Path | Contents |
| --- | --- |
| `src/` | Server source and Zig unit tests |
| `tests/` | Protocol tests, written in Python with no extra packages |
| `editors/zed/` | Zed extension. Only files that the extension needs. |
| `editors/experiments/` | Editor grammar experiments. The extension does not use them. |
| `examples/` | Small DOT files for manual tests |
| `tools/` | Development commands. See [tools/README.md](../tools/README.md). |
| `vendor/` | Pinned copy of dot-parser, with its licenses and hash manifest |
| `docs/` | The six current documents |
| `bench/` | Benchmark reports, raw results and retired tools |
| `.github/workflows/` | GitHub Actions workflows |

[Architecture](ARCHITECTURE.md#folder-and-file-layout) explains the `src/` layout.

## Build and run

```sh
zig build -Doptimize=safe
zig-out/bin/dot-ls --version
zig-out/bin/dot-ls lsp
```

The last command runs the language server on standard input and output. Press
`ctrl-c` to stop it. Usually the editor starts it for you. `dot-ls`,
`dot-ls --stdio` and `dot-ls lsp` do the same thing. The build also installs
`zig-out/bin/dotls`, an old name for the same program.

A source build reports version `0.0.1-dev`. Release builds pass the real version.

The default build uses the page allocator, packed small allocations for the HTML
cache, and buffered JSON storage. These build options exist for experiments:

- `-Dallocator=page|smp|debug`
- `-Djson-storage=buffer|arena|inplace`

They are not editor settings. Do not change a default without comparing memory
and speed before and after.

## Run the checks

Run these from the project root. GitHub Actions runs the same checks (see
[Continuous integration](#continuous-integration)).

```sh
python3 tools/check_layout.py
python3 tools/check_vendor.py
zig build test
zig build test -Doptimize=safe
zig build test-parser -Doptimize=safe
zig build -Doptimize=safe
for suite in lsp protocol validation completion attributes references html code_actions outline output templates; do
  python3 "tests/$suite.py" zig-out/bin/dot-ls
done
```

| Check | What it covers |
| --- | --- |
| `check_layout.py` | Document links, the `docs/` file list, tool syntax and source import rules |
| `check_vendor.py` | The vendored parser matches its pinned upstream bytes |
| `zig build test` | Server unit tests. The test root is `src/tests.zig`. |
| `zig build test-parser` | The vendored parser's own tests |
| `tests/*.py` | Protocol tests against a built server. Each takes the server path. |

Choose extra checks that fit your change:

- **Code that calls dot-parser** (mostly `src/analysis/`): run
  `python3 tools/check_vendor.py` and `zig build test-parser -Doptimize=safe`.
- **Ownership, indexes or cancellation:** add tests for cancellation, failure and
  old document versions.
- **How incoming messages are stored** (`src/protocol/json_message.zig`): also
  build with `-Djson-storage=inplace` and `-Djson-storage=arena`, each with
  `-Dallocator=debug`, in separate `--prefix` folders. Run the protocol tests on
  each. Then rebuild the normal server before you measure speed.
- **Protocol code** (`src/protocol/`): compare exact replies with an older server:
  `python3 tests/protocol.py zig-out/bin/dot-ls --compare /absolute/path/to/old/dot-ls`.
- **Long-running load:** `python3 tools/stress.py zig-out/bin/dot-ls --output bench/results/stress-local`
  runs a macOS stress test with large files, edits, cancellation and shutdown.
  The [tools guide](../tools/README.md) has the details.

Do not add tests that only repeat an implementation detail.

To test with the Neovim client:

```sh
DOTLS_BIN="$PWD/zig-out/bin/dot-ls" nvim --headless -u NONE -i NONE -l tests/neovim.lua
```

Test Zed grammar features, such as colors, pairing and folding, in Zed. The
protocol tests do not cover them. The [Zed guide](../editors/zed/README.md#work-on-the-extension)
shows how to test the extension. If you add an error to an example file to test
it, remove the error afterwards.

## Continuous integration

The repository is `github.com/AshutoshMahala/dot-ls`. It has two GitHub Actions
workflows in `.github/workflows/`.

**CI** (`ci.yml`) runs on every push to `main`, on every pull request, and when
you start it by hand from the Actions page. On Ubuntu 24.04 (x86-64) and macOS 15
(ARM64) it runs all of the checks in [Run the checks](#run-the-checks). It also
runs the Zed extension's download cache tests, with the `rustc` of the runner.

**Package** (`package.yml`) runs on every push to `main`, on every tag that
starts with `v`, and when you start it by hand from the Actions page. It has
three jobs:

1. **Build archives** builds all release archives on Ubuntu with
   `tools/package_release.py`. It then checks them with `tools/check_release.py`.
   It uploads them as the workflow artifact `dot-ls-VERSION`.
2. **Run tests** runs on four machines: Linux x86-64, Linux ARM64, macOS ARM64
   and macOS x86-64. Each machine extracts its own archive into a clean folder
   and runs all protocol tests against it.
3. **Create draft release** runs only for a version tag, and only when both
   other jobs pass. It creates a draft GitHub release with all archives and
   `SHA256SUMS`.

GitHub shows full job logs only to signed-in users. The workflows run each test
command through `tools/ci_report.py`. When a command fails, its last 40 output
lines appear as an annotation on the run page, which anyone can read.

The Package workflow pins its tools: Zig 0.17.0, Rust 1.99.1 and WASI SDK 34.
It checks the WASI SDK download against a fixed SHA-256 value. Rust and the WASI
SDK are set only in the `env` block at the top of `package.yml`. The Zig version
is in these places. Change all of them together:

- `ZIG_VERSION` in `package.yml`
- `version` of the `setup-zig` step in `ci.yml`
- `minimum_zig_version` in `build.zig.zon`
- The version check and the `zig` value of `RELEASE.json` in `tools/package_release.py`

## Make a release

The Zed extension downloads the server from the GitHub release whose tag is
`v` plus the extension version. The tag, the archives and all version numbers
must agree.

1. Set the new version in all of these places:
   - `VERSION`
   - `.version` in `build.zig.zon`
   - `version` in `editors/zed/Cargo.toml`
   - `version` in `editors/zed/extension.toml`
   - The `VERSION` constant, and the file names in the tests, in
     `editors/zed/src/resolver.rs`
   - The default `-dev` version in `build.zig`, for example `0.0.2-dev`

   Then update the lock file:

   ```sh
   cargo update --workspace --manifest-path editors/zed/Cargo.toml
   ```

   This command finds the places that still have the old version:

   ```sh
   grep -rn '0\.0\.1' VERSION build.zig build.zig.zon editors/zed/Cargo.toml editors/zed/Cargo.lock editors/zed/extension.toml editors/zed/src README.md editors/zed/README.md docs/DEVELOPMENT.md
   ```

   `tools/package_release.py` stops with an error if `VERSION`, `build.zig.zon`,
   `Cargo.toml`, `extension.toml` and `resolver.rs` do not agree.
2. Update the version examples in `README.md` and `editors/zed/README.md`.
3. Run [the checks](#run-the-checks). Commit and push to `main`.
4. Wait until **CI** and **Package** pass on `main`.
5. Create and push the tag:

   ```sh
   git tag "v$(cat VERSION)"
   git push origin "v$(cat VERSION)"
   ```

   The **Package** workflow stops if the tag does not match `VERSION`.
6. When the workflow finishes, open the repository's Releases page. Review the
   draft release and its six files. Then publish it.

The Zed extension can download the server only after you publish the release.
A draft release is not visible to the extension.

The macOS programs have an ad-hoc signature only. They are not signed with an
Apple Developer ID and are not notarized.

## Build release archives locally

You can build the same archives on your own machine. The output goes to
`dist/`, which Git ignores.

```sh
python3 tools/package_release.py --output dist/0.0.1
python3 tools/package_release.py --output dist/0.0.1 --zed-only --wasi-clang /path/to/wasi-sdk/bin/clang
python3 tools/check_release.py dist/0.0.1 --runtime --output dist/0.0.1-checks.json
```

To keep a check result as evidence, write it into a new folder in
`bench/results/` instead.

The first command builds the four server archives. The second command builds
the Zed extension archive and updates `SHA256SUMS`. Use `--zed` instead of
`--zed-only` to build all five archives in one run.

Options:

- `--targets` builds only some systems, for example `--targets aarch64-macos`.
- `--cache-dir PATH` uses an existing Zig cache.
- `--grammar-cache PATH` sets where the Zed grammar sources are cloned. The
  default is `editors/zed/grammars/`, which Git ignores. The tool uses the exact
  committed grammar files at the pinned revisions, not local edits.

The server archives are built with `-Dversion=VERSION`, `-Doptimize=safe`,
`-Dstrip=true` and `-Dcpu=baseline`, in a temporary install folder. They never
replace `zig-out/bin/dot-ls`. macOS builds target macOS 15.0 and later. Linux
builds are static.

Each server archive contains `dot-ls`, both project licenses, the parser and Zig
licenses, `THIRD-PARTY-NOTICES.txt`, `RELEASE.json` and `README.txt`. The Zed
archive contains the compiled extension, the compiled DOT and HTML grammars, the
query files, `DEPENDENCIES.json` and all dependency licenses. It contains no
Rust source. Archive entries have fixed timestamps and owners.

`check_release.py` checks the checksums, archive paths, file types, CPU types
and library links of every archive. With `--runtime`, it also extracts the
archive for the current machine into a clean folder. Then it runs all protocol
tests with a minimal `PATH`. It runs only the archive that matches the current
machine.

## Measure

Use the [benchmark guide](../bench/README.md) and the
[performance baseline](PERFORMANCE.md).

Some benchmarks, such as `tools/references_bench.py`, read the large example
files `examples/editor-5mb.dot`, `editor-20mb.dot`, `editor-40mb.dot` and
`editor-100mb.dot`. They are also useful for manual tests in an editor. They are
not in Git. Create them with:

```sh
python3 tools/make_large_examples.py
```

The tool writes the same bytes as the files used for earlier results. It checks
each file's SHA-256 value. Use `--sizes 5 20` to create only some files.

Rules for measurements:

- Start at 5 MB. Go to 20 MB and 40 MB only if the smaller file stays responsive.
- Measure server memory and editor memory separately.
- Do not run builds, tests or editor work while you measure.
- Record the server hash, build options, file hashes, machine and raw results.
- Tools write into `bench/results/`. Save an earlier result before you run a
  tool that writes to the same folder.
- A summary must point to its raw data. Do not present one old run as a
  performance promise.

The profilers in `bench/history/tools/` were written for older source code. Do
not use them on the current source. A new profiler must use a clear interface,
or must be checked against the current source first.

## Update the parser

`vendor/dot-parser/` is an exact copy of dot-parser at the commit named in
[vendor/README.md](../vendor/README.md). It has no local changes. When you
update it:

1. Replace the files with the new upstream commit.
2. Update `vendor/upstream.json` and `vendor/README.md`.
3. Update the parser version that `--version` prints, in `src/protocol/lsp.zig`,
   and the comment in `build.zig.zon`.
4. Run `python3 tools/check_vendor.py`.
5. Run all [checks](#run-the-checks).

Do not edit the parser in place. A fresh build must work from this project alone.

## Change the Zed extension

The extension has its own Rust build. `extension.toml` pins the DOT and HTML
grammars. `editors/experiments/compact-dot/` is a grammar experiment. The
extension and the release archives do not use it. Keep it, and any other file
that the extension does not need, out of `editors/zed/`. A published Zed
extension must contain only what it needs.

See [Work on the extension](../editors/zed/README.md#work-on-the-extension).

## What goes into Git

Git keeps source, tests, documents, small examples, benchmark records and the
pinned parser. `.gitignore` leaves out files that tools can create again:

| Ignored path | What it is | How to create it |
| --- | --- | --- |
| `.zig-cache/`, `zig-out/` | Zig build output | `zig build` |
| `dist/` | Release archives | `tools/package_release.py`, or the Package workflow |
| `examples/editor-*mb.dot` | Large benchmark files (165 MB) | `tools/make_large_examples.py` |
| `editors/zed/target/`, `extension.wasm`, `grammars/` | Zed extension build output | Zed dev install. `tools/package_release.py` also clones into `grammars/` by default. |
| `editors/zed/.cargo/config.toml` | Settings for one machine | Not needed |
| `temp/` | Your scratch files | Not needed |
| `.zed/`, `.vscode/`, `.idea/` | Your own editor settings for this repository | Not needed |
| `__pycache__/`, `.DS_Store`, `nvim.log` | Caches, system files and logs | Not needed |

Rules:

- Put scratch files in `temp/` at the project root.
- Put editor support in `editors/<editor>/`, for example `editors/zed/`. That
  folder's guide documents the editor settings. Do not commit editor settings
  folders such as `.zed/` or `.vscode/`.
- Put measurements in `bench/results/` and reports in `bench/reports/`. Never
  put them in `docs/`.
- Put development commands in `tools/` and list them in its README.
- Keep machine paths, logs and caches out of Git.
- Do not delete the large example files or the Zed build output while an editor
  uses them. You can delete `.zig-cache/` and `__pycache__/` when no build runs.
- Do not add a library, worker or framework only to tidy folders.
- Commit with your own Git identity. Do not add AI authors or co-author lines.
