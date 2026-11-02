> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

# Zed delimiter and folding checks

Date: 2026-10-15. Changes are limited to the Zed adapter.

## Behavior

- Outer HTML-like DOT delimiters use theme styles, separate from HTML punctuation.
- Outer delimiter mates highlight together.
- Complete HTML opening and closing tags highlight together. The query uses
  syntax-tree element boundaries. A smaller pair inside each opening tag would
  take precedence over the element pair in Zed, so normal element tags match
  their closing tags rather than matching their own angle brackets.
- Self-closing HTML tags pair their own angle delimiters.
- Existing DOT brace and square-bracket queries remain in place.
- Multiline HTML wrappers and inner elements have indent queries.
- A private embedded HTML language keeps these rules local to DOT.
- The extension now supplies a pinned HTML grammar. It does not require the
  separate HTML extension and adds no server dependency.

## Verification

The development extension rebuilt and loaded in Zed. Its build log reported a
successful DOT/HTML grammar build and extension reload. The first two-grammar
build completed in 1.27 seconds. That is installation time, not LSP startup time.

Live checks in `examples/html-colors.dot` confirmed:

- Quoted tag text remains string-colored.
- Outer delimiters are orange in the current theme; HTML tag names are blue.
- Cursor at the outer opener highlights the closing wrapper delimiter.
- Cursor inside TABLE highlights both the complete TABLE opener and closer.
- The wrapper folds to a placeholder and unfolds without changing the text.
- The TABLE gutter control folds its body separately.

## Resource check and limits

No server source or binary changed. The binary remains 800824 bytes.
SHA-256: `06634ddefd6c88f0d168ad6825401b43b57b27a322643d8bb53f234e389d2344`.
There is no new LSP request, server index, or server parse stage for this feature.
The extra work is in Zed's existing syntax-query machinery. The private HTML
language uses the same pinned HTML grammar as the previous HTML injection.

The existing Zed main process RSS was 15,786,144 KiB before the changes and
15,810,736 KiB after reloads and live checks: an increase of 24,592 KiB
(24.02 MiB). The helper remained 12,592 KiB. Main-process sampled CPU was
0.7% before and 2.3% after. These are process snapshots, not peak or timing
benchmarks. Large existing buffers, background work, grammar reloads, and
allocator retention prevent attribution of the delta to these queries.

Small-file matching and folding responded during the live checks. No isolated
large-file query latency or memory benchmark was completed. Do not interpret
these observations as proof of unchanged editor cost at 40 or 100 MB. Server
performance numbers from earlier reports remain the previous measured results.

## Follow-up measurements

The [isolated editor study](ZED_EDITOR_PERFORMANCE.md) now replaces the earlier
shared-session RSS snapshots for assessing editor feature cost. It measures
HTML-heavy 5, 20 and 40 MB files with language servers disabled.
