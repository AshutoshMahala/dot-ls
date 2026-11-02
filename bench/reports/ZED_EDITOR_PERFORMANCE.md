> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

# Isolated Zed editor measurements

Measured 2026-10-15. MB and GB below are decimal units. These results concern
Zed's editor features. No dot-ls server was running in the test sessions.

The main finding is that embedded HTML parsing has a substantial editor cost.
The separate pair and indent queries did not show a large additional cost at
5 MB. These measurements do not establish that those queries are free.

## Environment and isolation

- Apple M4 Pro, 14 logical CPUs, 48 GiB physical memory; native arm64 macOS.
- Installed Zed 1.24.2. This differs from the older live session used in earlier reports.
- A temporary copy of the installed app used a distinct bundle identifier and
  an ad-hoc signature. No Zed source was changed or rebuilt.
- Each case started a fresh process with a separate temporary data directory.
  `ZED_STATELESS=1` allowed it to coexist with the user's original Zed process.
- The same One Dark theme, 16-point buffer font, and window size were used.
- Language servers, edit predictions, telemetry, auto-update, autosave, and the
  internal performance profiler were disabled in test settings.
- Zed's project-trust prompt was left in Restricted Mode. Its delayed appearance
  interfered with some early cursor-navigation attempts; see exclusions below.
- Only the DOT adapter was preseeded. Zed also installed its default HTML 0.3.2
  extension in each temporary profile. Both use the same pinned HTML grammar.
- All feature variants were copies under `/private/tmp/dot-ls-zed-isolated`.
  Production adapter queries and the user's settings/buffers were not changed.
- The user's existing Zed session was not the measured process. Other applications
  could still affect scheduling and memory pressure. No attempt was made to reserve
  the whole machine or control when the user closed other applications.

## Workload

These are new **HTML-heavy fixtures**, not the earlier mostly plain-DOT examples.
A 170-byte record contains one multiline HTML label and one edge statement.
The label contains TABLE/TR/TD/B/BR tags. Each label is a separate injection.
Repeated DOT node identifiers are legal and do not affect this editor-only test.

| File size | HTML labels |
| --- | ---: |
| 5 MB | 29,411 |
| 20 MB | 117,646 |
| 40 MB | 235,293 |

Every variant at a given size opened exactly the same bytes. File hashes are in
[the environment record](../results/zed-editor-isolated/environment.json).
These dense fixtures are useful for exposing injection costs. Do not apply their
memory ratios directly to files with few labels or one large label.

Variants:

- `dot`: DOT highlighting, existing DOT brace/square pairs and DOT indent rules;
  HTML-like content gets one string style. No embedded HTML parsing.
- `colors`: HTML injection, HTML colors and outer delimiter color distinction.
- `pairs`: colors plus outer delimiter, complete HTML tag and self-closing tag pairs.
- `full`: pairs plus HTML wrapper and element indent rules used with editor folding.

Removing the new indent queries does not disable Zed's general indentation-based
folding. This comparison measures the added rules, not an editor with all folding
removed. Likewise, DOT brace matching remains enabled in every variant.

The full adapter was checked at 5 MB first. Navigation, typing, matching, and
folding remained usable, so testing advanced to 20 MB and then 40 MB.
At 40 MB, the inserted character was visible in the next captured editor state.
Folding/unfolding the first label and repeated wrapper-pair navigation also worked.
No exact keyboard-to-paint or frame-time measurement was made.

## Memory after opening

RSS is for the **main editor process**, including its baseline, text buffers,
syntax trees, renderer, extension machinery, and allocator retention.
The added column subtracts each process's own pre-open baseline before comparing
full against DOT-only. Baselines were approximately 231–241 MB.

| File | DOT-only RSS | Full adapter RSS | Added RSS, adjusted for baseline |
| --- | ---: | ---: | ---: |
| 5 MB | 488.3 MB | 598.1 MB | 118.0 MB |
| 20 MB | 1,139.7 MB | 1,591.2 MB | 449.6 MB |
| 40 MB | 2,011.6 MB | 2,916.6 MB | 901.4 MB |

