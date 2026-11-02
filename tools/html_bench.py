#!/usr/bin/env python3
"""Delayed-label latency and actual server RSS, with repeatable edit fixtures."""
import hashlib,json,pathlib,queue,re,statistics,subprocess,sys,threading,time
root=pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0,str(root/'tests'))
from lsp import Client

def fixtures(mb):
    original=(root/f'examples/editor-{mb}mb.dot').read_text()
    header='digraph editor_test {\n'
    labels=''.join('    html%d [label=<<B>key%04d '%(n,n)+('text '*795)+('</I>' if n==999 else '</B>')+'>];\n' for n in range(1000))
    body=original.split('digraph editor_test {\n',1)[1].rsplit('}',1)[0]
    remaining=mb*1000000-len(header)-len(labels)-2
    body=body[:remaining];body=body[:body.rfind('\n')+1]
    base=header+labels+body+'}\n'
    outer=base.replace('editor_test','editor_edit',1)
    inner=outer.replace('key0000','new0000',1)
    shifted=inner.replace(header.replace('editor_test','editor_edit'),header.replace('editor_test','editor_edit')+'\n',1)
    return [('initial',base),('outer_only',outer),('one_html_edit',inner),('outer_newline',shifted)]

if len(sys.argv)>1 and sys.argv[1]=='fixtures':
    destination=pathlib.Path(sys.argv[2]);destination.mkdir(parents=True,exist_ok=True)
    for mb in (5,40):
        for label,text in fixtures(mb):(destination/f'{mb}-{label}.dot').write_text(text)
    sys.exit()
label,binary=sys.argv[1],str(pathlib.Path(sys.argv[2]).resolve())
runs=[]
for mb in (5,40):
    sources=fixtures(mb);payloads=[]
    for version,(kind,text) in enumerate(sources,1):
        doc={'uri':'untitled:html-bench','version':version}
        if version==1:doc.update(languageId='dot',text=text);method='textDocument/didOpen';params={'textDocument':doc}
        else:method='textDocument/didChange';params={'textDocument':doc,'contentChanges':[{'text':text}]}
        payloads.append(json.dumps({'jsonrpc':'2.0','method':method,'params':params}).encode())
    c=Client.__new__(Client);c.start=time.perf_counter();c.q=queue.Queue()
    c.p=subprocess.Popen(['/usr/bin/time','-l',binary,'lsp'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    threading.Thread(target=c.read,daemon=True).start();c.init()
    pid=subprocess.check_output(['pgrep','-P',str(c.p.pid)]).split()[0].decode()
    rss=lambda:int(subprocess.check_output(['ps','-o','rss=','-p',pid]).strip())*1024
    idle=rss();samples=[]
    for version,((kind,text),payload) in enumerate(zip(sources,payloads),1):
        start=time.perf_counter_ns();c.raw(payload);assert c.diag(version)==[]
        dot_ms=(time.perf_counter_ns()-start)/1e6
        merged_ms=None
        if label=='after':
            d=c.diag(version);assert d and all(x['message'].startswith('HTML label:') for x in d),d
            merged_ms=(time.perf_counter_ns()-start)/1e6
        c.send('textDocument/references',{'textDocument':{'uri':'untitled:html-bench'},'position':{'line':0,'character':0},'context':{'includeDeclaration':True}},50)
        assert c.get()['result']==[]
        samples.append({'edit':kind,'dot_ms':dot_ms,'merged_ms':merged_ms,'settled_rss_bytes':rss(),'source_bytes':len(text.encode())})
    c.send('textDocument/didClose',{'textDocument':{'uri':'untitled:html-bench'}});assert c.diag()==[];closed=rss()
    c.send('shutdown',id=90);assert c.get().get('id')==90;c.send('exit');c.p.stdin.close();assert c.p.wait(timeout=10)==0
    output=c.p.stderr.read().decode();peak=int(re.search(r'(\d+)\s+maximum resident set size',output)[1])
    runs.append({'mb':mb,'idle_rss_bytes':idle,'closed_rss_bytes':closed,'peak_rss_bytes':peak,'samples':samples,'time_output':output})
    print(mb,samples,'peak',peak,flush=True)
report={'label':label,'binary_bytes':pathlib.Path(binary).stat().st_size,'binary_sha256':hashlib.sha256(pathlib.Path(binary).read_bytes()).hexdigest(),'runs':runs,'notes':'Zig 0.16 ReleaseSafe, page allocator, buffered JSON. Pre-encoded edits. 1,000 distinct HTML labels with about 4 MB total HTML; last has a mismatched closer. Original example edges fill remaining size. Four successive versions per fresh process. The old binary does not check HTML, so only its DOT stage is compared. New merged time includes HTML checks/reuse and diagnostic mapping; completion context and references follow. Server RSS only; Zed remains open. No simultaneous builds or benchmarks.'}
(root/f'bench/results/legacy/html-{label}.json').write_text(json.dumps(report,indent=2)+'\n')
