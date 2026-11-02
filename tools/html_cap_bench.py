#!/usr/bin/env python3
"""Before/after full-label coverage, diagnostic turnaround and server-only RSS.
Uses the same macOS stdio resource client as server_compare.py. No editor.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import statistics
import time
import server_compare as bench

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('label', choices=['before','after'])
p.add_argument('binary', type=Path)
p.add_argument('--trials', type=int, default=3)
p.add_argument('--plain',action='store_true',help='Run the label-free DOT regression control')
p.add_argument('--lifecycle',action='store_true',help='Check close/reopen memory and cancellation on unique 40 MB labels')
a = p.parse_args()
out = bench.PROJECT/'bench/results/html-label-cap'
out.mkdir(parents=True,exist_ok=True)
bench.SERVERS['dot-ls'] = [str(a.binary.resolve()),'lsp']
if a.lifecycle:
    source=(bench.FIXTURES/'cap-unique-40mb.dot').read_text()
    payloads=[bench.packet('textDocument/didOpen',{'textDocument':{'uri':bench.URI,'languageId':'dot','version':v,'text':source}}) for v in [1,2,3]]
    tiny=bench.message('digraph { a [label=<<B>x</I>>]; }',4)
    client=bench.Client.__new__(bench.Client);ok=False;report={}
    try:
        client.__init__('dot-ls');report['idle']=client.quiet();report['rounds']=[]
        for version in [1,2]:
            client.raw(payloads[version-1]);notifications=[]
            for _ in range(2):
                _,reply,_=client.receive();assert reply['params']['version']==version
                notifications.append(reply['params']['diagnostics'])
            assert notifications==[[],[]],notifications
            opened=client.quiet()
            client.raw(bench.packet('textDocument/didClose',{'textDocument':{'uri':bench.URI}}))
            assert client.receive()[1]['params']['diagnostics']==[]
            closed=client.quiet();report['rounds'].append({'version':version,'opened':opened,'closed':closed})
        client.raw(payloads[2]);_,reply,_=client.receive()
        assert reply['params']['version']==3 and reply['params']['diagnostics']==[]
        start=time.perf_counter();client.raw(tiny);seen=[];final=[]
        while len(final)<2:
            arrived,reply,_=client.receive();version=reply['params']['version'];seen.append(version)
            assert seen==sorted(seen),seen
            if version==4:final.append(reply['params']['diagnostics'])
        assert final[0]==[] and any(d['severity']==1 for d in final[1]),final
        report['replacement_final_ms']=(arrived-start)*1000;report['versions_after_replacement']=seen
        report['after_replacement']=client.quiet();ok=True
    finally:
        if hasattr(client,'p'):report['resources']=client.close(ok)
    assert ok and report['resources']['exit_code']==0
    (out/'lifecycle.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2));raise SystemExit()
rows = []
for kind in (['plain'] if a.plain else ['repeated','unique']):
    for mb in [5,20,40]:
        source, _, metadata = bench.fixture('plain' if kind=='plain' else 'html',mb)
        if kind == 'unique':
            number = [0]
            def body(_):
                i = number[0];number[0] += 1
                return f'<B>{i:08d}</B><BR/>b'.encode()
            source = re.sub(rb'<B>alpha</B><BR/>beta',body,source)
            assert number[0] == metadata['html_labels']
        assert len(source) == mb*1_000_000
        path = bench.FIXTURES/f'cap-{kind}-{mb}mb.dot';path.write_bytes(source)
        origin = source.rfind(b'    n')+4 if kind=='plain' else source.rfind(b'</B>')
        bad = source[:origin]+b'@'+source[origin+1:] if kind=='plain' else source[:origin]+b'</I>'+source[origin+4:]
        variants = [('open',source),('outer_edit',source.replace(b'controlled',b'controller',1)),
                    ('tail_error',bad),('repair',source),('tail_error',bad),('repair',source)]
        payloads = [(phase,bench.message(text.decode(),v)) for v,(phase,text) in enumerate(variants,1)]
        for trial in range(1,a.trials+1):
            row = {'build':a.label,'kind':kind,'mb':mb,'trial':trial,
                   'labels':metadata['html_labels'],'source_sha256':hashlib.sha256(source).hexdigest(),
                   'phases':[]}
            client = bench.Client.__new__(bench.Client);ok = False
            try:
                client.__init__('dot-ls');row['startup_ms']=client.startup_ms;row['idle']=client.quiet()
                for version,(phase,data) in enumerate(payloads,1):
                    start=time.perf_counter();client.raw(data);notifications=[]
                    for _ in range(1 if kind=='plain' else 2):
                        while True:
                            arrived,reply,size=client.receive()
                            if reply.get('method')=='textDocument/publishDiagnostics':
                                assert reply['params']['version']==version
                                ds=reply['params']['diagnostics']
                                notifications.append({'ms':(arrived-start)*1000,'diagnostics':ds,'wire_bytes':size});break
                    settled=client.quiet()
                    ds=notifications[-1]['diagnostics']
                    errors=[d for d in ds if d.get('severity')==1]
                    incomplete=any('incomplete' in str(d.get('code')) for d in ds)
                    if a.label=='after' or mb==5 or kind=='plain':
                        assert not incomplete,(kind,mb,phase,ds)
                        assert bool(errors)==(phase=='tail_error'),(kind,mb,phase,ds)
                        if phase=='tail_error':
                            expected_line=bad[:origin].count(b'\n')
                            assert any(d['range']['start']['line']==expected_line for d in errors),(expected_line,ds)
                    else:assert incomplete,(kind,mb,phase,ds)
                    row['phases'].append({'phase':phase,'version':version,'dot_ms':notifications[0]['ms'],
                        'final_ms':notifications[-1]['ms'],'errors':len(errors),'incomplete':incomplete,
                        'settled_rss_bytes':settled['rss_bytes'],'notifications':notifications})
                ok=True
            except Exception as error:row['failure']=repr(error)
            finally:
                if hasattr(client,'p'):row['resources']=client.close(ok)
            assert ok and row['resources']['exit_code']==0,row
            rows.append(row)
            (out/f'{"plain-" if a.plain else ""}{a.label}.json').write_text(json.dumps({'binary':str(a.binary.resolve()),
                'binary_sha256':hashlib.sha256(a.binary.read_bytes()).hexdigest(),'runs':rows},indent=2)+'\n')
            print(a.label,kind,mb,trial,'final ms',round(statistics.median(r['final_ms'] for r in row['phases']),2),
                  'peak MB',round(row['resources']['actual_peak_rss_bytes']/1e6,2),flush=True)