Most of the total memory is already present in the DOT-only case. At 20 and
40 MB, enabling the HTML features adds about 3.8 KB RSS per label in this fixture.
That is an observed ratio, not proof of a particular allocation size or an exact
breakdown of Tree-sitter internals.

The corresponding open physical footprints were 442.7 / 557.4 MB at 5 MB,
1,092.5 / 1,498.9 MB at 20 MB, and 1,965.7 / 2,803.5 MB at 40 MB
(DOT-only / full). Footprint and RSS are different macOS accounting measures.
Neither is the sum of live application allocations.

## Incremental feature cost at 5 MB

| Variant | RSS after open | Increase from its own baseline | CPU seconds during open |
| --- | ---: | ---: | ---: |
| DOT only | 488.3 MB | 247.4 MB | 0.77 |
| HTML colors | 600.7 MB | 359.8 MB | 1.32 |
| Colors + pairs | 597.8 MB | 361.9 MB | 1.44 |
| Colors + pairs + indent/folding rules | 598.1 MB | 365.5 MB | 1.42 |

HTML colors require the extra syntax layer. They account for almost all of the
measured open-memory increase. Adding pair and indent rules changes the
baseline-adjusted value by a few MB in these single runs. The small differences
are not strong evidence of a reproducible per-feature allocation cost.
Individual pair/indent variants were tested only at 5 MB. The 20/40 MB checks
compare DOT-only with the full adapter; they do not separately attribute every
query's cost at those sizes.

## CPU work

These are **whole-process CPU seconds**, summed across threads. They are not
wall-clock open latency or syntax-parser-only time. The interval starts at a
marker before the Open action and ends at a marker after the document has loaded.
It includes UI work and a small amount of idle work during manual/tool gaps.

| File | DOT-only open CPU | Full adapter open CPU | Difference |
| --- | ---: | ---: | ---: |
| 5 MB | 0.77 s | 1.42 s | +0.64 s |
| 20 MB | 2.25 s | 4.68 s | +2.43 s |
| 40 MB | 4.06 s | 9.44 s | +5.38 s |

For a separate 40 MB check, one `x` was inserted into the text `alpha` inside the
first B tag. Analysis was allowed to settle before undo. It was allowed to settle
again before the result was recorded. The file content was restored.

| 40 MB operation | DOT-only CPU | Full adapter CPU | Difference |
| --- | ---: | ---: | ---: |
| Insert into HTML text | 1.48 s | 2.43 s | +0.95 s |
| Undo that insert | 1.40 s | 2.22 s | +0.82 s |

These are one observation per operation and variant, after an earlier edit batch.
They include event handling, reparsing, rendering, and idle work between markers.
They do not identify how much CPU each internal stage consumed. The mean of the
two operations is 1.44 versus 2.33 CPU-seconds, about 61% more process CPU.
A responsive typed character can coexist with expensive background work.

## Edit memory and controls

Editing caused additional transient and retained memory. At 40 MB, sampled RSS
peaks were 3.39 GB for DOT-only and 4.38 GB for the full adapter. The runs included
five insert/undo cycles, followed by the separately settled insert and undo.
The full run also exercised pair navigation and folding. Timing between edits
was controlled through sequential UI observations, but was not identical.
These are observed process peaks, not an exact matched-workload high-water comparison.

At 20 MB, the full exploratory run reached 4.43 GB sampled RSS. It included extra
setup edits and therefore must not be compared as an identical edit sequence
with the 1.55 GB DOT-only run. A larger fixture does not necessarily produce a
larger sampled peak: cancellation, allocator reuse, and edit cadence matter.

At 40 MB, five fold/unfold cycles added about 0.43 MB retained RSS at their
markers. Ten subsequent matching-bracket jumps added about 0.13 MB. Those small
changes suggest no large new persistent index for the operations. They do not
establish exact query allocations. CPU for the fold interval was 1.66 s and for
the following matching interval 3.12 s, including UI work and tool gaps. There is
no equivalent no-feature control for these intervals, so these are not incremental
feature CPU costs.

