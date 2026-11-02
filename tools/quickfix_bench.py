#!/usr/bin/env python3
"""Server-only quick-fix cost: clean files, 1/1000 fixes and request turnaround.
Run before and after separately, without concurrent builds or editor activity.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import time
import server_compare as bench

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('label',choices=['before','after'])
p.add_argument('binary',type=Path)
p.add_argument('--trials',type=int,default=3)
a=p.parse_args()
out=bench.PROJECT/'bench/results/quick-fixes';out.mkdir(parents=True,exist_ok=True)
bench.SERVERS['dot-ls']=[str(a.binary.resolve()),'lsp']
bench.INIT=bench.packet('initialize',{'processId':None,'capabilities':{
    'general':{'positionEncodings':['utf-16']},'workspace':{'workspaceEdit':{'documentChanges':True}},
    'textDocument':{'publishDiagnostics':{'relatedInformation':True,'dataSupport':True}}}},1)
rows=[]
for mb in [5,20,40]:
    for kind in ['plain','html']:
        source,_,meta=bench.fixture(kind,mb)
        operators=[m.start()+1 for m in re.finditer(rb' -> ',source)]
        def bad(count):
            data=bytearray(source)
            for i in range(count):
                at=operators[(i+1)*len(operators)//(count+1)]
                data[at:at+2]=b'--'
            return bytes(data)
        variants=[('open',source,0),('operator-1',bad(1),1),('repair',source,0),('operator-1000',bad(1000),1000),('clean-final',source,0)]
        payloads=[(phase,bench.message(text.decode(),v),expected) for v,(phase,text,expected) in enumerate(variants,1)]
        queries={v:bench.packet('textDocument/codeAction',{'textDocument':{'uri':bench.URI},
            'range':{'start':{'line':0,'character':0},'end':{'line':2147483647,'character':0}},
            'context':{'diagnostics':[],'only':['quickfix']}},90+v) for v,(_,_,expected) in enumerate(payloads,1) if expected}
        for trial in range(1,a.trials+1):
            row={'kind':kind,'mb':mb,'trial':trial,'source_sha256':meta['sha256'],'phases':[],'actions':[]};client=None;ok=False
            try:
                client=bench.Client('dot-ls');row['startup_ms']=client.startup_ms;row['idle']=client.quiet()
                for version,(phase,data,expected) in enumerate(payloads,1):
                    result=client.measure(data,version,kind,phase,expected)
                    ds=result['notifications'][-1]
                    assert ds['errors']==expected,(phase,ds)
                    assert ds['incomplete']==(expected==1000),(phase,ds)
                    row['phases'].append(result)
                    if expected:
                        start=time.perf_counter();client.raw(queries[version]);arrived,reply,size=client.receive()
                        assert reply['id']==90+version,reply
                        if a.label=='after':
                            assert len(reply['result'])==expected,(phase,len(reply['result']))
                            for action in reply['result']:
                                change=action['edit']['documentChanges'][0]
                                assert change['textDocument']=={'uri':bench.URI,'version':version},change
                                assert len(change['edits'])==1 and change['edits'][0]['newText']=='->',change
                        else:assert reply['error']['code']==-32601,reply
                        quiet=client.quiet()
                        row['actions'].append({'phase':phase,'count':expected if a.label=='after' else 0,
                            'request_ms':(arrived-start)*1000,'response_bytes':size,'settled_rss_bytes':quiet['rss_bytes']})
                ok=True
            finally:
                if client is not None:row['resources']=client.close(ok)
            assert ok and row['resources']['exit_code']==0 and not row['resources']['safety_stop'],row
            rows.append(row)
            (out/f'{a.label}.json').write_text(json.dumps({'binary':str(a.binary.resolve()),'sha256':hashlib.sha256(a.binary.read_bytes()).hexdigest(),'runs':rows},indent=2)+'\n')
            print(a.label,mb,kind,trial,'open ms',round(row['phases'][0]['final_diagnostics_ms'],2),'peak MB',round(row['resources']['actual_peak_rss_bytes']/1e6,2),flush=True)
