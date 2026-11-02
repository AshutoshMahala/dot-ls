#!/usr/bin/env python3
"""Build derived tables from the controlled server comparison's raw records."""
import json
from pathlib import Path
import statistics

out = Path(__file__).resolve().parents[1] / 'bench/results/server-comparison-2026-10-15'
raw = [json.loads(line) for line in (out/'runs.jsonl').read_text().splitlines()]
effective = {}
for r in raw: effective[(r['server'],r['kind'],r['mb'],r['case'],r['trial'])] = r
rows = list(effective.values())
summary = {'startup': [], 'main': [], 'errors': [], 'failures': [], 'superseded_raw_records':len(raw)-len(rows)}
for name in ['dot-ls','dot-language-server']:
    startup = [r for r in json.loads((out/'startup.json').read_text()) if r['server']==name]
    summary['startup'].append({'server':name,'runs':len(startup),
        'median_ms':statistics.median(r['startup_ms'] for r in startup),
        'min_ms':min(r['startup_ms'] for r in startup),'max_ms':max(r['startup_ms'] for r in startup),
        'median_idle_rss_bytes':statistics.median(r['idle']['rss_bytes'] for r in startup)})
for mb in [5,20,40]:
    for kind in ['plain','html']:
        for name in ['dot-ls','dot-language-server']:
            group = [r for r in rows if (r['mb'],r['kind'],r['server']) == (mb,kind,name)]
            main = [r for r in group if r['case']=='single-error' and r['passed']]
            if main:
                entry = {'mb':mb,'kind':kind,'server':name,'completed_processes':len(main),
                    'max_actual_peak_rss_bytes':max(r['resources']['actual_peak_rss_bytes'] for r in main),
                    'reported_incomplete':any(p['notifications'][-1]['incomplete'] for r in main for p in r['phases']),
                    'median_open_settled_rss_bytes':statistics.median(r['phases'][0]['settled_rss_bytes'] for r in main)}
                for phase in ['open','error','repair']:
                    points = [p for r in main for p in r['phases'] if p['phase']==phase]
                    entry[phase] = {'n':len(points),'median_final_ms':statistics.median(p['final_diagnostics_ms'] for p in points),
                        'min_final_ms':min(p['final_diagnostics_ms'] for p in points),'max_final_ms':max(p['final_diagnostics_ms'] for p in points),
                        'median_first_ms':statistics.median(p['first_diagnostics_ms'] for p in points),
                        'max_settled_rss_bytes':max(p['settled_rss_bytes'] for p in points)}
                summary['main'].append(entry)
            for r in group:
                if not r['passed']:
                    summary['failures'].append(r);continue
                if r['case'].startswith('errors-'):
                    phases = r['phases']; repeat = [p['final_diagnostics_ms'] for p in phases if p['phase']=='repeat']
                    summary['errors'].append({'mb':mb,'kind':kind,'server':name,
                        'inserted_errors':phases[0]['inserted_errors'],'open_final_ms':phases[0]['final_diagnostics_ms'],
                        'repeat_n':len(repeat),'repeat_median_final_ms':statistics.median(repeat),
                        'returned_errors':phases[-1]['notifications'][-1]['errors'],
                        'returned_diagnostics':phases[-1]['notifications'][-1]['diagnostics'],
                        'incomplete':phases[-1]['notifications'][-1]['incomplete'],
                        'actual_peak_rss_bytes':r['resources']['actual_peak_rss_bytes'],
                        'last_settled_rss_bytes':phases[-1]['settled_rss_bytes']})
(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
for row in summary['main']:
    print(row['mb'],row['kind'],row['server'],
          'open/error/repair ms',*[round(row[p]['median_final_ms'],2) for p in ['open','error','repair']],
          'peak MB',round(row['max_actual_peak_rss_bytes']/1e6,2))
print('Failures/skips:',len(summary['failures']))
