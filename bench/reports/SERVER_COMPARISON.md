> Historical experiment report. It describes the build tested at that time.
> Use [current documentation](../../docs/README.md) for the supported design and behavior.

# Controlled server comparison

Measured 2026-10-15. This compares dot-ls with npm dot-language-server 3.2.1.
No editor ran as part of this test. Memory belongs to the server process only.
The Python client is also excluded from server memory measurements.
MB and GB below use decimal units.

On 40 MB plain DOT, median single-error delay is 204 ms for dot-ls versus
5.72 seconds for dot-language-server. Peak server RSS is 125 MB versus 4.48 GB.
However, the dense 20/40 MB HTML cases hit dot-ls’s label-count limit. Those
timings must not be presented as full HTML-validation comparisons.


This report measures the build before the HTML label-cap fix. The current
implementation checks all labels in these dense files. See
[the subsequent fix and before/after measurements](HTML_LABEL_CAP.md).

## Scope and method

The machine is an Apple M4 Pro with 14 logical CPUs and 48 GiB RAM, running native
arm64 macOS 27.0.1. dot-ls is the current normal Zig 0.16.0 ReleaseSafe build.
Its diagnostics, HTML checks, completion context and reference-index work retain
their normal defaults. dot-language-server uses Node 26.11.1 and
`dot-language-support` 4.4.2. No heap limit or feature overrides were applied.
The measured Node heap limit is 4,395,630,592 bytes. Other applications can affect
scheduling. These are local results, not a cross-platform performance guarantee.

The client sends the same UTF-16 and related-information capabilities to both.
Each phase has exactly one outstanding document version. This matters because
dot-language-server does not put a version in its diagnostics. Both receive the
same pre-encoded full-sync JSON-RPC messages over stdio. Client JSON encoding is
outside the timer. Timing starts just before writing the notification and ends
when the complete diagnostic frame is received, before decoding that frame.
It includes pipe transfer and backpressure. It is not internal parse time or
keyboard-to-screen latency. Reading earlier frames can add client overhead.

For HTML, dot-ls sends an outer-DOT result followed by an HTML result. The main
tables use the second notification. First-result timings remain in the raw data.
The other server sends one result. No completion, references or rendering
requests were sent to inflate either server's work. Normal background work was
allowed to settle after each diagnostic phase: three quiet 100 ms CPU intervals,
with a five-second maximum wait. Settled memory is a sample, not proof that GC
will not run later.

The main sequence uses three fresh server processes per file and server. Each
opens a valid file, then receives three error/repair pairs. The single error is
near EOF, so a quick prefix failure cannot stand in for scanning the full file.
Tables show median open times from three observations and median error/repair
times from nine observations each. The nine changes share three processes;
they are not nine independent fresh-process runs.

Memory is sampled with macOS `proc_pid_rusage` every 20 ms. Actual process peak
RSS comes from `wait4` when that child exits; it includes brief intake overlaps
that polling can miss. The peak table uses the highest actual peak of the three
main-sequence processes. Peak memory covers the whole seven-version sequence,
not only the first diagnostic. It is not a heap-allocation breakdown or evidence
of a leak.

Testing started at 5 MB, then advanced to 20 MB and 40 MB. A response gate required
each case to finish diagnostics within 10 seconds, exit cleanly and peak below
6 GB RSS. A sampler could terminate only the owned test process above 6 GB.
The gate measures protocol responsiveness, not editor smoothness. Coverage-limit
notices are recorded separately; a quick incomplete result is not full validation.

## Inputs

The harness generates exact 5,000,000 / 20,000,000 / 40,000,000-byte ASCII files.
It leaves the existing examples and user buffers unchanged. Fixture hashes and
record counts are saved with the results.

- Plain DOT: a chain of uniquely numbered node IDs with quoted edge labels.
- HTML-heavy DOT: a multiline TABLE/TR/TD/B/BR label and an edge per 170-byte record.
  The files contain 29,411 / 117,646 / 235,293 HTML labels respectively.

HTML bodies repeat exactly. This exercises dot-ls's exact-content reuse. It does
not measure the cost of the same number of distinct HTML bodies. Plain and HTML
files have different statement/node densities; compare servers within each row,
not one workload's time with the other as an isolated cost of HTML support.

The error sweep replaces the first `n` in selected edge-source IDs with `@`.
The remaining digits still form a legal numeric ID. Each mutation therefore
adds one independent lexical error, without changing file size or line count.
Multiple faults are spread across the document. A single fault is near EOF.
This is one recovery pattern. Missing delimiters, deep nesting, invalid UTF-8,
non-ASCII position conversion and different HTML errors can behave differently.

The sweep uses a fresh process for each count: 0, 1, 10, 100, 1,000 and 1,200.
It opens that source, then sends it twice more as full document changes. Its
update result is the median of those two repeats, not the larger main sample.

## Startup and idle memory

Fifteen fresh processes per server, with warm filesystem caches. Startup runs
from process creation through the initialize response, including client setup.

