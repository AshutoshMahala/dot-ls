#!/usr/bin/env python3
"""Before/after outline cost. Fresh processes, 5/20/40 MB, plain and HTML.
Includes clean and broken files, quiet RSS and actual process peak RSS.
"""
import argparse,hashlib,json,time
from pathlib import Path
import server_compare as bench
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('label',choices=['before','after']);p.add_argument('binary',type=Path)
p.add_argument('--trials',type=int,default=3)
a=p.parse_args();out=bench.PROJECT/'bench/results/outline';out.mkdir(parents=True,exist_ok=True)
bench.SERVERS['dot-ls']=[str(a.binary.resolve()),'lsp']
bench.INIT=bench.packet('initialize',{'capabilities':{'general':{'positionEncodings':['utf-16']},'textDocument':{'documentSymbol':{'hierarchicalDocumentSymbolSupport':True},'publishDiagnostics':{'relatedInformation':True}}}},1)
rows=[]
for mb in [5,20,40]:
    for kind in ['plain','html']:
        source,positions,meta=bench.fixture(kind,mb)
        broken=bench.damage(source,positions,1).encode()
        variants=[('open',source,0),('broken',broken,1),('repair',source,0)]
        payloads=[(phase,bench.message(text.decode(),v),errors) for v,(phase,text,errors) in enumerate(variants,1)]
        for trial in range(1,a.trials+1):
            row={'kind':kind,'mb':mb,'trial':trial,'fixture':meta,'phases':[],'outline':[]};client=None;ok=False
            try:
                client=bench.Client('dot-ls');row['startup_ms']=client.startup_ms;row['idle']=client.quiet()
                for version,(phase,data,errors) in enumerate(payloads,1):
                    result=client.measure(data,version,kind,phase,errors);row['phases'].append(result)
                    start=time.perf_counter();client.raw(bench.packet('textDocument/documentSymbol',{'textDocument':{'uri':bench.URI}},90+version))
                    arrived,reply,size=client.receive(45)
                    assert reply['id']==90+version,reply
                    if a.label=='after':
                        symbols=reply['result'];assert len(symbols)==1,symbols[:1]
                        count=1+len(symbols[0].get('children',[]))
                        expected=1+(meta['records'] if kind=='html' else 0)
                        assert count==expected,(phase,count,expected)
                    else:
                        assert reply['error']['code']==-32601,reply
                        count=0
                    quiet=client.quiet()
                    row['outline'].append({'phase':phase,'request_ms':(arrived-start)*1000,'response_bytes':size,'symbols':count,'settled_rss_bytes':quiet['rss_bytes']})
                ok=True
            finally:
                if client is not None:row['resources']=client.close(ok)
            assert ok and row['resources']['exit_code']==0 and not row['resources']['safety_stop'],row
            rows.append(row)
            (out/f'{a.label}.json').write_text(json.dumps({'binary':str(a.binary.resolve()),'sha256':hashlib.sha256(a.binary.read_bytes()).hexdigest(),'runs':rows},indent=2)+'\n')
            print(a.label,mb,kind,trial,'open',round(row['phases'][0]['final_diagnostics_ms'],1),'ms peak',round(row['resources']['actual_peak_rss_bytes']/1e6,2),'MB outline',round(row['outline'][0]['request_ms'],1),'ms',flush=True)
