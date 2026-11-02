# Features

This document describes what dot-ls does today. Each section tells you what the
feature does, how to try it, and its limits. The example files are in
[examples/](../examples/).

| Feature | LSP method | In Zed |
| --- | --- | --- |
| [Errors and warnings](#errors-and-warnings) | `textDocument/publishDiagnostics` | Shown as you type |
| [HTML-like label checks](#html-like-labels) | `textDocument/publishDiagnostics` | Shown shortly after the DOT errors |
| [Quick fixes](#quick-fixes) | `textDocument/codeAction` | **editor: toggle code actions** |
| [Hover help](#hover-help) | `textDocument/hover` | Hover, or **editor: hover** |
| [Completion](#completion) | `textDocument/completion` | Type, or **editor: show completions** |
| [Find references](#find-references) | `textDocument/references` | **editor: find all references** |
| [Outline](#outline) | `textDocument/documentSymbol` | **outline: toggle** or the Outline Panel |

The Zed extension adds [editor features](#zed-editor-features) that do not use
the server. Some features are [not supported yet](#not-supported-yet).

## How dot-ls works with your files

- dot-ls knows only the files that are open in the editor. It does not read
  files from disk and does not search the whole project.
- The editor sends the full text of a file after each change. dot-ls checks the
  whole file again each time.
- It supports up to 128 open files at the same time.
- It supports UTF-8, UTF-16 and UTF-32 positions. The editor chooses one when
  it starts the server.
- It does not open a network port. It talks to the editor only on standard input
  and output.

## Errors and warnings

dot-ls checks the file while you type and reports:

- **Syntax errors**, such as a missing `]` or `}`, or unexpected text.
- **Wrong edge operators.** A `digraph` uses `->`. A `graph` uses `--`.
- **Characters that DOT does not allow**, such as `@` or a zero byte outside a
  quoted string.
- **An attribute set twice in one statement.** This is a warning, not an error.
  DOT allows it, and the later value wins.

dot-ls calls each error, warning or notice a *finding*. The editor shows each
finding as a message with two lines. The first line says what is wrong. The second line
says how to fix it. For example, this file:

```dot
graph G {
    a -> b;
    c [color=red, color=blue];
}
```

gives one error and one warning:

```text
Edge operator '->' does not match this graph.
Use '--' here, or change the graph declaration.

This attribute is set more than once in this statement.
The later value overrides the earlier value. Check whether this is intentional.
```

Each finding also has a code, such as `E.Syntax.Grammar.003`. When the parser
knows a related place in the file, the finding points to it too. Messages are
plain text. The editor chooses colors and icons.

Limits:

- dot-ls reports at most 1,000 findings for a file. After that, a notice says
  that the list is incomplete.
- dot-ls stops checking at a nesting depth of 256. A notice says that more
  errors can remain.
- The repeated-attribute check covers up to 256 different attribute names in one
  statement. It skips very long names. When it skips something, a notice says
  that the check is incomplete.
- dot-ls does not check attribute values or layout rules. It is not a full
  Graphviz validator.

## HTML-like labels

DOT can use HTML-like markup in a label when the value is in angle brackets:
`label=<<B>bold</B>>`. dot-ls checks this markup in the `label`, `xlabel`,
`headlabel` and `taillabel` attributes. A quoted value, such as
`label="<B>text</B>"`, is a normal string. dot-ls does not check it as markup.

dot-ls checks:

- That tags are complete and correctly closed.
- That character references are complete, for example `&amp;` and not `&amp`.

dot-ls does not yet check which tags and attributes Graphviz accepts.

Try it with [html-labels.dot](../examples/html-labels.dot). The label
`<<TABLE><TR></TABLE>>` gives:

```text
HTML label: closing tag '</TABLE>' does not match '<TR>'.
close the most recently opened element using its opening name
```

How it works:

- dot-ls publishes the DOT errors first. Then it checks the labels and publishes
  all findings together. For a short time after an edit, earlier label errors
  can disappear until the label check finishes.
- dot-ls checks every label. When it can, it reuses the results for labels
  that did not change, so an edit elsewhere in the file costs less.
- A syntax error in the DOT text can stop dot-ls from finding the labels after it.

## Quick fixes

When the parser knows how to repair an error, dot-ls offers a quick fix. Put the
cursor on the error and open the code actions. Fix titles start with the action,
for example:

- Insert closing ']'
- Replace with '->'
- Insert ';'
- Remove unexpected text
- Put double quotes around this name

Try it with [quick-fixes.dot](../examples/quick-fixes.dot). It has two errors:

- `a -- b` in a `digraph` offers **Replace with '->'**.
- The label `<<B>&amp</B>>` offers **Insert ';'**.

Rules:

- All fixes come from the parser. dot-ls does not guess a repair.
- dot-ls marks certain fixes as preferred. Other fixes are possible repairs. The
  editor shows both kinds. You choose one.
- dot-ls never applies a fix by itself. There is no "fix all" action.
- A fix belongs to one version of the file. If the file changed, dot-ls rejects
  the old fix.
- The editor must support versioned edits (`documentChanges`). Zed does. An
  editor without this support gets no fixes.

## Hover help

Hover over an attribute name to see help for it. The help for `shape` reads:

```text
shape

The shape used to draw a node.

- Type: shape
- Default: ellipse
- Applies to: node

start [shape=box];

Graphviz reference
```

The help shows the value type, the default value, the minimum value when there
is one, and the objects that can use the attribute: node, edge, graph, subgraph
or cluster. Common attributes also have a description and an example. Other
attributes have a short general description. The link opens the Graphviz page
for the attribute.

Try it with [attribute-help.dot](../examples/attribute-help.dot). Hover over
`shape`, `rankdir` or `arrowhead`.

Rules:

- Hover works for attribute names in attribute lists, such as `[shape=box]`,
  and in graph assignments, such as `rankdir=LR`.
- Quoted and joined names work, for example `"shape"` and `"sha" + "pe"`, up to
  256 bytes.
- There is no help for node names, values, comments, unknown attributes, or
  names inside HTML-like labels.
- The default is the Graphviz default. It is not the value that your graph
  actually uses for that object.
- The editor chooses Markdown or plain text. If the editor does not say, dot-ls
  uses plain text.

## Completion

dot-ls suggests keywords and attribute names that fit the cursor position.

| Cursor position | Suggestions |
| --- | --- |
| Start of the file | `strict`, `graph`, `digraph` |
| After `strict` | `graph`, `digraph` |
| Inside the graph, at the start of a statement | `graph`, `node`, `edge`, `subgraph` |
| After an edge operator (`->` or `--`) | `subgraph` |
| Inside a node attribute list, `a [` | Node attributes, such as `shape` |
| Inside an edge attribute list, `a -> b [` | Edge attributes, such as `arrowhead` |
| Inside a `graph [` list | Graph attributes, such as `rankdir` |
| Inside a subgraph or cluster `graph [` list | Subgraph or cluster attributes |

The attribute names come from the parser's catalog of 177 Graphviz attributes.
A cluster is a subgraph whose name starts with `cluster`.

dot-ls gives no suggestions for attribute values, ports, strings, comments or
HTML-like labels. It also gives no attribute names for graph assignments such as
`rankdir=LR`. Completion still works when the file has errors.

**Known bug:** dot-ls gives no attribute names when the cursor is directly before
`]`. For example, `a [|]` and `a [sha|]` give nothing, where `|` is the cursor.
`a [| ]` and `a [sha| ]` work. Zed adds the `]` when you type `[`, so this bug
affects most new attribute lists in Zed. To work around it, type a space, press
the left arrow key once, then type the attribute name.

Zed can also show its own word suggestions next to the dot-ls suggestions.

## Find references

Put the cursor on a node name and find its references. dot-ls lists every place
where the file uses that node:

- Node statements, such as `build [label="Build"];`
- Edge ends, such as `source -> build`
- Quoted and joined names. `build`, `"build"` and `"bu" + "ild"` are the same node.
- The node part of a port, such as `build` in `build:input`

It does not count port names, subgraph names, attribute values or label text.
The editor decides whether the first use (the declaration) is in the list.

Try it with [references.dot](../examples/references.dot). Put the cursor on
`build`. With the declaration included, dot-ls finds five uses.

Limits:

- References work only when the file has no syntax errors. Otherwise, the
  request fails with "Node references are unavailable: analysis did not complete
  within limits." Fix the syntax errors first.
- dot-ls searches only the current file.
- A request returns at most 10,000 locations.

## Outline

The outline shows the graph, its subgraphs and clusters, and the nodes declared
in each one. In Zed, set `document_symbols` to `"on"` for **DOT (dot-ls)**. The
[Zed guide](../editors/zed/README.md#settings) shows how.

| DOT item | Outline symbol kind |
| --- | --- |
| Graph | Namespace |
| Subgraph | Package |
| Cluster (a subgraph whose name starts with `cluster`, case-sensitive) | Module |
| Node | Variable |

Rules:

- Only node statements, such as `start;` or `a [shape=box];`, add a node. Edges
  do not add nodes.
- A node declared twice appears twice.
- A subgraph without a name appears as `{…}`.
- Names longer than 128 bytes are shortened and end with `…`.
- The outline keeps working when the file has errors.

Try it with [outline.dot](../examples/outline.dot). The line `broken -> ;` is an
intentional error. The outline still shows the nodes after it:

```text
Outline
  start
  cluster_inputs
    source
    cache
  processing
    parse
    validate
  {…}
    anonymous_node
  output
```

Some errors can still hide the rest of the file. An unclosed string, comment or
HTML-like label is an example.

Editors that do not support a tree get a flat list instead.

## Zed editor features

The Zed extension adds these features. They come from the extension's grammar
and queries. They do not use the server.

- Syntax colors from your Zed theme. HTML-like labels have colors that differ
  from quoted strings.
- Pairs for `{}`, `[]` and `""`, and matching of the outer `<` and `>` of an
  HTML-like label.
- Indentation and code folding.

Try them with [editor-features.dot](../examples/editor-features.dot) and
[html-colors.dot](../examples/html-colors.dot).

## Not supported yet

dot-ls does not have these features:

- Rename, go to definition and formatting
- Graph preview
- Attribute value completion
- Graphviz tag and attribute rules for HTML-like labels
- An explanation of where a node gets its attribute values
- A search across all files in a project
- A command-line checker

[Requirements](REQUIREMENTS.md) lists the open work.

## Resource limits

dot-ls has fixed limits. They keep its memory and work bounded, even for very
large or broken files. When a feature reaches a limit, dot-ls reports that the
result is unavailable or incomplete. It does not silently return a shorter result.

The limits apply to the data that dot-ls keeps. They are not limits on the total
memory of the process. Temporary work, JSON output, memory allocator pages and
thread stacks use more memory. MiB means 1,048,576 bytes.

Limits you may notice:

| Resource | Limit |
| --- | --- |
| File size / one LSP message | 200 MiB / 256 MiB |
| Open files / file URI length | 128 / 8 KiB |
| DOT nesting depth / findings kept per file | 256 / 1,000, with a notice when reached |
| Find references | 10,000 locations per request |
| Outline | 250,000 symbols; names shown up to 128 UTF-8 bytes, then `…` |
| Waiting feature requests | 64 per file, shared by all features; string request IDs up to 8 KiB |
| One HTML-like label | 8 MiB; 256 nested elements; 100,000 nodes; 200,000 attributes |
| HTML-like label findings | 64 per label; 1,000 per file |
| Attribute hover data | 8 MiB per file, counted in the completion memory below |

Internal limits:

| Resource | Limit |
| --- | --- |
| Active and pending source allocations | 512 MiB combined |
| Parser pump | 4,096 work credits |
| Completion payload | 64 MiB per document; 128 MiB live total |
| References payload | 128 MiB per document; 256 MiB live total |
| Outline memory / response | 32 MiB per document; 64 MiB live total / conservative 128 MiB JSON bound |
| HTML cache payload | 8 MiB and 4,096 entries per document; 32 MiB and 16,384 live entries across generations |
| Selected HTML span capacity | Source bytes / 4 + 16 per job |
| Output JSON body | 128 MiB bulk; 64 KiB control |
| Output bulk credits / frames | 144 MiB / 256; includes active encoders |
| Output control reserve / frames | 512 KiB / 64 |
| Output metadata allowance | 256 KiB bulk / 16 KiB control per live frame; includes URI and growth overlap |
| Event loop progress | At most 64 KiB output and 256 KiB input per turn |
| EOF/exit drain | At most 2 seconds; a stopped reader fails the connection |

[Architecture](ARCHITECTURE.md) explains how output and memory are bounded.

More details:

- The outline reads at most 4,096 bytes of a name to make its display text. The
  symbol range still covers the full name.
- If the attribute hover data for a file is larger than its limit, hover returns
  an error for that version of the file. Errors and warnings still work.
- Output memory is used only when needed. The limits above are not memory that
  dot-ls reserves at start.

## Known restrictions

- Large files cost more on each edit. The editor sends the full text, and dot-ls
  copies and checks all of it.
- dot-ls uses one worker thread for analysis. A long check of one file can delay
  results for another file.
- Building a large response uses CPU time on the thread that sends it.
- If the editor stops reading responses, dot-ls still reads edits and cancel
  requests. If its reserved space for error replies runs out, it closes the
  connection.
- If a response is too large for the output space, dot-ls sends an error instead.
  It drops only diagnostics that a newer edit has already replaced.

[Architecture](ARCHITECTURE.md) explains how dot-ls owns and releases memory.
