#!/usr/bin/env python3
"""Run temporary profiled server. Modes: timing, memory."""
import pathlib,sys,os,json,time,threading,subprocess,statistics
project=pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0,str(project/'tests'))
from lsp import Client
mode=sys.argv[2] if len(sys.argv)>2 else 'timing'
c=Client(); events=[]; samples=[]
lock=threading.Lock()
def read_events():
    for line in c.p.stderr:
        try:
            event=json.loads(line)
            if mode=='memory' and event['stage'] in ('body_read','json_decode','snapshot_copy','parser','json_cleanup','input_cleanup','job_cleanup','positions_ready'):
                # Memory-mode build pauses after these trace points.
                rss=int(subprocess.check_output(['ps','-o','rss=','-p',str(c.p.pid)]).strip())*1024
                event['rss_bytes']=rss
            with lock: events.append(event)
        except Exception as e: print('trace error',e,file=sys.stderr)
t=threading.Thread(target=read_events);t.start()
c.init();time.sleep(.05)
if mode=='memory':
    out=project/'docs'/('profile-'+os.environ.get('DOTLS_PROFILE_LABEL','')+'idle-vmmap.txt')
    out.write_bytes(subprocess.check_output(['vmmap','-summary',str(c.p.pid)],stderr=subprocess.STDOUT))
    idle_rss=int(subprocess.check_output(['ps','-o','rss=','-p',str(c.p.pid)]).strip())*1024
else:idle_rss=None
size=40_000_000
text='digraph {\n'+('a -> b;\n'*((size-12)//8))+'}\n'
if os.environ.get('DOTLS_PROFILE_ERRORS') == '1':
    text = text[:-2] + '@}\n'
for v in range(1,6 if mode=='timing' else 2):
    start=time.perf_counter_ns()
    method='textDocument/didOpen' if v==1 else 'textDocument/didChange'
    params={'textDocument':{'uri':'untitled:test','version':v},'contentChanges':[{'text':text}]}
    if v==1:params={'textDocument':{'uri':'untitled:test','version':v,'text':text,'languageId':'dot'}}
    payload=json.dumps({'jsonrpc':'2.0','method':method,'params':params},ensure_ascii=False).encode()
    encoded=time.perf_counter_ns();c.raw(payload);written=time.perf_counter_ns();diagnostics=c.diag(v);assert bool(diagnostics)==(os.environ.get('DOTLS_PROFILE_ERRORS')=='1');done=time.perf_counter_ns()
    samples.append({'encode_ms':(encoded-start)/1e6,'write_ms':(written-encoded)/1e6,'after_write_ms':(done-written)/1e6,'total_ms':(done-start)/1e6})
    del payload
    time.sleep(.03)
c.stop();t.join()
# Select events for the large requests, rather than lifecycle messages.
stages={}
for event in events:
    cat={v['name']:v for v in event['categories']}
    if cat['input']['live']>40_000_000 or cat['snapshot']['live']>30_000_000:
        stages.setdefault(event['stage'],[]).append(event['us']/1000)
report={'mode':mode,'source_bytes':len(text.encode()),'idle_rss_bytes':idle_rss,'client_runs':samples,'stage_ms':{k:{'median':statistics.median(v),'samples':v} for k,v in stages.items()},'events':events}
path=project/'docs'/('profile-'+os.environ.get('DOTLS_PROFILE_LABEL','')+mode+'.json');path.write_text(json.dumps(report,indent=2))
print(json.dumps({k:v for k,v in report.items() if k!='events'},indent=2))
