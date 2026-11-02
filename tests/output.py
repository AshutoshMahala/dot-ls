#!/usr/bin/env python3
"""Nonblocking stdio: partial intake, paused readers, intact frames and exit bounds."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import time

BIN = str(Path(sys.argv[1] if len(sys.argv)>1 else 'zig-out/bin/dot-ls').resolve())

def packet(method, params=None, ident=None):
    value={'jsonrpc':'2.0','method':method}
    if params is not None:value['params']=params
    if ident is not None:value['id']=ident
    body=json.dumps(value).encode()
    return b'Content-Length: '+str(len(body)).encode()+b'\r\n\r\n'+body

class Client:
    def __init__(self):
        self.p=subprocess.Popen([BIN,'lsp'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,bufsize=0)
        os.set_blocking(self.p.stdin.fileno(),False)
        self.buffer=bytearray()
        self.send('initialize',{'capabilities':{'textDocument':{'documentSymbol':{'hierarchicalDocumentSymbolSupport':True}}}},1)
        assert self.get()['id']==1
    def raw(self,data):
        view=memoryview(data);deadline=time.monotonic()+15
        while view:
            remaining=deadline-time.monotonic()
            assert remaining>0 and select.select([], [self.p.stdin], [], remaining)[1], 'input blocked while output was paused'
            try:n=os.write(self.p.stdin.fileno(),view)
            except BlockingIOError:continue
            view=view[n:]
    def send(self,*args):self.raw(packet(*args))
    def get(self,timeout=15):
        deadline=time.monotonic()+timeout
        while True:
            pos=self.buffer.find(b'\r\n\r\n')
            if pos>=0:
                size=int(self.buffer[:pos].split(b':',1)[1])
                if len(self.buffer)>=pos+4+size:
                    body=bytes(self.buffer[pos+4:pos+4+size]);del self.buffer[:pos+4+size]
                    return json.loads(body)
            remaining=deadline-time.monotonic()
            assert remaining>0,'reply timeout'
            assert select.select([self.p.stdout],[],[],remaining)[0],'reply timeout'
            data=os.read(self.p.stdout.fileno(),256*1024)
            assert data, self.p.stderr.read().decode()
            self.buffer.extend(data)
    def open(self,text):self.send('textDocument/didOpen',{'textDocument':{'uri':'untitled:output','languageId':'dot','version':1,'text':text}})
    def stop(self):
        self.send('shutdown',None,90)
        while self.get().get('id')!=90:pass
        self.send('exit');self.p.stdin.close()
        assert self.p.wait(timeout=4)==0,self.p.stderr.read().decode()
        assert not self.p.stderr.read()
    def kill(self):
        if self.p.poll() is None:self.p.kill();self.p.wait()

c=Client()
try:
    c.open('digraph { a [shape=box]; }')
    query=packet('textDocument/hover',{'textDocument':{'uri':'untitled:output'},'position':{'line':0,'character':15}},2)
    cut=query.index(b'\r\n\r\n')-3
    c.raw(query[:cut])
    assert c.get()['method']=='textDocument/publishDiagnostics' # header is still partial
    c.raw(query[cut:]);assert c.get()['id']==2
    c.send('textDocument/didChange',{'textDocument':{'uri':'untitled:output','version':2},'contentChanges':[{'text':'digraph { a -> }'}]})
    query=packet('unknown',{},3);cut=len(query)-3;c.raw(query[:cut])
    assert c.get()['params']['version']==2 # body is still partial
    c.raw(query[cut:]);assert c.get()['id']==3
    c.stop()
finally:c.kill()

# Force a reply far larger than the pipe. The old synchronous dispatcher cannot
# accept close/hover/shutdown until the client resumes reading that reply.
source='digraph G {\n'+''.join(f'n{i};\n' for i in range(60000))+'}\n'
for early_exit in (False,True):
    c=Client()
    try:
        c.open(source);assert c.get()['method']=='textDocument/publishDiagnostics'
        c.send('textDocument/documentSymbol',{'textDocument':{'uri':'untitled:output'}},10)
        assert select.select([c.p.stdout],[],[],10)[0]
        time.sleep(.15)
        c.send('textDocument/didClose',{'textDocument':{'uri':'untitled:output'}})
        c.send('textDocument/hover',{'textDocument':{'uri':'untitled:output'},'position':{'line':0,'character':0}},11)
        c.send('$/cancelRequest',{'id':11})
        if not early_exit:
            large='digraph {\n'+'x -> y;\n'*750000+'}\n'
            c.send('textDocument/didOpen',{'textDocument':{'uri':'untitled:cancel','languageId':'dot','version':1,'text':large}})
            c.send('textDocument/completion',{'textDocument':{'uri':'untitled:cancel'},'position':{'line':0,'character':0}},12)
            c.send('$/cancelRequest',{'id':12})
            c.send('textDocument/didClose',{'textDocument':{'uri':'untitled:cancel'}})
        c.send('shutdown',None,90)
        if early_exit:
            start=time.monotonic();c.send('exit');c.p.stdin.close()
            code=c.p.wait(timeout=4)
            assert code!=0,'stopped reader must report drain failure'
            assert time.monotonic()-start<3.5
            assert b'OutputDrainTimeout' in c.p.stderr.read()
        else:
            replies={};clear=False
            while 90 not in replies:
                value=c.get()
                if 'id' in value:replies[value['id']]=value
                else:clear=True
            assert len(replies[10]['result'][0]['children'])==60000
            assert replies[11]['error']['code']==-32602
            assert replies[12]['error']['code']==-32800
            assert replies[90]['result'] is None and clear
            c.send('exit');c.p.stdin.close();assert c.p.wait(timeout=4)==0,c.p.stderr.read().decode()
            assert not c.p.stderr.read()
    finally:c.kill()

# Broken stdout must terminate even when input stays open.
c=Client()
try:
    c.p.stdout.close();c.send('unknown',{},4)
    assert c.p.wait(timeout=4)!=0
finally:c.kill()
print('Output: partial intake, paused/resumed reader, intact large reply, close/cancel input, bounded exit and broken pipe passed.')
