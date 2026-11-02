#!/usr/bin/env python3
"""Stress capped diagnostic presentation, and measure direct warm startup."""
import json,pathlib,queue,re,statistics,subprocess,sys,threading,time
root=pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0,str(root/'tests'))
import lsp
variants=[('before',str(pathlib.Path(sys.argv[1]).resolve())),('after',str(pathlib.Path(sys.argv[2]).resolve()))]
runs=[]
text='digraph {\n'+'a -> ;\n'*1200+'}\n'
for label,binary in variants:
    lsp.BIN=binary;startup=[]
    for _ in range(15):
        c=lsp.Client();c.init();startup.append((time.perf_counter()-c.start)*1000);c.stop()
    c=lsp.Client.__new__(lsp.Client);c.start=time.perf_counter();c.q=queue.Queue()
    c.p=subprocess.Popen(['/usr/bin/time','-l',binary,'lsp'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    threading.Thread(target=c.read,daemon=True).start();c.init();samples=[];count=0
    for v in range(1,6):
        doc={'uri':'untitled:many-errors','version':v}
        if v==1:doc.update(languageId='dot',text=text);method='textDocument/didOpen';params={'textDocument':doc}
        else:method='textDocument/didChange';params={'textDocument':doc,'contentChanges':[{'text':text}]}
        payload=json.dumps({'jsonrpc':'2.0','method':method,'params':params}).encode()
        start=time.perf_counter_ns();c.raw(payload);d=c.diag(v);samples.append((time.perf_counter_ns()-start)/1e6)
        assert len(d)==1001,len(d);count=len(d)
    c.send('shutdown',id=90)
    while c.get().get('id')!=90:pass
    c.send('exit');c.p.stdin.close();assert c.p.wait(timeout=10)==0
    output=c.p.stderr.read().decode();match=re.search(r'(\d+)\s+maximum resident set size',output);assert match,output
    runs.append({'label':label,'source_bytes':len(text.encode()),'diagnostics':count,'request_ms':samples,'median_ms':statistics.median(samples),'warm_startup_ms':startup,'median_warm_startup_ms':statistics.median(startup),'peak_rss_bytes':int(match[1]),'time_output':output})
(root/'bench/results/legacy/features-diagnostic-load.json').write_text(json.dumps({'runs':runs,'notes':'Separate capped-diagnostic workload and 15 direct warm starts per binary. Timing excludes client encoding. Actual macOS time -l peak across five versions.'},indent=2)+'\n')
print(json.dumps([{k:v for k,v in r.items() if k not in ('time_output','warm_startup_ms')} for r in runs],indent=2))