## Measurement method and limitations

`tools/zed_editor_bench.py` samples macOS `proc_pid_rusage` at a target interval
of 50 ms. The structure reports CPU counters in Mach time units on this machine.
The measured `mach_timebase_info` is 125/3; the counters were checked against
`ps` cumulative CPU time before reporting seconds. Memory counters are bytes.
The sampler is a separate process and is not included in editor CPU/RSS.
Short peaks between samples can be missed.

The `settle` helper waits for two consecutive one-second intervals with less
than 0.10 CPU-seconds each. This is a practical quiescence check, not a Zed parse
completion event. It cannot prove that every deferred task has completed.

Native UI automation adds substantial observation overhead. Its command timings
are not used as typing latency. Exact keyboard-to-paint latency, dropped frames,
and parse-ready wall time remain unmeasured. These results support conclusions
about editor resource cost and observed responsiveness, not a millisecond typing
latency claim.

Each size/variant has one selected process run. There are no confidence intervals
or claims about tail latency. CPU open markers include differently sized gaps.
The large memory and CPU differences are useful; small differences need repeated
interleaved runs before making a fine-grained optimization decision.

The first full 5 MB pilot is retained as `full-5-pilot-excluded.json`. It opened
an extra worktree and had exploratory actions, so it is excluded from tables.
Early 5 MB edit batches used unreliable navigation. Their CPU timings are also
excluded. Open measurements do not depend on the later edit position.
The selected 20 MB HTML edit and all selected 40 MB operations used a cursor
position checked directly in the editor.

Disabled experimental queries were represented by empty query files. Zed logged
missing-capture messages for those files and disabled those queries, as intended.
The controls therefore include this small first-load setup overhead. Production
queries did not produce those messages. Measured query/config copies are saved
under `zed-editor-isolated/variants/` so the control is explicit.

## Records and reproduction

- [Summary](../results/zed-editor-isolated/summary.json): selected counters and derived CPU seconds.
- [Environment](../results/zed-editor-isolated/environment.json): version, settings scope, hashes and counts.
- `zed-editor-isolated/<variant>-<size>.json`: stage markers and raw samples.
- `zed-editor-isolated/variants/`: exact language queries and settings used.
- `tools/zed_editor_bench.py`: fixture generator, profile setup, sampler and stage markers.

From the project root, after building/installing the development adapter:

```sh
python3 tools/zed_editor_bench.py prepare
python3 tools/zed_editor_bench.py prepare-app
python3 tools/zed_editor_bench.py launch full 5
python3 tools/zed_editor_bench.py monitor
```

The monitor runs in a separate terminal. Reuse the existing temporary app if
`prepare-app` reports that it already exists. In another terminal, use
`mark preopen`, open the fixture through Zed Bench's Open dialog, then
`mark opened`. Keep Restricted Mode. Check the cursor position visually before
editing. Use `mark <name>` around each operation and `settle` after it. `finish`
saves the samples and stops only the process launched for this test. The helper
checks its stored process start time before sending a signal.

Run the DOT-only control with `launch dot 5`. Use `colors` and `pairs` for the
intermediate variants. Start at 5 MB and check responsiveness before changing
the size to 20 or 40. Use fresh processes, the same bytes, the same window, and
the same operation sequence. Do not compare rapid-edit CPU as if every edit
completed its analysis: later edits can cancel or coalesce earlier work.

All benchmark editor processes were stopped after measurement. The temporary app,
profiles, and fixtures remain under `/private/tmp/dot-ls-zed-isolated` for inspection.
The dot-ls binary was unchanged. No server performance claim is inferred from
these editor measurements.

The next performance investigation should focus on the HTML injection path.
Keeping the server lean does not by itself keep the editor's syntax trees lean.

For allocation attribution and the compact grammar experiment, see
[the grammar memory study](ZED_GRAMMAR_MEMORY.md).
