#!/usr/bin/env python3
"""Interleaved label-free before/after control; wait for all background work."""
import json,pathlib,statistics,sys,time
root=pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0,str(root/'tests'))
import lsp
binaries=[str(pathlib.Path(x).resolve()) for x in sys.argv[1:3]]
runs=[]
for mb in (40,100):
    text=(root/f'examples/editor-{mb}mb.dot').read_text();broken=text[:-2]+'@'+text[-2:]
    payloads={kind:json.dumps({'jsonrpc':'2.0','method':'textDocument/didChange','params':{'textDocument':{'uri':'untitled:test','version':2},'contentChanges':[{'text':source}]}}).encode() for kind,source in [('repair',text),('error',broken)]}
    clients=[]
    def ready(c):
        c.send('textDocument/references',{'textDocument':{'uri':'untitled:test'},'position':{'line':0,'character':0},'context':{'includeDeclaration':True}},50)
        r=c.get();assert r.get('id')==50,r
    for binary in binaries:
        lsp.BIN=binary;c=lsp.Client();c.init();c.open(text);c.diag(1);ready(c);clients.append(c)
    rows=[]
    for round in range(5):
        for kind in ('error','repair'):
            for index in ((0,1) if round%2==0 else (1,0)):
                c=clients[index];started=time.perf_counter_ns();c.raw(payloads[kind]);d=c.diag(2)
                elapsed=(time.perf_counter_ns()-started)/1e6;assert bool(d)==(kind=='error'),d
                ready(c) # no other server has work while this one is measured
                rows.append({'round':round,'kind':kind,'variant':'before' if index==0 else 'after','ms':elapsed})
    for c in clients:c.stop()
    runs.append({'mb':mb,'samples':rows})
    print(mb,{(variant,kind):statistics.median(x['ms'] for x in rows if x['variant']==variant and x['kind']==kind) for variant in ('before','after') for kind in ('error','repair')},flush=True)
(root/'bench/results/legacy/html-label-free-interleaved.json').write_text(json.dumps({'binaries':binaries,'runs':runs,'notes':'Five interleaved error/repair pairs per binary and size. Variant order reverses on alternate rounds. One active request at a time; every sample waits for background completion before the other binary is measured. Pre-encoded changes, first diagnostics only. No HTML in fixtures. Separate RSS evidence is in completion-context-html-{before,after}-40-100.json.'},indent=2)+'\n')
