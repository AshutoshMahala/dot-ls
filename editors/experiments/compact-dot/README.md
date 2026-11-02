# Compact DOT grammar experiment

This is a portable editor grammar candidate. It is not the current default.
It changes no dot-ls server code and adds no server dependency.
See [the memory study](../../../bench/reports/ZED_GRAMMAR_MEMORY.md) for measurements and limits.

## Source and behavior

The DOT rules come from `rydesun/tree-sitter-dot` at
`9ab85550c896d8b294d9b9ca1e30698736f08cea`. Its MIT license is retained here.
Generated sources use Tree-sitter CLI 0.27.1 and ABI 14.

The private grammar name is `dot_ls`. This avoids replacing the `dot` grammar
used by another extension. The candidate makes two changes:

- Inline the `id` wrapper rule. Identifier, number, string and statement nodes remain.
- Scan each HTML body into one `html_internal` token. Keep the outer `<` and `>`
  as separate children of `html_string`.

The scanner balances angle brackets and handles quoted tag attributes, XML
comments and CDATA. It has no heap allocation or serialized state. An unused
error sentinel stops it from consuming unrelated DOT text during error recovery.
The scanner finds DOT boundaries. It does not validate the Graphviz HTML vocabulary.
The separate HTML grammar still provides inner tag structure, colors and matching.
The existing DOT and private HTML editor queries need no changes.

An edit inside one HTML body can scan that whole body again. The measured large
single-label cases were faster than the original grammar, but this is not a bound
on every malformed input or label layout. Upstream grammar limitations outside
these changes remain. This is an editor grammar, not a replacement for dot-parser.

## Build and check

From the project root, with a WASI SDK installed:

```sh
python3 tools/build_zed_grammar.py --clang /path/to/wasi-sdk/bin/clang --output /tmp/dot_ls.wasm
```

The generated C sources are included. Regeneration is optional:

```sh
python3 tools/build_zed_grammar.py --clang /path/to/wasi-sdk/bin/clang --output /tmp/dot_ls.wasm --regenerate /path/to/tree-sitter-0.27.1
```

Run `tree-sitter test` in this grammar directory with CLI 0.27.1.
The corpus expectations intentionally omit the inlined `id` wrappers.
For the additional checks, build a native shared library with the host compiler:

```sh
clang -O2 -dynamiclib -Ieditors/experiments/compact-dot/src editors/experiments/compact-dot/src/parser.c editors/experiments/compact-dot/src/scanner.c -o /tmp/dot_ls.dylib
TREE_SITTER_LIBRARY=/path/to/libtree-sitter.dylib python3 tools/zed_grammar_test.py /tmp/dot_ls.dylib
```

The example shared-library command is for macOS. On Linux, use `-shared -fPIC`
and the normal `.so` suffix. These native tools are for tests only.

For isolated Zed comparisons, first prepare the normal benchmark profiles using
`tools/zed_editor_bench.py prepare`. Then run:

```sh
python3 tools/zed_editor_bench.py prepare-compact /tmp/dot_ls.wasm
python3 tools/zed_editor_bench.py launch compact-full 5 study
```

Use the separate UI workflow in the memory study. The preseeded benchmark index
loads the supplied WASM. Its upstream source metadata is not a release manifest.
Do not distribute the temporary profile or its extension index to customers.

## Customer release path

The runtime output is a normal WebAssembly Tree-sitter grammar. Customers need
neither a custom Zed build, a changed allocator, profiling tools, a WASI SDK nor
machine-specific editor settings. The app copy and temporary profiles are only
measurement tools. The extension's existing server-location setup still applies.

Before making this candidate the adapter default:

1. Publish this grammar source in a maintained Git repository, or merge it into
   the extension repository and use its grammar subdirectory as the manifest path.
2. Add `[grammars.dot_ls]` to the extension manifest. Set its real repository URL
   and immutable commit revision. Set `path` if the grammar is in a subdirectory.
3. Set the DOT language configuration to `grammar = "dot_ls"`. Remove the old
   DOT grammar entry. Keep the pinned HTML grammar and the existing queries.
4. Build through Zed's normal extension builder from that source pin. Run the
   corpus and boundary tests and repeat an editor smoke test with the built output.
5. Ship the extension through the normal extension release process. Preserve the
   MIT notice. Check the release on other supported Zed platforms before claiming
   cross-platform verification.

The repository URL and commit do not exist yet for this candidate. The default
manifest therefore retains the real upstream pin. No local file URL, fabricated
revision or benchmark index has been added to the production adapter.
