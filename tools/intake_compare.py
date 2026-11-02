#!/usr/bin/env python3
"""Compare two server binaries with identical pre-encoded 40 MB requests."""
import json, os, pathlib, statistics, sys, time
project = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(project / 'tests'))
import lsp
variants = [('before', pathlib.Path(sys.argv[1]).resolve()), ('inplace', pathlib.Path(sys.argv[2]).resolve())]
text = 'digraph {\n' + 'a -> b;\n' * 4_999_998 + '}\n'
workload = os.environ.get('DOTLS_INTAKE_WORKLOAD', 'edges')
if workload == 'comment': text = 'digraph {/*' + 'a' * 39_999_984 + '*/}'
payloads = []
for v in range(1, 6):
    method = 'textDocument/didOpen' if v == 1 else 'textDocument/didChange'
    document = {'uri': 'untitled:test', 'version': v}
    if v == 1:
        document.update(text=text, languageId='dot'); params = {'textDocument': document}
    else: params = {'textDocument': document, 'contentChanges': [{'text': text}]}
    payloads.append(json.dumps({'jsonrpc': '2.0', 'method': method, 'params': params}, ensure_ascii=False).encode())
runs = []
for repeat in range(2):
    for name, binary in (variants if repeat == 0 else list(reversed(variants))):
        lsp.BIN = str(binary); c = lsp.Client(); c.init(); samples = []
        for v, payload in enumerate(payloads, 1):
            start = time.perf_counter_ns(); c.raw(payload); assert c.diag(v) == []
            samples.append((time.perf_counter_ns() - start) / 1e6)
            time.sleep(.03)
        c.stop()
        runs.append({'name': name, 'repeat': repeat, 'request_ms': samples, 'binary_bytes': binary.stat().st_size})
summary = []
for name, _ in variants:
    samples = [t for r in runs if r['name'] == name for t in r['request_ms']]
    summary.append({'name': name, 'median_ms': statistics.median(samples), 'min_ms': min(samples), 'max_ms': max(samples), 'samples': len(samples)})
report = {'workload': workload, 'source_bytes': len(text.encode()), 'wire_bytes': len(payloads[0]), 'summary': summary, 'runs': runs, 'notes': 'ReleaseSafe. Sequential runs, reverse order on second pass. Pre-encoded full-sync request to diagnostic receipt. Excludes client encoding. No RSS sampling or profiling in timed servers.'}
(project / ('bench/results/legacy/intake-comparison' + ('-comment' if workload == 'comment' else '') + '.json')).write_text(json.dumps(report, indent=2)); print(json.dumps(summary, indent=2))
