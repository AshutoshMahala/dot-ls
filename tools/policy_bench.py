#!/usr/bin/env python3
"""Before/after server-only policy costs. Pre-encoded requests; fresh processes.
5, 20, 40 MB gates; plain DOT and repeated HTML labels; 0/1/1000 findings.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import server_compare as bench

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('label',choices=['before','after'])
p.add_argument('binary',type=Path)
p.add_argument('--trials',type=int,default=3)
a=p.parse_args()
out=bench.PROJECT/'bench/results/parser-policy';out.mkdir(parents=True,exist_ok=True)
bench.SERVERS['dot-ls']=[str(a.binary.resolve()),'lsp']
rows=[]
for mb in [5,20,40]:
    for kind in ['plain','html']:
        source,positions,meta=bench.fixture(kind,mb)
        # Distinct fixtures preserve file size for operator changes. Duplicate
        # attributes add 10 bytes per selected statement (reported below).
        operators=[m.start() for m in re.finditer(rb' -> ',source)]
        def bad(count):
            data=bytearray(source)
            for i in range(count):
                at=operators[(i+1)*len(operators)//(count+1)]+1
                data[at:at+2]=b'--'
            return bytes(data)
        duplicate=source.replace(b'[color="blue"]',b'[color=red color="blue"]',1000) if kind=='html' else source.replace(b'[label="',b'[label=x label="',1000)
        variants=[('clean',source,0),('operator-1',bad(1),1),('repair',source,0),('operator-1000',bad(1000),1000),('duplicates-1000',duplicate,1000),('clean-final',source,0)]
        payloads=[(phase,bench.message(text.decode(),v),expected,len(text)) for v,(phase,text,expected) in enumerate(variants,1)]
        for trial in range(1,a.trials+1):
            row={'kind':kind,'mb':mb,'trial':trial,'source_sha256':meta['sha256'],'phases':[]};client=None;ok=False
            try:
                client=bench.Client('dot-ls');row['startup_ms']=client.startup_ms;row['idle']=client.quiet()
                for version,(phase,data,expected,size) in enumerate(payloads,1):
                    result=client.measure(data,version,kind,phase,expected if a.label=='after' and phase.startswith('operator') else 0)
                    ds=result['notifications'][-1]
                    assert ds['diagnostics']==(expected if a.label=='after' else 0)+(1 if a.label=='after' and expected==1000 else 0),(phase,ds)
                    assert ds['errors']==(expected if a.label=='after' and phase.startswith('operator') else 0),(phase,ds)
                    assert ds['incomplete']==(a.label=='after' and expected==1000),(phase,ds)
                    result['source_bytes']=size;row['phases'].append(result)
                ok=True
            finally:
                if client is not None:row['resources']=client.close(ok)
            assert ok and row['resources']['exit_code']==0,row
            rows.append(row)
            (out/f'{a.label}.json').write_text(json.dumps({'binary':str(a.binary.resolve()),'sha256':hashlib.sha256(a.binary.read_bytes()).hexdigest(),'runs':rows},indent=2)+'\n')
            print(a.label,mb,kind,trial,'clean ms',round(row['phases'][-1]['final_diagnostics_ms'],2),'peak MB',round(row['resources']['actual_peak_rss_bytes']/1e6,2),flush=True)
