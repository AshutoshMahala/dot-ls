#!/usr/bin/env python3
"""Compare 15 direct warm LSP starts; no time wrapper or build work."""
import json, pathlib, statistics, sys, time
root = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root / 'tests'))
import lsp
runs = []
for label, binary in zip(('before', 'after'), sys.argv[1:]):
    lsp.BIN = str(pathlib.Path(binary).resolve())
    samples = []
    for _ in range(15):
        client = lsp.Client()
        client.init()
        samples.append((time.perf_counter() - client.start) * 1000)
        client.stop()
    runs.append({'label': label, 'warm_startup_ms': samples, 'median_ms': statistics.median(samples)})
assert len(runs) == 2, 'Pass baseline and candidate binaries'
(root / (sys.argv[3] if len(sys.argv)>3 else 'bench/results/legacy/references-startup.json')).write_text(json.dumps({'runs': runs, 'notes': '15 direct warm starts per binary through initialize reply, no time wrapper. ReleaseSafe builds.'}, indent=2) + '\n')