| Server | Median startup | Observed range | Median idle RSS |
| --- | --- | --- | --- |
| dot-ls | 8.3 ms | 3.2–12.5 ms | 2.16 MB |
| dot-language-server | 129.2 ms | 114.4–134.1 ms | 57.87 MB |

## Diagnostic turnaround

All times are milliseconds. “Error” is the single near-EOF error change.
† marks dense HTML cases where dot-ls cannot check all selected labels.

| Input | dot-ls open | Other open | dot-ls error | Other error |
| --- | --- | --- | --- | --- |
| plain 5 MB | 41.7 | 690.3 | 44.9 | 297.0 |
| plain 20 MB | 104.0 | 2492.5 | 113.7 | 1580.2 |
| plain 40 MB | 181.9 | 6544.8 | 203.6 | 5718.7 |
| html 5 MB | 37.1 | 318.0 | 41.9 | 164.2 |
| html 20 MB | 94.2† | 1347.7 | 102.0† | 589.6 |
| html 40 MB | 156.7† | 2448.6 | 185.1† | 1873.6 |

“Other” is dot-language-server throughout these tables. Repair turnaround:

| Input | dot-ls repair, ms | Other repair, ms |
| --- | --- | --- |
| plain 5 MB | 40.8 | 300.8 |
| plain 20 MB | 105.7 | 2282.1 |
| plain 40 MB | 184.5 | 5941.5 |
| html 5 MB | 38.8 | 158.1 |
| html 20 MB | 93.0† | 743.7 |
| html 40 MB | 155.8† | 1963.1 |

Both servers passed the response/resource gate at all three sizes. Across the
40 MB plain-DOT main sequence, the other server’s individual changes took about
4.3–7.3 seconds. Passing this ten-second gate does not mean those waits feel instant.

## Server memory

These are **server-only** RSS values. They include the language runtime.
“Open” is median settled RSS after the valid first open; “peak” is the maximum
actual high-water RSS across the main sequences. All values use decimal MB.

| Input | dot-ls open | Other open | dot-ls peak | Other peak |
| --- | --- | --- | --- | --- |
| plain 5 MB | 6.7 | 669.5 | 17.8 | 1978.1 |
| plain 20 MB | 19.2 | 2252.8 | 63.8 | 3488.7 |
| plain 40 MB | 35.9 | 4159.6 | 125.0 | 4481.5 |
| html 5 MB | 5.0 | 417.5 | 17.9 | 1112.7 |
| html 20 MB | 12.3† | 1299.9 | 63.9† | 2034.7 |
| html 40 MB | 22.0† | 2427.7 | 125.1† | 3069.9 |

The JavaScript server’s multi-GB values in this table belong to that server,
not Zed. The longer seven-version main sequence can peak higher than a three-
version error sweep. Sequence length and GC history matter; peak RSS is not
retained AST size. The raw error-sweep records also include their own peaks.

## Error-count sweep

Same-source full-sync repeat medians, milliseconds; two repeats in one fresh
process per count. `*` marks the dot-ls syntax diagnostic cap. `†` marks dense
HTML coverage limits/discovery differences. See the coverage discussion below.

### 5 MB

| Inserted errors | Plain dot-ls | Plain other | HTML dot-ls | HTML other |
| --- | --- | --- | --- | --- |
| 0 | 37.9 | 281.7 | 35.4 | 181.9 |
| 1 | 46.2 | 291.0 | 41.4 | 188.5 |
| 10 | 44.6 | 279.5 | 41.8 | 193.4 |
| 100 | 44.7 | 296.4 | 40.9 | 178.6 |
| 1,000 | 43.6* | 276.5 | 44.4* | 172.3 |
| 1,200 | 42.1* | 299.4 | 43.4* | 163.1 |

### 20 MB

| Inserted errors | Plain dot-ls | Plain other | HTML dot-ls | HTML other |
| --- | --- | --- | --- | --- |
| 0 | 103.5 | 1186.7 | 93.4† | 724.3 |
| 1 | 116.6 | 1537.2 | 111.2† | 782.8 |
| 10 | 114.8 | 1499.2 | 103.0† | 776.1 |
| 100 | 110.9 | 1214.0 | 102.6† | 786.7 |
| 1,000 | 110.0* | 1466.7 | 102.8*† | 810.7 |
| 1,200 | 105.8* | 1514.3 | 100.3*† | 781.7 |

### 40 MB

| Inserted errors | Plain dot-ls | Plain other | HTML dot-ls | HTML other |
| --- | --- | --- | --- | --- |
| 0 | 176.5 | 5363.9 | 161.0† | 1833.1 |
| 1 | 206.8 | 5045.3 | 177.0† | 1431.8 |
| 10 | 192.1 | 3464.3 | 178.0† | 2047.1 |
| 100 | 190.5 | 5038.2 | 180.9† | 1741.5 |
| 1,000 | 185.4* | 5299.8 | 176.6*† | 1372.3 |
| 1,200 | 180.1* | 5101.4 | 167.2*† | 1790.1 |

