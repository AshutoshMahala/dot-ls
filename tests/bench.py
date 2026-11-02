#!/usr/bin/env python3
"""Local process RSS samples. Sampling is separate from latency tests."""
from lsp import Client, BIN
import subprocess, json, time, threading, statistics, os, platform

def rss(pid):
    return int(subprocess.check_output(['ps','-o','rss=','-p',str(pid)]).strip()) * 1024
c=Client(); c.init(); idle=rss(c.p.pid)
large='digraph {\n'+('a -> b;\n'*550000)+'}\n'
peak=[idle]; running=threading.Event(); running.set()
def sample():
    while running.is_set():
        try: peak.append(rss(c.p.pid))
        except (subprocess.CalledProcessError,ValueError): pass
        time.sleep(.005)
t=threading.Thread(target=sample); t.start()
c.open(large); c.diag(1)
for v in range(2,12): c.change(large,v); c.diag(v)
running.clear(); t.join()
c.send('textDocument/didClose',{'textDocument':{'uri':'untitled:test'}}); c.diag()
time.sleep(.05); closed=rss(c.p.pid); c.stop()
print(json.dumps({'platform':platform.platform(),'binary_bytes':os.path.getsize(BIN),'idle_rss_bytes':idle,'sampled_peak_rss_bytes':max(peak),'rss_after_close_bytes':closed,'document_bytes':len(large.encode()),'note':'RSS sampled through ps; transient peaks may be missed. Full-sync JSON acquisition is included.'},indent=2))
