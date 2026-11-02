#!/usr/bin/env python3
"""Compare built allocator variants sequentially. No benchmarks during builds."""
import pathlib, sys, json, time, statistics, threading, queue, subprocess, os
project=pathlib.Path(__file__).resolve().parent.parent
class Client:
    def __init__(self,binary):
        self.start=time.perf_counter_ns()
        self.p=subprocess.Popen([str(binary),'lsp'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.q=queue.Queue()
        threading.Thread(target=self.read,daemon=True).start()
    def read(self):
        while True:
            headers={}
            while True:
                line=self.p.stdout.readline()
                if not line:return
                if line==b'\r\n':break
                k,v=line.decode().split(':',1);headers[k.lower()]=v.strip()
            self.q.put(json.loads(self.p.stdout.read(int(headers['content-length']))))
    def raw(self,payload):
        self.p.stdin.write(b'Content-Length: '+str(len(payload)).encode()+b'\r\n\r\n'+payload);self.p.stdin.flush()
    def send(self,method,params=None,id=None):
        value={'jsonrpc':'2.0','method':method}
        if params is not None:value['params']=params
        if id is not None:value['id']=id
        self.raw(json.dumps(value).encode())
    def get(self):return self.q.get(timeout=30)
    def init(self):
        self.send('initialize',{'capabilities':{}},1);assert self.get().get('id')==1
        startup=(time.perf_counter_ns()-self.start)/1e6;self.send('initialized',{});return startup
    def stop(self):
        self.send('shutdown',id=90)
        while self.get().get('id')!=90:pass
        self.send('exit');self.p.stdin.close();assert self.p.wait(timeout=10)==0
        stderr=self.p.stderr.read();assert not stderr,stderr.decode()
def rss(pid):return int(subprocess.check_output(['ps','-o','rss=','-p',str(pid)]).strip())*1024
text='digraph {\n'+'a -> b;\n'*4_999_998+'}\n'
# Prepare payloads before server timing so every allocator sees identical bytes.
payloads=[]
for version in range(1,5):
    if version==1:method='textDocument/didOpen';params={'textDocument':{'uri':'untitled:test','version':version,'languageId':'dot','text':text}}
    else:method='textDocument/didChange';params={'textDocument':{'uri':'untitled:test','version':version},'contentChanges':[{'text':text}]}
    payloads.append(json.dumps({'jsonrpc':'2.0','method':method,'params':params}).encode())
variants=[(a,j,pathlib.Path('/private/tmp')/('dotls-allocator-'+a+'-'+j)/'bin/dotls') for a in ('page','smp','debug') for j in ('arena','buffer')]
results=[]
# Two passes in opposite orders reduce order/temperature bias.
for repeat in range(2):
    for allocator,json_mode,binary in (variants if repeat==0 else reversed(variants)):
        c=Client(binary);startup=c.init();samples=[]
        for version,payload in enumerate(payloads,1):
            start=time.perf_counter_ns();c.raw(payload);reply=c.get();done=time.perf_counter_ns()
            assert reply['params']['version']==version and not reply['params']['diagnostics'],reply
            samples.append((done-start)/1e6)
        c.stop()
        results.append({'repeat':repeat,'allocator':allocator,'json_storage':json_mode,'startup_ms':startup,'request_ms':samples,'binary_bytes':binary.stat().st_size})
# RSS is sampled in a separate pass. It can miss brief peaks.
for allocator,json_mode,binary in variants:
    c=Client(binary);c.init();time.sleep(.03);idle=rss(c.p.pid);observed=[idle];running=threading.Event();running.set()
    def sample():
        while running.is_set():
            try:observed.append(rss(c.p.pid))
            except (ValueError,subprocess.CalledProcessError):pass
            time.sleep(.003)
    t=threading.Thread(target=sample);t.start()
    c.raw(payloads[0]);assert not c.get()['params']['diagnostics']
    running.clear();t.join()
    c.send('textDocument/didClose',{'textDocument':{'uri':'untitled:test'}});assert not c.get()['params']['diagnostics'];time.sleep(.03);closed=rss(c.p.pid);c.stop()
    results.append({'allocator':allocator,'json_storage':json_mode,'idle_rss_bytes':idle,'sampled_peak_rss_bytes':max(observed),'after_close_rss_bytes':closed})
summary=[]
for allocator,json_mode,_ in variants:
    timed=[r for r in results if r['allocator']==allocator and r['json_storage']==json_mode and 'request_ms' in r]
    memory=next(r for r in results if r['allocator']==allocator and r['json_storage']==json_mode and 'idle_rss_bytes' in r)
    times=[v for r in timed for v in r['request_ms']]
    summary.append({'allocator':allocator,'json_storage':json_mode,'median_request_ms':statistics.median(times),'min_request_ms':min(times),'max_request_ms':max(times),'binary_bytes':timed[0]['binary_bytes'],**{k:v for k,v in memory.items() if k.endswith('_bytes')}})
report={'source_bytes':len(text.encode()),'wire_bytes':len(payloads[0]),'summary':summary,'runs':results,'notes':'Latency starts before writing pre-encoded payload. Includes transport, server JSON, copying, metered block syntax analysis and response. RSS sampling is separate and may miss transient peaks.'}
(project/'bench/results/legacy/allocator-comparison.json').write_text(json.dumps(report,indent=2));print(json.dumps(summary,indent=2))
