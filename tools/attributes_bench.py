#!/usr/bin/env python3
"""Compare attribute help costs with isolated server processes (macOS)."""
import argparse
import hashlib
import json
from pathlib import Path
import time
import server_compare as b

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('before',type=Path);p.add_argument('after',type=Path)
p.add_argument('--trials',type=int,default=3);p.add_argument('--sizes',type=int,nargs='+',default=[5,20,40])
p.add_argument('--output',type=Path,default=b.PROJECT/'bench/results/attributes')
p.add_argument('--both-have-attributes',action='store_true')
p.add_argument('--errors',type=int,default=1,help='Syntax errors in the broken edit (default: 1)')
p.add_argument('--hover-format',choices=['markdown','plaintext'],help='Advertise a preferred hover format; older servers may still return plaintext')
a=p.parse_args()
if a.errors < 1:p.error('--errors must be positive')
if a.hover_format:
    init=json.loads(b.INIT.split(b'\r\n\r\n',1)[1])
    init['params']['capabilities']['textDocument']['hover']={'contentFormat':[a.hover_format]}
    b.INIT=b.packet('initialize',init['params'],1)
out=a.output;out.mkdir(parents=True,exist_ok=True)
b.FIXTURES=Path('/private/tmp/dot-ls-attribute-fixtures')
rows=[]
for mb in sorted(a.sizes):
    for kind in ['plain','html']:
        source,positions,meta=b.fixture(kind,mb)
        lines=source[:2048].decode().splitlines();line=next(i for i,s in enumerate(lines) if 'label=' in s)
        completion={'line':line,'character':lines[line].index('label=')}
        hover={'line':line,'character':lines[line].index('label=')+2}
        snapshots=[source,b.damage(source,positions,a.errors).encode(),source]
        packets=[b.message(s.decode(),v) for v,s in enumerate(snapshots,1)]
        for trial in range(a.trials):
            for label in (['before','after'] if trial%2==0 else ['after','before']):
                binary=getattr(a,label).resolve();b.SERVERS['dot-ls']=[str(binary),'lsp'];c=b.Client('dot-ls');ok=False
                row={'mb':mb,'kind':kind,'label':label,'trial':trial,'errors_in_broken_edit':a.errors,'fixture':meta,'startup_ms':c.startup_ms,'idle':c.quiet(),'phases':[]}
                try:
                    for version,data in enumerate(packets,1):
                        start=time.perf_counter();c.raw(data);ds=[];counts=[];wire_sizes=[]
                        for _ in range(2 if kind=='html' else 1):
                            while True:
                                arrived,message,wire_size=c.receive()
                                if message.get('method')=='textDocument/publishDiagnostics':break
                            assert message['params']['version']==version,message
                            ds.append((arrived-start)*1000);counts.append(len(message['params']['diagnostics']));wire_sizes.append(wire_size)
                        c.raw(b.packet('textDocument/completion',{'textDocument':{'uri':b.URI},'position':completion},100+version))
                        arrived,reply,_=c.receive();assert reply.get('id')==100+version,reply
                        count=len(reply['result']['items']);assert (count>0)==(label=='after' or a.both_have_attributes),reply
                        ready=(arrived-start)*1000
                        t=time.perf_counter();c.raw(b.packet('textDocument/hover',{'textDocument':{'uri':b.URI},'position':hover},200+version))
                        arrived,reply,hover_wire_bytes=c.receive();assert reply.get('id')==200+version,reply
                        if label=='after' or a.both_have_attributes:assert 'Default:' in reply['result']['contents']['value'],reply
                        else:assert reply['error']['code']==-32601,reply
                        quiet=c.quiet()
                        row['phases'].append({'version':version,'diagnostic_counts':counts,'diagnostic_wire_bytes':wire_sizes,'first_diagnostics_ms':ds[0],'final_diagnostics_ms':ds[-1],'completion_ready_ms':ready,'completion_items':count,'hover_ms':(arrived-t)*1000,'hover_wire_bytes':hover_wire_bytes,'hover_kind':reply.get('result',{}).get('contents',{}).get('kind'),'settled':quiet})
                    ok=True
                finally:row['resources']=c.close(ok)
                assert ok and row['resources']['exit_code']==0 and not row['resources']['safety_stop'],row
                rows.append(row);(out/'comparison.json').write_text(json.dumps({'builds':{n:{'binary':str(getattr(a,n).resolve()),'sha256':hashlib.sha256(getattr(a,n).read_bytes()).hexdigest()} for n in ['before','after']},'runs':rows},indent=2)+'\n')
                print(mb,kind,label,trial,'diagnostics',round(row['phases'][0]['final_diagnostics_ms'],1),'ready',round(row['phases'][0]['completion_ready_ms'],1),'settledMB',round(row['phases'][-1]['settled']['rss_bytes']/1e6,2),flush=True)
