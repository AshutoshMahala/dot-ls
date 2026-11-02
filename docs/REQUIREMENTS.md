# Requirements and status

This is the current implementation requirement set. Historical feature plans and
measurement reports do not override it. This development checkpoint is not a
completed M0 release.

## Required design

- Run as a native stdio LSP process. Add no HTTP server or network listener.
- Keep the implementation self-contained with pinned dependencies and licenses.
- Use explicit memory ownership, bounded allocations and cooperative cancellation.
- Keep startup small and diagnostics usable on large files. Measure each feature
  that adds parse work, construction work or retained data.
- Use compact feature indexes by default. Do not retain a full AST without a
  demonstrated need and an agreed measured tradeoff.
- Follow [ARCHITECTURE.md](ARCHITECTURE.md), including its ownership and failure rules.

## Feature requirements

Existing IDs are retained so earlier evidence can still be traced. This cleanup
assigns the previously unused IDs R-FEAT-007 through R-FEAT-011 to implemented
requirements that were formerly described only in prose.

| ID | Requirement | Current status |
| --- | --- | --- |
| R-FEAT-001 | Useful typed diagnostics, repair guidance, related locations and negotiated positions | Implemented |
| R-FEAT-002 | DOT keyword completion | Implemented; context filtering is covered by R-FEAT-007 |
| R-FEAT-003 | Logical node references and later provenance | References implemented; provenance and a separate first-occurrence command deferred |
| R-FEAT-004 | Analyze outer DOT before delayed HTML checks, preserving current DOT findings | Implemented, with bounded exact-content reuse |
| R-FEAT-005 | Choose retained representations from feature needs, ownership and measured costs | Applies to all changes; current features retain compact indexes |
| R-FEAT-006 | Preserve before/after diagnostics, startup, memory and request evidence | Required development practice |
| R-FEAT-007 | Filter keywords by syntactic editing context | Implemented with lexical context; it is not a full semantic completion engine |
| R-FEAT-008 | Zed brace pairing and indentation | Implemented in the editor adapter |
| R-FEAT-009 | Theme-based HTML-like content coloring, distinct from quoted strings | Implemented in the editor adapter |
| R-FEAT-010 | Outer HTML delimiter distinction, matching pairs and folding | Implemented through editor grammar/query support |
| R-FEAT-011 | Check all selected HTML labels with bounded storage rather than a count cap | Implemented; resource failures must still report incomplete checking |
| R-FEAT-012 | Named dot-ls parser policy and missing stream validation checks | Implemented without a full AST |
| R-FEAT-013 | Parser-provided quick fixes with version safety | Implemented; no guessed repairs or fix-all |
| R-FEAT-014 | Compact hierarchical outline that survives recoverable syntax errors | Implemented; explicit limits and flat-client fallback |
| R-FEAT-015 | Suggest attribute names for the current node, edge or graph scope | Implemented in attribute lists using the pinned catalog; value suggestions deferred. Known bug: no names when the cursor is directly before `]` |
| R-FEAT-016 | Explain known attribute names on hover without retaining source or a full tree | Implemented with bounded compressed spans and catalog metadata |

Descriptions of feature behavior and limits live in [FEATURES.md](FEATURES.md).
Do not duplicate the same limit table in each feature report.

## Acceptance rules

- Open, full-text change and close work for multiple documents and non-file URIs.
- Edits and close/reopen must never publish an older generation's results.
- UTF-8, UTF-16 and UTF-32 positions must agree with source ranges, including
  multibyte text and CR/LF/CRLF line endings.
- A compact index must not borrow freed source. Close and shutdown release ownership.
- Findings, resource failures and validation gaps must be visible; a successful
  partial outline must not hide omitted symbols.
- Broken-file outline tests keep recognized declarations on both sides of an
  error. Incomplete attribute names must not become nodes.
- HTML reuse requires exact bytes after hash comparison and current range rebasing.
- Quick fixes use parser-provided spans/replacements and versioned document edits.
- Tests distinguish editor-owned grammar features from LSP features.
- Presentation uses short plain-text diagnostics, action-first fix titles and
  negotiated Markdown/plaintext hover templates. Keep colors and panels owned
  by the editor. Format help on demand without retaining full source or an AST.

## Remaining release work

The following areas prevent a blanket claim that M0 is complete:

- Define and audit the final M0 release checklist and all release gates.
- Runtime/protocol migration steps 0–8 are implemented, including bounded output.
  The local packaged Zed smoke check passes, including user-confirmed diagnostics,
  hover and quick-fix application. Review worst-case request fairness for release.
  The Package workflow runs the protocol tests on Linux ARM64 and x86-64. It has
  not run on GitHub yet. Until it passes, Linux coverage is a cross-build only.
- macOS sustained-edit, cancellation, multi-document/error-load, close/reopen,
  memory recovery, active-shutdown and paused-reader checks pass for the tested
  5/20/40 MB workloads. See [PERFORMANCE.md](PERFORMANCE.md). Carry these checks
  into the supported-platform release gates; this evidence does not establish a
  guaranteed wall-clock cancellation bound or exhaustive workload coverage.
- The parser pin is `01b0a8e`, with no local patches. Public statement/head,
  delimiter and extent events now supply the outline information. Keep broken-file
  hierarchy, ranges, allocation-failure and metering checks as regression gates.
- Native and prebuilt Zed packaging is implemented for 0.0.1. The repository is
  `AshutoshMahala/dot-ls`. Its Package workflow builds all archives, runs the
  protocol tests on each of the four systems after clean extraction, and creates
  a draft release for a version tag. The workflows have not run on GitHub yet.
  See [DEVELOPMENT.md](DEVELOPMENT.md#continuous-integration).
- Archives rebuilt with the `01b0a8e` pin pass all protocol tests after clean
  extraction on Mac ARM64
  ([check result](../bench/results/packaging-01b0a8e/checks.json)). The isolated
  Zed managed-cache launch, with diagnostics, hover and quick fixes confirmed by
  the user, used parser `8615e9f`. Repeat it with the current pin before release.
- Publishing the first release, testing the first automatic server download,
  deciding on signing and notarization, and submitting to the Zed gallery remain
  separate work. Compact grammar experiments remain outside the packaged default.
- Fix the attribute-name completion bug before release. Zed adds `]` when the
  user types `[`, so the cursor is usually directly before `]`.
- Decide release scope for CLI checking, tracing, parent-process monitoring and
  editor coverage. They are not implemented release claims.
- Keep deferred features explicit: provenance, rename, attribute value completion,
  Graphviz vocabulary validation, formatting and preview.

This document records known scope and gaps. It is not an assertion that every
requirement for a public release has already been specified or tested.
