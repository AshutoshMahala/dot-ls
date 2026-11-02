# dot-ls

dot-ls is a language server for [Graphviz DOT](https://graphviz.org/doc/info/lang.html)
files (`.dot`, `.gv`). It checks your graph while you type and helps you edit it.
It is a small native program. It does not need Graphviz.

What you get in the editor:

- **Errors and warnings** with a short fix hint, for DOT syntax and HTML-like labels.
- **Quick fixes** for many syntax errors, such as "Insert closing ']'".
- **Hover help** for attribute names such as `shape`, `rankdir` and `arrowhead`.
- **Completion** of keywords and attribute names.
- **Find references** for a node.
- **Outline** of graphs, subgraphs, clusters and nodes.

See [Features](docs/FEATURES.md) for examples and limits.

## Status

dot-ls is early software (version 0.0.1).

- **Editor:** [Zed](https://zed.dev) is the only supported editor.
  The Zed extension is not in Zed's extension gallery yet.
- **Systems:** macOS 15 or later and Linux, each on ARM64 or x86-64.
  Windows is not supported.
- **Not available yet:** rename, formatting, graph preview and attribute value
  completion.

## Use dot-ls in Zed

Follow [the Zed guide](editors/zed/README.md). In short:

1. Get the `dot-ls` server (next section).
2. Install Rust with [rustup](https://rustup.rs). Zed needs it to build the extension.
3. Clone this repository.
4. In Zed, run **zed: install dev extension** and select the `editors/zed` folder.
5. Tell Zed where `dot-ls` is, in your Zed settings.
6. Open a `.dot` file. The language selector in the status bar shows **DOT (dot-ls)**.

## Get the server

### Download a prebuilt server

Each [GitHub release](https://github.com/AshutoshMahala/dot-ls/releases) has one
archive per system. Pick the archive for your machine:

| System | Archive |
| --- | --- |
| macOS, Apple silicon | `dot-ls-VERSION-aarch64-macos.tar.gz` |
| macOS, Intel | `dot-ls-VERSION-x86_64-macos.tar.gz` |
| Linux, ARM64 | `dot-ls-VERSION-aarch64-linux-musl.tar.gz` |
| Linux, x86-64 | `dot-ls-VERSION-x86_64-linux-musl.tar.gz` |

A release also has `SHA256SUMS`, the checksums of the archives, and
`dot-ls-zed-VERSION.tar.gz`. You do not need the Zed archive. It is for testing
the packaged extension. Install the extension from source, as shown below.

If the releases page is empty, use a build from GitHub Actions. Open the
[Package workflow](https://github.com/AshutoshMahala/dot-ls/actions/workflows/package.yml),
select the latest successful run on `main`, and download the `dot-ls-VERSION`
artifact. You must be signed in to GitHub to download an artifact. The artifact
is a zip file that holds all archives and `SHA256SUMS`. Unzip it first.

Put your archive and `SHA256SUMS` in one folder. Open a terminal in that folder.
Check the download, then extract the program. This example uses Apple silicon
and version 0.0.1:

```sh
shasum -a 256 -c --ignore-missing SHA256SUMS
mkdir -p ~/.local/bin
tar -xzf dot-ls-0.0.1-aarch64-macos.tar.gz -C ~/.local/bin dot-ls
~/.local/bin/dot-ls --version
```

On Linux, use `sha256sum -c --ignore-missing SHA256SUMS` for the first command.
The last command prints the version, for example
`dot-ls 0.0.1; dot-parser 0.5.0 (01b0a8e)`.

The archive also contains the licenses and third-party notices. Keep them if you
share the program.

The macOS programs are not notarized by Apple. If macOS blocks `dot-ls`, remove
the download flag:

```sh
xattr -d com.apple.quarantine ~/.local/bin/dot-ls
```

### Build from source

You need [Zig 0.17.0](https://ziglang.org/download/). The build needs no network
access. All dependencies are in this repository.

```sh
git clone https://github.com/AshutoshMahala/dot-ls.git
cd dot-ls
zig build -Doptimize=safe
zig-out/bin/dot-ls --version
```

The program is `zig-out/bin/dot-ls`. A source build reports version `0.0.1-dev`.

## Run the server

An editor starts dot-ls for you. You only need these commands to configure an
editor or to check the program.

| Command | What it does |
| --- | --- |
| `dot-ls lsp` | Runs the language server on standard input and output. |
| `dot-ls` or `dot-ls --stdio` | Same as `dot-ls lsp`. |
| `dot-ls --version` | Prints the server and parser versions. |
| `dot-ls --help` | Prints a short usage message. |

dot-ls does not open a network port. It reads only the files that the editor
sends to it.

A source build also installs `zig-out/bin/dotls`. This is an old name for the
same program. Release archives contain only `dot-ls`.

## Documentation

| I want to... | Read |
| --- | --- |
| Install and configure the Zed extension | [Zed guide](editors/zed/README.md) |
| Learn what each feature does, with examples | [Features](docs/FEATURES.md) |
| Build, test or release dot-ls | [Development](docs/DEVELOPMENT.md) |
| Understand the design before I change code | [Architecture](docs/ARCHITECTURE.md) |
| See what is done and what is missing | [Requirements](docs/REQUIREMENTS.md) |
| See speed and memory measurements | [Performance](docs/PERFORMANCE.md) |

The [documentation index](docs/README.md) lists all documents.

## License

dot-ls is available under the MIT license or the Apache License 2.0, at your
choice. See [LICENSE-MIT](LICENSE-MIT) and [LICENSE-APACHE](LICENSE-APACHE).
Bundled dependencies keep their own licenses.
