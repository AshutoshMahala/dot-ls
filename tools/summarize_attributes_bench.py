#!/usr/bin/env python3
"""Summarize the saved attribute-help server comparison."""
import argparse
import json
from pathlib import Path
import platform
import statistics

root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',type=Path,default=root/'bench/results/attributes')
p.add_argument('--build',default='Zig 0.16.0 ReleaseSafe; page allocator, packed HTML entries, buffered JSON')
a=p.parse_args();out=a.output
data=json.loads((out/'comparison.json').read_text())
rows=[]
for mb in sorted({r['mb'] for r in data['runs']}):
    for kind in ['plain','html']:
        row={'mb':mb,'kind':kind}
        for label in ['before','after']:
            runs=[r for r in data['runs'] if (r['mb'],r['kind'],r['label'])==(mb,kind,label)]
            assert len(runs)==3, (mb,kind,label,len(runs))
            median=statistics.median
            row[label]={
                'open_diagnostics_ms':median(r['phases'][0]['final_diagnostics_ms'] for r in runs),
                'edit_diagnostics_ms':median(p['final_diagnostics_ms'] for r in runs for p in r['phases'][1:]),
                'broken_diagnostics_ms':median(r['phases'][1]['final_diagnostics_ms'] for r in runs),
                'repair_diagnostics_ms':median(r['phases'][2]['final_diagnostics_ms'] for r in runs),
                'open_completion_ready_ms':median(r['phases'][0]['completion_ready_ms'] for r in runs),
                'settled_rss_bytes':median(r['phases'][-1]['settled']['rss_bytes'] for r in runs),
                'peak_rss_bytes':median(r['resources']['actual_peak_rss_bytes'] for r in runs),
                'idle_rss_bytes':median(r['idle']['rss_bytes'] for r in runs),
                'startup_ms':median(r['startup_ms'] for r in runs),
                'hover_ms':median(p['hover_ms'] for r in runs for p in r['phases']),
            }
        rows.append(row)
summary={'platform':platform.platform(),'build':a.build,
         'method':'Three fresh processes per size/layout/build, alternating order. Pre-encoded open/broken/repair. Readiness includes the completion reply after diagnostics. Settled RSS waits for all background work. Actual peak RSS uses wait4; editor and harness memory excluded. No concurrent builds/tests/UI actions during measurement. Check each run for feature support; unsupported-method error timing is not a hover baseline.',
         'builds':data['builds'],'rows':rows}
(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
for row in rows:
    print(row['mb'],row['kind'],json.dumps(row['after']))
