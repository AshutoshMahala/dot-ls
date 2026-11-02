#!/usr/bin/env python3
"""Summarize saved outline before/after runs. Does not launch servers."""
import json,statistics as s
from pathlib import Path
root=Path(__file__).resolve().parents[1]/'bench/results/outline'
data={k:json.loads((root/f'{k}.json').read_text()) for k in ['before','after']}
summary={'builds':{},'cases':[]}
for label,d in data.items():
    assert len(d['runs'])==18
    summary['builds'][label]={'sha256':d['sha256'],'startup_ms_median':s.median(r['startup_ms'] for r in d['runs']),'idle_rss_bytes_median':s.median(r['idle']['rss_bytes'] for r in d['runs'])}
for mb in [5,20,40]:
    for kind in ['plain','html']:
        case={'mb':mb,'kind':kind}
        for label,d in data.items():
            runs=[r for r in d['runs'] if r['mb']==mb and r['kind']==kind]
            assert len(runs)==3 and all(r['resources']['exit_code']==0 and not r['resources']['safety_stop'] for r in runs)
            case[label]={'peak_rss_bytes_max':max(r['resources']['actual_peak_rss_bytes'] for r in runs),'phases':{}}
            for phase in ['open','broken','repair']:
                ps=[p for r in runs for p in r['phases'] if p['phase']==phase]
                qs=[q for r in runs for q in r['outline'] if q['phase']==phase]
                case[label]['phases'][phase]={'first_ms_median':s.median(p['first_diagnostics_ms'] for p in ps),'final_ms_median':s.median(p['final_diagnostics_ms'] for p in ps),'settled_rss_bytes_median':s.median(p['settled_rss_bytes'] for p in ps),'query_ms_median':s.median(q['request_ms'] for q in qs),'response_bytes':qs[0]['response_bytes'],'symbols':qs[0]['symbols']}
        summary['cases'].append(case)
(root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print('| Size | Layout | Diagnostics before → after | Peak RSS before → after | Retained RSS before → after | Outline request |')
print('| --- | --- | ---: | ---: | ---: | ---: |')
for c in summary['cases']:
 b,a=c['before'],c['after'];bp,ap=b['phases']['open'],a['phases']['open']
 print(f"| {c['mb']} MB | {c['kind']} | {bp['final_ms_median']:.1f} → {ap['final_ms_median']:.1f} ms | {b['peak_rss_bytes_max']/1e6:.2f} → {a['peak_rss_bytes_max']/1e6:.2f} MB | {bp['settled_rss_bytes_median']/1e6:.2f} → {ap['settled_rss_bytes_median']/1e6:.2f} MB | {ap['query_ms_median']:.1f} ms |")
print(json.dumps(summary['builds'],indent=2))
