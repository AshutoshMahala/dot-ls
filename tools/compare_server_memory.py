#!/usr/bin/env python3
"""Separate high-water RSS check for the same open/error/repair sequence."""
import json, pathlib, queue, re, subprocess, sys, threading, time
root=pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0,str(root/'tests'))
from lsp import Client
runs=[]
for mb in (5,20):
    text=(root/f'examples/editor-{mb}mb.dot').read_text()
    broken=text[:-2]+'@'+text[-2:]
    for name,cmd in [('dotls',[str(root/'zig-out/bin/dotls'),'lsp']),('graphviz',['/opt/homebrew/bin/dot-language-server','--stdio'])]:
        c=Client.__new__(Client);c.start=time.perf_counter()
        c.p=subprocess.Popen(['/usr/bin/time','-l',*cmd],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        c.q=queue.Queue();threading.Thread(target=c.read,daemon=True).start()
        c.init();samples=[]
        for version,source in enumerate((text,broken,text),1):
            start=time.perf_counter_ns()
            if version==1:c.send('textDocument/didOpen',{'textDocument':{'uri':'untitled:compare','languageId':'dot','version':version,'text':source}})
            else:c.change(source,version,'untitled:compare')
            while True:
                reply=c.get()
                if reply.get('method')=='textDocument/publishDiagnostics':break
                if 'id' in reply and 'method' in reply:c.raw(json.dumps({'jsonrpc':'2.0','id':reply['id'],'result':None}).encode())
            assert bool(reply['params']['diagnostics'])==(version==2),reply
            samples.append((time.perf_counter_ns()-start)/1e6)
            time.sleep(.1)
        c.send('shutdown',id=90)
        while c.get().get('id')!=90:pass
        c.send('exit');c.p.stdin.close();assert c.p.wait(timeout=10)==0
        stderr=c.p.stderr.read().decode();match=re.search(r'(\d+)\s+maximum resident set size',stderr);assert match,stderr
        runs.append({'server':name,'mb':mb,'source_bytes':len(text.encode()),'peak_rss_bytes':int(match[1]),'request_ms_including_python_encoding':samples,'time_output':stderr})
        print(name,mb,int(match[1]),flush=True)
(root/'bench/results/zed-comparison/high-water-memory.json').write_text(json.dumps({'runs':runs,'notes':'Separate stdio client, not Zed. Fresh process per case. macOS time -l measures actual maximum resident size across open, EOF syntax error, repair and shutdown. No RSS polling or relay. Timing here includes Python encoding; use Zed relay traces for editor LSP notification-to-diagnostic latency.'},indent=2)+'\n')
