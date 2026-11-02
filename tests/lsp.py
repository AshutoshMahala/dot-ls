#!/usr/bin/env python3
"""Protocol acceptance checks and warm-launch measurements; stdlib only."""
import json, subprocess, threading, queue, time, statistics, sys, os
BIN = os.path.abspath(sys.argv[1] if len(sys.argv)>1 else 'zig-out/bin/dot-ls')
class Client:
    def __init__(self):
        self.start=time.perf_counter(); self.p=subprocess.Popen([BIN,'lsp'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.q=queue.Queue(); threading.Thread(target=self.read,daemon=True).start()
    def read(self):
        try:
            while True:
                headers={}
                while True:
                    line=self.p.stdout.readline()
                    if not line: return
                    if line==b'\r\n': break
                    k,v=line.decode().split(':',1); headers[k.lower()]=v.strip()
                self.q.put(json.loads(self.p.stdout.read(int(headers['content-length']))))
        except Exception as e: self.q.put(e)
    def raw(self,b): self.p.stdin.write(b'Content-Length: '+str(len(b)).encode()+b'\r\n\r\n'+b); self.p.stdin.flush()
    def send(self,method,params=None,id=None):
        v={'jsonrpc':'2.0','method':method}
        if params is not None: v['params']=params
        if id is not None: v['id']=id
        self.raw(json.dumps(v,ensure_ascii=False).encode())
    def get(self):
        v=self.q.get(timeout=15)
        if isinstance(v,Exception): raise v
        return v
    def init(self,enc=None):
        self.send('initialize',{'processId':None,'capabilities':{'general':{'positionEncodings':enc}} if enc else {}},1)
        reply=self.get(); assert reply['id']==1 and 'result' in reply,reply
        self.send('initialized',{})
        return reply
    def open(self,text,version=1,uri='untitled:test'):
        self.send('textDocument/didOpen',{'textDocument':{'uri':uri,'languageId':'anything','version':version,'text':text}})
    def change(self,text,version,uri='untitled:test'):
        self.send('textDocument/didChange',{'textDocument':{'uri':uri,'version':version},'contentChanges':[{'text':text}]})
    def diag(self,version=None):
        v=self.get(); assert v.get('method')=='textDocument/publishDiagnostics',v
        if version is not None: assert v['params']['version']==version,v
        return v['params']['diagnostics']
    def stop(self):
        self.send('shutdown',id=90)
        while True:
            v=self.get()
            if v.get('id')==90: break
        assert v.get('result','missing') is None,v
        self.send('exit'); self.p.stdin.close(); assert self.p.wait(timeout=10)==0,self.p.stderr.read().decode()
        assert not self.p.stderr.read(), 'unexpected stderr'

def checks():
    c=Client(); c.send('unknown',id=2); assert c.get()['error']['code']==-32002
    c.init(); c.send('unknown',id='x'); assert c.get()['id']=='x'
    c.raw(b'{'); assert c.get()['error']['code']==-32700
    c.raw(b'{"jsonrpc":"2.0","method":"unknown","id":[[[]]]}'); assert c.get()['error']['code']==-32600
    c.open('digraph G { a -> }'); d=c.diag(1)
    assert any("found '}'" in x['message'] and 'after the edge operator' in x['message'] for x in d),d
    # Completion is bounded and still available while syntax is broken.
    c.send('textDocument/completion',{'textDocument':{'uri':'untitled:test'},'position':{'line':0,'character':3}},'complete')
    reply=c.get(); assert reply['id']=='complete' and not reply['result']['isIncomplete'],reply
    items=reply['result']['items']; assert {i['label'] for i in items}=={'strict','graph','digraph'}
    assert all(i['kind']==14 and i['insertText']==i['label'] for i in items),items
    c.send('textDocument/completion',{'textDocument':{'uri':'untitled:missing'},'position':{'line':0,'character':0}},70)
    assert c.get()['error']['code']==-32602
    c.send('textDocument/completion',{'textDocument':{'uri':'untitled:test'},'position':{'line':-1,'character':0}},71)
    assert c.get()['error']['code']==-32602
    c.change('digraph G { a -> b }',2); assert c.diag(2)==[]
    c.change('digraph G { a -> }',1); assert c.diag(1) # backward version still applied
    c.send('textDocument/didClose',{'textDocument':{'uri':'untitled:test'}}); assert c.diag()==[]
    c.open('graph {}',1); assert c.diag(1)==[]
    c.stop()
    for enc,expected in [('utf-8',len('digraph { "😀" '.encode())),('utf-16',len('digraph { "😀" '.encode('utf-16-le'))//2),('utf-32',len('digraph { "😀" '))]:
        c=Client(); assert c.init([enc])['result']['capabilities']['positionEncoding']==enc
        c.open('digraph { "😀" @ }'); diagnostics=c.diag(1)
        invalid=[d for d in diagnostics if 'byte' in d['message']]
        assert invalid and invalid[0]['range']['start']=={'line':0,'character':expected},(enc,diagnostics)
        c.stop()
    # Mixed line endings and byte order mark must preserve line coordinates.
    c=Client(); c.init(); c.open('\ufeffdigraph {\r\n"😀";\r@\n}'); d=c.diag(1)
    assert any(x['range']['start']=={'line':2,'character':0} for x in d),d
    c.stop()
    # Related locations point to the actual opening construct in negotiated units.
    c=Client(); c.send('initialize',{'capabilities':{'textDocument':{'publishDiagnostics':{'relatedInformation':True}},'general':{'positionEncodings':['utf-16']}}},1)
    reply=c.get(); assert reply['result']['serverInfo']['name']=='dot-ls'
    assert reply['result']['capabilities']['completionProvider']['resolveProvider'] is False
    c.send('initialized',{})
    source='digraph { "😀" [label=x'
    c.open(source); d=c.diag(1)
    related=[r for x in d for r in x.get('relatedInformation',[])]
    assert any(r['location']['uri']=='untitled:test' and r['location']['range']['start']['character']==len(source[:source.index('[')].encode('utf-16-le'))//2 for r in related),d
    c.change('digraph { a [label="unfinished',2);d=c.diag(2)
    assert any('closing double quote' in x['message'] for x in d),d
    c.stop()
    # Multi-document jobs and close/reopen must not cross document incarnations.
    c=Client(); c.init(); c.open('digraph { a -> }',1,'untitled:a'); c.open('graph {}',1,'untitled:b')
    seen={c.get()['params']['uri'],c.get()['params']['uri']}; assert seen=={'untitled:a','untitled:b'},seen
    c.stop()
    # Burst edits: only accepted current generations may be published; last must arrive.
    c=Client(); c.init(); large='digraph {\n'+('a -> b;\n'*100000)+'}\n'
    c.open(large,1)
    for version in range(2,22): c.change(large,version)
    c.change('digraph { final -> }',22)
    versions=[]
    while True:
        message=c.get(); versions.append(message['params']['version'])
        if versions[-1]==22: break
    assert versions==sorted(versions),versions
    assert message['params']['diagnostics'],message
    c.stop()
    # In-place packet ownership must preserve escaped keys and Unicode text.
    c=Client(); c.init()
    c.raw(b'{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"untitled:escaped","version":1,"te\\u0078t":"digraph {\\n \\\"\\uD83D\\uDE00\\\";\\n}"}}}')
    assert c.diag(1)==[]
    # A full-sync batch uses the last change, with all fields in the same packet.
    c.send('textDocument/didChange',{'textDocument':{'uri':'untitled:escaped','version':2},'contentChanges':[{'text':'digraph { a -> }'},{'text':'graph {}'}]})
    assert c.diag(2)==[]
    c.send('textDocument/didChange',{'textDocument':{'uri':'untitled:escaped','version':3},'contentChanges':[{'range':{},'text':'invalid'}]})
    c.change('digraph { a -> }',4,'untitled:escaped'); assert c.diag(4)
    c.stop()
    # Completion waits for the current context; diagnostics must arrive first.
    c=Client(); c.init(); c.open(large,1)
    c.send('textDocument/completion',{'textDocument':{'uri':'untitled:test'},'position':{'line':0,'character':0}},'busy')
    replies=[c.get(),c.get()]
    assert any(r.get('id')=='busy' and len(r['result']['items'])==3 for r in replies),replies
    assert any(r.get('method')=='textDocument/publishDiagnostics' and r['params']['version']==1 for r in replies),replies
    c.send('textDocument/didClose',{'textDocument':{'uri':'untitled:test'}});c.diag()
    c.send('textDocument/completion',{'textDocument':{'uri':'untitled:test'},'position':{'line':0,'character':0}},'closed')
    assert c.get()['error']['code']==-32602
    c.stop()
    # Exit without shutdown is a failure. EOF must release the worker too.
    c=Client(); c.init(); c.send('exit'); assert c.p.wait(timeout=10)==1
    c=Client(); c.init(); c.open(large); c.p.stdin.close(); assert c.p.wait(timeout=10)==0
    # A diagnostic retention stop must report incomplete work, not clean syntax.
    c=Client(); c.init(); c.open('digraph {\n'+('a -> ;\n'*1200)+'}')
    d=c.diag(1); assert len(d)<=1001 and any(x['code']=='dot-ls:incomplete' for x in d),len(d)
    c.stop()
    # Invalid framing closes the transport safely; it is not resynchronizable.
    c=Client(); c.p.stdin.write(b'Content-Length: 1\r\nContent-Length: 1\r\n\r\nx'); c.p.stdin.flush()
    assert c.p.wait(timeout=10)!=0
    startup=[]
    for _ in range(15):
        c=Client(); c.init(); startup.append((time.perf_counter()-c.start)*1000); c.stop()
    latency=[]
    c=Client(); c.init(); c.open(large); c.diag(1)
    for v in range(2,12):
        start=time.perf_counter(); c.change(large,v); c.diag(v); latency.append((time.perf_counter()-start)*1000)
    c.stop()
    print(json.dumps({'checks':'passed','binary_bytes':os.path.getsize(BIN),'startup_ms_median':statistics.median(startup),'startup_ms_max':max(startup),'edit_bytes':len(large.encode()),'edit_ms_median':statistics.median(latency),'edit_ms_max':max(latency)},indent=2))

if __name__ == '__main__': checks()
