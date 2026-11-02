#!/usr/bin/env python3
"""Capture instrumented stderr through a pipe; keep tracing out of production."""
import json, pathlib, statistics, subprocess, sys
root=pathlib.Path(__file__).resolve().parent.parent
binary,label,source=sys.argv[1:4]
result=subprocess.run([binary,str(pathlib.Path(source).resolve())],stderr=subprocess.PIPE,check=True)
rows=[json.loads(s) for s in result.stderr.splitlines()]
report={'label':label,'source_bytes':pathlib.Path(source).stat().st_size,
 'notes':'Temporary instrumented parser/index-only build. Five samples. Requested allocator bytes, not RSS. No protocol/JSON intake. Categories show live bytes and cumulative peaks; independent peaks must not be summed.',
 'median_ms':{stage:statistics.median(r['us']/1000 for r in rows if r['stage']==stage) for stage in dict.fromkeys(r['stage'] for r in rows)},'events':rows}
(root/f'docs/index-profile-{label}.json').write_text(json.dumps(report,indent=2)+'\n')
print(label,report['median_ms'])
