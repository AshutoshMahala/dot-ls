# dot-ls for Zed

This Zed extension adds the language **DOT (dot-ls)** for `.dot`, `.gv` and `.DOT`
files. It gives you:

- Syntax colors, bracket and quote pairing, indentation and folding. These come
  from the extension's grammar and work without the server.
- Errors, quick fixes, hover help, completion, references and the outline. These
  come from the `dot-ls` server, which the extension starts for you.

In Zed's Extensions page, the extension is named **Graphviz DOT (dot-ls)**. The
extension ID and the language server ID are both `dotls`.

## Before you start

- The extension is not in Zed's extension gallery yet. You install it from this
  repository as a dev extension.
- You need Rust, installed with [rustup](https://rustup.rs). Zed uses Rust to
  build the extension. Zed adds the `wasm32-wasip2` target itself.
- You need the `dot-ls` server for your system. See
  [Get the server](../../README.md#get-the-server).
- dot-ls runs on macOS 15 or later and Linux, on ARM64 or x86-64. Windows is not
  supported.

In Zed, run commands from the command palette: press `cmd-shift-p` on macOS or
`ctrl-shift-p` on Linux, then type the command name.

## Install

1. Clone the repository:

   ```sh
   git clone https://github.com/AshutoshMahala/dot-ls.git
   ```

2. In Zed, run **zed: install dev extension**. Select the `editors/zed` folder in
   the clone. Zed builds the extension. The first build can take a few minutes.

3. Tell the extension where the server is. Open your Zed settings file,
   `~/.config/zed/settings.json`, and add the `lsp` entry. If the file already
   has settings, put the `lsp` key inside its outer `{ }`. Use the full path to
   your `dot-ls` program:

   ```json
   {
     "lsp": {
       "dotls": {
         "binary": {
           "path": "/Users/you/.local/bin/dot-ls"
         }
       }
     }
   }
   ```

   If `dot-ls` is on your `PATH`, you can skip this step.

4. Check that it works. Create a file named `check.dot` with this text:

   ```dot
   digraph {
       start [shape=box];
       start -> finish;
       broken [color=red
   }
   ```

   Open it in Zed. You should see:

   - **DOT (dot-ls)** in the language selector in the status bar.
   - An error on the last `}`: "Missing closing ']' before '}'."
   - Help for `shape` when you hover over it.
   - The fix **Insert closing ']'** when you put the cursor on the error and run
     **editor: toggle code actions**. Apply it, and the error goes away.

## How the extension finds the server

The extension uses the first match in this list:

1. The path in `lsp.dotls.binary.path`.
2. A program named `dot-ls` on the `PATH` that Zed uses for the project. Then the
   old name `dotls`.
3. A server that the extension downloads from the GitHub release `v0.0.1`.

The download (item 3) works only after the release `v0.0.1` is published on
GitHub with its archives. The extension asks for that exact version, not the
newest release. It saves the server in Zed's extension data folder:

- macOS: `~/Library/Application Support/Zed/extensions/work/dotls/`
- Linux: `~/.local/share/zed/extensions/work/dotls/`

Later starts use the saved server and need no network. This download path has
not been tested with a real published release yet.

The extension never uses a server from your project folder, such as `zig-out/`,
unless you set its path.

## Settings

All settings are optional.

```json
{
  "lsp": {
    "dotls": {
      "binary": {
        "path": "/Users/you/.local/bin/dot-ls",
        "arguments": ["lsp"],
        "env": { "EXAMPLE": "value" }
      }
    }
  },
  "languages": {
    "DOT (dot-ls)": {
      "language_servers": ["dotls"],
      "document_symbols": "on"
    }
  },
  "file_types": {
    "DOT (dot-ls)": ["**/*.dot", "**/*.gv"]
  }
}
```

| Setting | Use |
| --- | --- |
| `lsp.dotls.binary.path` | Full path to the `dot-ls` program. |
| `lsp.dotls.binary.arguments` | Program arguments. The default is `["lsp"]`. |
| `lsp.dotls.binary.env` | Extra environment variables for the server. |
| `languages."DOT (dot-ls)".document_symbols` | Set to `"on"` so the outline uses dot-ls. |
| `file_types."DOT (dot-ls)"` | Use this when another extension opens your `.dot` files. |

You can put these settings in `~/.config/zed/settings.json` for all projects, or
in `.zed/settings.json` inside one project.

## Use the features

| Task | What to do in Zed |
| --- | --- |
| See errors | Errors show as you type. Run **diagnostics: deploy** to list them all. |
| Fix an error | Put the cursor on the error. Run **editor: toggle code actions**. |
| Read attribute help | Hover over an attribute name, or run **editor: hover**. |
| Complete a name | Type, or run **editor: show completions**. |
| Find all uses of a node | Put the cursor on the node name. Run **editor: find all references**. |
| See the graph outline | Run **outline: toggle**, or open the Outline Panel. |

[Features](../../docs/FEATURES.md) explains each feature, with examples and limits.
The [examples folder](../../examples/) has small files to try each feature.

## Troubleshooting

**"Cannot install dot-ls: ..."**
The extension did not find a server on your `PATH` or in your settings. Then it
could not use a downloaded server. Read the rest of the message:

- If it names a release, an asset or a network problem, the download failed.
  This is normal until release `v0.0.1` is published. Set
  `lsp.dotls.binary.path`, or put `dot-ls` on your `PATH`.
- If it says "Invalid dot-ls binary" or "Cannot read dot-ls", the saved server
  is damaged or is for another system. Quit Zed. Delete the `dot-ls-*` folder in
  Zed's extension data folder (listed above). Start Zed again.

**"The configured dot-ls binary path is empty."**
Remove the empty `path` value, or set it to the full path of `dot-ls`.

**The file opens with a different language, or shows no errors.**
Click the language selector in the status bar and choose **DOT (dot-ls)**. To make
this permanent, add the `file_types` setting shown above. Another Graphviz
extension can claim the same file names.

**The outline is empty.**
Set `document_symbols` to `"on"` for **DOT (dot-ls)**, as shown above.

**Attribute names do not appear after `[`.**
This is a known bug. Zed adds `]` when you type `[`, and dot-ls returns no
attribute names when the cursor is directly before `]`. Type a space, press the
left arrow key once, then type the name. See [Features](../../docs/FEATURES.md#completion).

**Other problems.**
Run **debug: open language server logs** and select `dotls` to read the server
messages. After you change or replace the server, run
**editor: restart language server**.

## Work on the extension

This section is for people who change the extension.

The extension source is in this folder:

| Path | Contents |
| --- | --- |
| `extension.toml` | Extension manifest and pinned grammar revisions |
| `Cargo.toml`, `Cargo.lock` | Rust crate and pinned `zed_extension_api` version |
| `src/lib.rs` | Finds or downloads the server and starts it |
| `src/resolver.rs` | Download cache for the server; has its own tests |
| `languages/dot/` | DOT colors, brackets, indentation and HTML injection queries |
| `languages/dot-html/` | Queries for HTML-like label content |

Keep only the files that the extension needs in this folder. Zed's rules require
this for a published extension. The grammar experiment is in
[editors/experiments/compact-dot](../experiments/compact-dot/README.md) for this
reason. The extension does not use it.

To test a change:

1. Build the server: `zig build -Doptimize=safe`.
2. Set `lsp.dotls.binary.path` to the full path of `zig-out/bin/dot-ls`.
3. Install this folder as a dev extension, as in [Install](#install).
4. Open `examples/message-templates.dot`. Check hover help on `shape` and the
   quick fix for the missing `]`.

After a server change, run **editor: restart language server**. After a change
to the extension code or queries, install the dev extension again.

Run the download cache tests without Zed. Run these commands from the project
root:

```sh
rustc --edition 2021 --test editors/zed/src/resolver.rs -o /tmp/dot-ls-resolver-tests
/tmp/dot-ls-resolver-tests
```

Test grammar features, such as colors, pairing and folding, in Zed itself. The
server tests do not cover them.

### Test the packaged extension

The release process builds a prebuilt extension archive, `dot-ls-zed-VERSION.tar.gz`.
It contains the compiled extension, the compiled grammars and their licenses. It
contains no Rust source. Loading it needs no Rust. You can load it into a new,
separate Zed profile, so your normal Zed setup does not change.

Get the archives from the Package workflow (see
[Get the server](../../README.md#get-the-server)), or build them as described in
[Development](../../docs/DEVELOPMENT.md#build-release-archives-locally). Then run
this from the project root. Use the server archive for your machine, and a
profile path that does not exist yet:

```sh
python3 tools/install_zed_local.py \
  --extension dist/0.0.1/dot-ls-zed-0.0.1.tar.gz \
  --server dist/0.0.1/dot-ls-0.0.1-aarch64-macos.tar.gz \
  --profile /tmp/dot-ls-zed-local
```

The tool puts the extension and the server into the new profile. It also creates
a sample project. It sets no server path, so the extension must find the server
in its own data folder.

On macOS, start Zed with that profile:

```sh
/usr/bin/env ZED_STATELESS=1 /Applications/Zed.app/Contents/MacOS/zed \
  --user-data-dir /tmp/dot-ls-zed-local /tmp/dot-ls-zed-local/sample
```

`ZED_STATELESS=1` stops Zed from sending the request to a Zed window that is
already open. This launch command has been tested only on macOS. In the new window, open `sample.dot` and do the checks from step 4
of [Install](#install). Then undo the fix.

### Publish to the Zed gallery

This has not been done yet. Zed lists an extension after a pull request to the
[zed-industries/extensions](https://github.com/zed-industries/extensions)
repository is merged. Zed then builds the extension from source, from the
`editors/zed` folder of this repository.

Before you open the pull request:

1. Make this repository public on GitHub.
2. Publish the GitHub release that matches the extension version. See
   [Make a release](../../docs/DEVELOPMENT.md#make-a-release).
3. Install the extension as a dev extension from the exact commit that you will
   submit. Do the checks in step 4 of [Install](#install).

In the pull request:

1. Add this repository as a Git submodule at `extensions/dotls`. Use the HTTPS
   URL. The submodule commit must be on a branch.
2. Add an entry to `extensions.toml` with `submodule`, `version` and
   `path = "editors/zed"`. The version must match `extension.toml`.
3. Run `pnpm sort-extensions`.

Zed checks that the extension folder has an accepted license. `LICENSE-MIT` and
`LICENSE-APACHE` are in this folder for that reason. A license only at the
repository root does not count.

An extension named **Graphviz** (ID `graphviz`) already supports DOT in Zed. It
uses the same DOT grammar and a different server, dot-language-server. Zed asks
new extensions to add functionality that the registry does not have yet. In the
pull request, explain what dot-ls adds.

Zed's [publishing guide](https://zed.dev/docs/extensions/publishing/publishing-guide)
and [prerequisites](https://zed.dev/docs/extensions/publishing/prerequisites)
have the full rules.

How people find the extension: Zed's extension search matches the extension name
and ID. It does not search the description, and Zed has no tags. The name
**Graphviz DOT (dot-ls)** lets searches for "graphviz", "dot" and "dot-ls" find
it. Zed sorts search results by download count. Zed also lists the extension
under the Languages, Grammars and Language Servers categories, because it
provides all three.