For example, at 20 MB plain DOT, dot-ls’s zero-error repeat median is 103.5 ms;
one error is 116.6 ms, and 10–1,000 errors stay around 110–115 ms. This does not
show a linear per-error penalty. The other server fluctuates substantially at 40 MB; these two-repeat samples cannot
separate small error-formatting costs from GC and scheduling noise.


## Coverage and interpretation

At 1,000 syntax errors, dot-ls reaches its fixed diagnostic capacity and reports
incomplete syntax analysis. At 1,200 inserted errors it returns 1,000 errors plus
that notice. dot-language-server returns all 1,200 in this test. Capped timings
must not be used as a claim that dot-ls completed the same amount of analysis.

There is also an HTML label-count limit. dot-ls collects at most 65,536 selected
HTML labels. The clean 20 MB and 40 MB dense fixtures exceed that count and
produce `dot-ls:html-incomplete`. Their dot-ls timings measure the outer DOT
analysis plus bounded HTML checking and an explicit limit response. They do not
measure complete HTML validation. Changing the number/position of outer DOT
errors can also change HTML discovery. A missing HTML-limit notice on broken
DOT does not demonstrate that every embedded label was checked.

### HTML coverage checks

A separate probe changes an HTML closing tag from `</B>` to `</I>`.
The outer DOT remains valid.

| Input | dot-ls final result | dot-language-server final result |
| --- | --- | --- |
| Small HTML label with mismatched closing tag | 2 errors | No diagnostics |
| Same tag text inside a quoted DOT string | No diagnostics | No diagnostics |
| 20 MB dense HTML, mismatch in first label | 2 errors plus HTML-incomplete notice | No diagnostics |
| 20 MB dense HTML, mismatch in last label | HTML-incomplete notice; tail mismatch not reported | No diagnostics |

This confirms that the two servers do not provide equal inner-HTML validation.
It also confirms that dot-ls's tail coverage is limited in this dense workload,
with an explicit notice instead of a clean result. The small probe is a
capability check, not an additional performance estimate. Its full diagnostics
are in `coverage-probes.json`.

The installed JavaScript server has broader language-service features. It keeps
an AST, binding and checking results for operations such as rename and hover.
dot-ls uses a smaller representation and a narrower feature set. In the installed
source, both the document-open and document-content-change events rebuild its
AST. The text-document library fires both events on open. That adds work to its
first-open path. The benchmark preserves this behavior; it does not patch the
other server.

Error count does not produce a steady latency increase through this tested range.
Garbage collection and warmup can affect dot-language-server timings; their
individual contributions were not separately profiled.
File size has a much larger effect here. A single syntax error adds work such as
position mapping in dot-ls, while the fixed diagnostic cap bounds high-error
work. These results do not show that error production is free, or that unlimited
errors would have the same cost. Full response sizes and returned counts are in
the raw records.

## Records and reproduction

[The result directory](../results/server-comparison-2026-10-15) contains environment and
binary hashes, fixture hashes, 15 warm-filesystem fresh starts per server,
per-version diagnostic times/counts/examples, actual peak RSS and a derived
[summary](../results/server-comparison-2026-10-15/summary.json). It records only diagnostic
examples and metadata, not full 40 MB document copies.

One initial harness assertion incorrectly required complete HTML validation of
the 20 MB dense fixture. It rejected dot-ls's legitimate limit notice and skipped
its remaining HTML cases. The harness was corrected to separate response success
from coverage. All affected dot-ls HTML cases were rerun. The original rejected
records remain in `runs.jsonl`; the summary selects the latest run for each
server/workload/size/case/trial. All 108 effective benchmark runs exit cleanly.
Nine earlier rejected/skipped records are retained in `harness-superseded.json`.
They are not counted as server crashes or included
in the final timing tables. The raw `analysis_complete` field in some earlier
rows means only absence of an explicit incomplete notice; it is not proof of
equal feature coverage. Production server code and limits were not changed.

Run from the project root on macOS. The harness defaults to the locally installed
Homebrew dot-language-server and the project's normal release binary. Check those
paths and versions before reproducing. Do not combine records from different
server builds in one result directory.

```sh
/path/to/zig-0.16.0/zig build -Doptimize=ReleaseSafe
python3 tools/server_compare.py startup
python3 tools/server_compare.py stage --mb 5
python3 tools/server_compare.py stage --mb 20
python3 tools/server_compare.py stage --mb 40
python3 tools/server_compare.py coverage
python3 tools/summarize_server_compare.py
```

Later sizes require the previous size's response gate to pass. The harness stops
further cases for a server/workload after a response/resource failure. It never
changes Zed settings, raises a server's limits or signals an unrelated process.
Startup tests are fresh processes with warm filesystem caches, not cold-boot
measurements. Error-sweep samples are small; inspect raw ranges before treating
small differences as meaningful.

The earlier editor comparison is in [ZED_COMPARISON.md](ZED_COMPARISON.md).
Its versions, features, fixtures, sequence and timing boundaries differ, so its
numbers should not be mixed with these tables.
