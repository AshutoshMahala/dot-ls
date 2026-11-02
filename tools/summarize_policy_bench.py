#!/usr/bin/env python3
"""Summarize preserved policy comparison results; no server work."""
import json
from pathlib import Path
import statistics as s
root=Path(__file__).resolve().parents[1]/'bench/results/parser-policy'
data={label:json.loads((root/f'{label}.json').read_text()) for label in ['before','after']}
summary={'builds':{},'cases':[]}
for label,d in data.items():
    assert len(d['runs'])==18
    summary['builds'][label]={'sha256':d['sha256'],'startup_ms_median':s.median(r['startup_ms'] for r in d['runs']),
        'idle_rss_bytes_median':s.median(r['idle']['rss_bytes'] for r in d['runs'])}
for mb in [5,20,40]:
    for kind in ['plain','html']:
        case={'mb':mb,'kind':kind}
        for label,d in data.items():
            runs=[r for r in d['runs'] if r['mb']==mb and r['kind']==kind]
            assert len(runs)==3 and all(r['resources']['exit_code']==0 and not r['resources']['safety_stop'] for r in runs)
            case[label]={'peak_rss_bytes_max':max(r['resources']['actual_peak_rss_bytes'] for r in runs),'phases':{}}
            for phase in ['clean','operator-1','repair','operator-1000','duplicates-1000','clean-final']:
                samples=[p for r in runs for p in r['phases'] if p['phase']==phase]
                case[label]['phases'][phase]={'first_ms_median':s.median(p['first_diagnostics_ms'] for p in samples),
                    'final_ms_median':s.median(p['final_diagnostics_ms'] for p in samples),
                    'settled_rss_bytes_median':s.median(p['settled_rss_bytes'] for p in samples)}
        summary['cases'].append(case)
(root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print('| File | Layout | Old clean open | New clean open | Old peak RSS | New peak RSS |')
print('| --- | --- | ---: | ---: | ---: | ---: |')
for c in summary['cases']:
    b,a=c['before'],c['after']
    print(f"| {c['mb']} MB | {c['kind']} | {b['phases']['clean']['final_ms_median']:.1f} ms | {a['phases']['clean']['final_ms_median']:.1f} ms | {b['peak_rss_bytes_max']/1e6:.2f} MB | {a['peak_rss_bytes_max']/1e6:.2f} MB |")
print('\n| 40 MB layout | Inserted findings | Old delay (missed) | New delay (reported) |')
print('| --- | --- | ---: | ---: |')
for c in summary['cases']:
    if c['mb']!=40:continue
    for phase in ['operator-1','operator-1000','duplicates-1000']:
        print(f"| {c['kind']} | {phase} | {c['before']['phases'][phase]['final_ms_median']:.1f} ms | {c['after']['phases'][phase]['final_ms_median']:.1f} ms |")
