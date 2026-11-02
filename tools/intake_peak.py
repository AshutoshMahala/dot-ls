#!/usr/bin/env python3
"""Measure real process high-water RSS with macOS time; no server instrumentation."""
import json, pathlib, queue, re, subprocess, sys, threading, time
project = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(project / 'tests'))
import lsp
runs = []
for errors in (False, True):
    text = 'digraph {\n' + 'a -> b;\n' * 4_999_998 + ('@}\n' if errors else '}\n')
    payload = json.dumps({'jsonrpc': '2.0', 'method': 'textDocument/didOpen', 'params': {'textDocument': {'uri': 'untitled:test', 'version': 1, 'languageId': 'dot', 'text': text}}}).encode()
    for name, binary in zip(('before', 'inplace'), sys.argv[1:3]):
        c = lsp.Client.__new__(lsp.Client)
        c.start = time.perf_counter()
        c.p = subprocess.Popen(['/usr/bin/time', '-l', binary, 'lsp'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        c.q = queue.Queue(); threading.Thread(target=c.read, daemon=True).start()
        c.init(); c.raw(payload); assert bool(c.diag(1)) == errors
        c.send('shutdown', id=90)
        while c.get().get('id') != 90: pass
        c.send('exit'); c.p.stdin.close(); assert c.p.wait(timeout=10) == 0
        output = c.p.stderr.read().decode()
        match = re.search(r'(\d+)\s+maximum resident set size', output); assert match, output
        runs.append({'variant': name, 'errors': errors, 'source_bytes': len(text.encode()), 'peak_rss_bytes': int(match[1]), 'time_output': output})
report = {'runs': runs, 'notes': 'macOS /usr/bin/time -l maximum resident set size in bytes, one process per fixture/variant, uninstrumented ReleaseSafe binaries. Includes startup, request, analysis/diagnostics and shutdown. Latency measured separately.'}
(project / 'bench/results/legacy/intake-peak-memory.json').write_text(json.dumps(report, indent=2))
print(json.dumps([{k:v for k,v in r.items() if k != 'time_output'} for r in runs], indent=2))
