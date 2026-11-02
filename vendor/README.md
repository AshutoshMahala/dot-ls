# Vendored dependency

`dot-parser/` starts from commit
`01b0a8e1b1a69bcf4535091e1c8870e5063eb7f4` (version 0.5.0 with unreleased APIs).
It has no package dependencies. Both original licenses are included.
The server builds from this copy. No sibling checkout or network access is needed.

The dependency has no local patches. Its bytes match the pinned commit exactly.
The sibling parser is unchanged. The CLI and LSP identify this copy as
`0.5.0 (01b0a8e)`.

## Trusted identifier operations

Upstream `identifier.fromName(source, name).hash()` and `.eql(other)` skip repeated
syntax checks for complete parser-recognized `dot.Name` values. The source must
stay alive and unchanged. Names retain the eight-byte layout of source spans.
References keep these typed names during construction and compare logical values
after hash matches. Duplicate-attribute checks and label selection use the same
API. Arbitrary editor text still needs checked helpers. Static label-key targets
use `identifier.check`; no unchecked constructor or new identifier patch is used.

## Public outline observations

The former outline hook is removed. The consumer uses public statement starts,
`observations.statement_head`, `observations.delimiter` and `statement_extents`.
Graph/scope begin events establish hierarchy. Recognized closing-brace events
close it, including during recovery; skipped delimiters and duplicate end-scope
notifications do not add closures. Node commits supply complete declaration
ranges, excluding trailing trivia and optional semicolons.

The outline builder keeps one tentative statement start. A node head makes it a
provisional entry even when its attributes fail. An actual EOF diagnostic in
node-ending grammar preserves a bare or complete ported prefix. Assignment/edge
heads, unfinished ports and lexical failures do not become nodes. This uses
typed parser facts, not a second lexer or a guessed repair.

Public observations cost dispatch credits and caller work. The consumer owns
the bounded outline storage and isolates allocation failures. No parser event
queue, source copy or full AST is retained. Tests cover recovery, budget
partitioning, declaration ranges, hierarchy and allocation failure.

## Upstream token previews

The current upstream uses `events.Observations` to select names, heads, delimiters
and raw unfinished-token previews. dot-ls selects heads/delimiters for outlines.
Token previews, extra identifier/name observations and result coverage remain
disabled; the current features do not need them.

The new optional `dot.ir` graph layer is included as upstream source but is not
enabled by dot-ls. No graph records, full AST or source snapshot are retained for
it. The existing compact indexes and source-release boundaries stay unchanged.

## Removed patches and verification

Public `Profile.Events(Sink)` sessions now provide metering, cancellation and
borrowed node, edge, attribute and scope events. The count-session,
node-occurrence, HTML-label-span and private-validation-event patches are removed.
Application-owned collectors keep delayed HTML, references and bounded validation
without retaining a full AST. Broader Graphviz label checks remain explicitly off
in the application policy until selected as a separate feature.

`upstream.json` records the exact upstream commit, included-file hashes and patch
order. Run this development check after changing the dependency:

```sh
python3 tools/check_vendor.py
```

The check verifies every file against the upstream hashes. Its optional reversal
support still handles explicitly declared patches, but the current list is empty.
It also rejects undeclared patches or extra files.
This check is a development tool, not a runtime or build dependency.
