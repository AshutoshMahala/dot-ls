#!/usr/bin/env python3
"""Repeatable feature-increment latency and actual peak-RSS measurements."""
import json,pathlib,queue,re,statistics,subprocess,sys,threading,time
root=pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0,str(root/'tests'))
from lsp import Client
label,binary=sys.argv[1],str(pathlib.Path(sys.argv[2]).resolve())
runs=[]
for mb in (5,20,40):
    text=(root/f'examples/editor-{mb}mb.dot').read_text();broken=text[:-2]+'@'+text[-2:]
    header_line=next(i for i,line in enumerate(text[:4096].splitlines()) if line.startswith('digraph '))
    requests=[]
    for v,source in enumerate((text,broken,text,broken,text,broken,text),1):
        doc={'uri':'untitled:feature-bench','version':v}
        if v==1:doc.update(languageId='dot',text=source);method='textDocument/didOpen';params={'textDocument':doc}
        else:method='textDocument/didChange';params={'textDocument':doc,'contentChanges':[{'text':source}]}
        requests.append(json.dumps({'jsonrpc':'2.0','method':method,'params':params}).encode())
    c=Client.__new__(Client);c.start=time.perf_counter();c.q=queue.Queue()
    c.p=subprocess.Popen(['/usr/bin/time','-l',binary,'lsp'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    threading.Thread(target=c.read,daemon=True).start()
    c.init();startup=(time.perf_counter()-c.start)*1000
    # The child of time is the server. Capture idle RSS before any large request.
    children=subprocess.check_output(['pgrep','-P',str(c.p.pid)]).split();assert len(children)==1,children
    idle=int(subprocess.check_output(['ps','-o','rss=','-p',children[0].decode()]).strip())*1024
    samples=[]
    for v,payload in enumerate(requests,1):
        start=time.perf_counter_ns();c.raw(payload);d=c.diag(v);elapsed=(time.perf_counter_ns()-start)/1e6
        assert bool(d)==(v%2==0),d[:2]
        samples.append({'phase':'open' if v==1 else 'error' if v%2==0 else 'repair','ms':elapsed})
    completion=[]
    if label!='before':
        for n in range(20):
            start=time.perf_counter_ns();c.send('textDocument/completion',{'textDocument':{'uri':'untitled:feature-bench'},'position':{'line':header_line,'character':0}},100+n)
            reply=c.get();assert len(reply['result']['items']) in (3,6),reply
            completion.append((time.perf_counter_ns()-start)/1e6)
    c.send('shutdown',id=90)
    while c.get().get('id')!=90:pass
    c.send('exit');c.p.stdin.close();assert c.p.wait(timeout=10)==0
    output=c.p.stderr.read().decode();match=re.search(r'(\d+)\s+maximum resident set size',output);assert match,output
    runs.append({'mb':mb,'source_bytes':len(text.encode()),'startup_ms':startup,'idle_rss_bytes':idle,'peak_rss_bytes':int(match[1]),'samples':samples,'completion_ms':completion,'time_output':output})
report={'label':label,'binary_bytes':pathlib.Path(binary).stat().st_size,'runs':runs,'notes':'Zig 0.16 ReleaseSafe. Pre-encoded full-sync request through diagnostics. Single fresh process per size, three error/repair pairs. Actual macOS time -l peak RSS; idle ps sample before requests. Completion includes small Python encoding. No editor, builds or background benchmarking during runs.'}
(root/f'bench/results/legacy/features-{label}.json').write_text(json.dumps(report,indent=2)+'\n')
for r in runs:print(r['mb'],{p:statistics.median(s['ms'] for s in r['samples'] if s['phase']==p) for p in ('open','error','repair')},'peak',r['peak_rss_bytes'])
