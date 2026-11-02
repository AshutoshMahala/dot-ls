#!/usr/bin/env python3
"""Large full-sync benchmark. Reports client overhead separately."""
import json, os, sys, time, subprocess, statistics
sys.path.insert(0, os.path.dirname(__file__))
from lsp import Client

def memory(p):
    values=subprocess.check_output(['ps','-o','rss=,vsz=','-p',str(p.pid)]).decode().split()
    return {'rss_bytes':int(values[0])*1024,'virtual_bytes':int(values[1])*1024}

c=Client(); time.sleep(.05); before=memory(c.p); c.init(); initialized=memory(c.p)
size=int(os.environ.get("DOTLS_BENCH_BYTES", "40000000"))
prefix='digraph {\n'; suffix='}\n'; body='a -> b;\n'
text=prefix+body*((size-len(prefix)-len(suffix))//len(body))+suffix
measurements=[]
for v in range(1,4):
    params={'textDocument':{'uri':'untitled:test','version':v},'contentChanges':[{'text':text}]}
    method='textDocument/didChange'
    if v==1:
        method='textDocument/didOpen';params={'textDocument':{'uri':'untitled:test','languageId':'dot','version':v,'text':text}}
    start=time.perf_counter()
    payload=json.dumps({'jsonrpc':'2.0','method':method,'params':params},ensure_ascii=False).encode()
    serialized=time.perf_counter()
    c.raw(payload); written=time.perf_counter()
    diagnostics=c.diag(v); received=time.perf_counter()
    assert diagnostics==[],diagnostics
    measurements.append({'serialization_ms':(serialized-start)*1000,'write_ms':(written-serialized)*1000,'after_write_ms':(received-written)*1000,'total_ms':(received-start)*1000,'wire_bytes':len(payload)})
    del payload
active=memory(c.p)
c.send('textDocument/didClose',{'textDocument':{'uri':'untitled:test'}});c.diag();time.sleep(.05);closed=memory(c.p);c.stop()
print(json.dumps({'source_bytes':len(text.encode()),'runs':measurements,'before_initialize':before,'after_initialize':initialized,'after_large_analysis':active,'after_close':closed,'build_note':os.environ.get('DOTLS_BENCH_NOTE','Normal checkpoint limits: 200 MiB source, 256 MiB framed message.')},indent=2))
