#!/usr/bin/env python3
"""Node identity, source ranges, lifecycle and malformed request checks."""
from lsp import Client

def request(c, line, char, include=True, uri='untitled:test'):
    c.send('textDocument/references', {'textDocument':{'uri':uri},'position':{'line':line,'character':char},'context':{'includeDeclaration':include}}, 50)
    reply=c.get(); assert reply.get('id')==50,reply
    return reply

def locations(c,line,char,include=True):
    reply=request(c,line,char,include); assert 'result' in reply,reply
    return [(x['range']['start']['line'],x['range']['start']['character'],x['range']['end']['line'],x['range']['end']['character']) for x in reply['result']]

for enc,quote_len in [('utf-8',6),('utf-16',4),('utf-32',3)]:
    c=Client(); assert c.init([enc])['result']['capabilities']['referencesProvider']
    source='digraph G {\r\n  a -> b -> a:p;\r  "a" [a=a,label="a"];\n  subgraph a { a; }\n  "😀" -> "😀";\n  "ab" -> "a" + "b";\n  a=x; node [a=a];\n}'
    c.open(source); assert c.diag(1)==[]
    expected=[(1,2,1,3),(1,12,1,13),(2,2,2,5),(3,15,3,16)]
    assert locations(c,1,2)==expected
    assert locations(c,2,3,False)==expected[1:]
    assert locations(c,1,14)==[], 'port must not be a node'
    assert locations(c,2,7)==[], 'attribute key must not be a node'
    assert locations(c,3,11)==[], 'subgraph name must not be a node'
    assert locations(c,6,2)==[], 'assignment must not be a node'
    assert locations(c,4,3)==[(4,2,4,2+quote_len),(4,6+quote_len,4,6+2*quote_len)]
    assert locations(c,5,3)==[(5,2,5,6),(5,10,5,19)]
    c.change('digraph { z -> z }',2); assert c.diag(2)==[]
    assert len(locations(c,0,10))==2
    c.change('digraph { z -> }',3); assert c.diag(3)
    assert request(c,0,10)['error']['code']==-32803
    c.change('digraph {}',4); assert c.diag(4)==[]; assert locations(c,0,2)==[]
    assert request(c,-1,0)['error']['code']==-32602
    assert request(c,0,0,uri='untitled:missing')['error']['code']==-32602
    c.send('textDocument/didClose',{'textDocument':{'uri':'untitled:test'}}); c.diag()
    assert request(c,0,0)['error']['code']==-32602
    c.open('digraph { a -> a }'); assert c.diag(1)==[]; assert len(locations(c,0,10))==2
    c.stop()
# Scoped endpoints, chains, repeated node IDs, and implicit first creation.
c=Client(); c.init(); c.open('digraph { a -> { b; c } -> d -> a; a; }'); assert c.diag(1)==[]
assert len(locations(c,0,10))==3,locations(c,0,10)
assert len(locations(c,0,17))==1
assert len(locations(c,0,27))==1
c.stop()

# Multiline logical IDs and comments between concatenated operands.
c=Client(); c.init(); source='digraph { "a\nb"; "a\nb"; "ab"; "a" /* glue */ + "b"; <ab>; }'
c.open(source); assert c.diag(1)==[]
assert len(locations(c,0,11))==2
assert len(locations(c,2,7))==3
c.stop()
# Requests during rebuilding wait for the new index; diagnostics arrive first.
big='digraph {\nunique -> target;\n'+('x -> y;\n'*300000)+'}'
c=Client();c.init();c.open('digraph { a -> a }');c.diag(1)
c.change(big,2)
c.send('textDocument/references',{'textDocument':{'uri':'untitled:test'},'position':{'line':1,'character':1},'context':{'includeDeclaration':True}},'queued')
seen=[]
while len(seen)<2: seen.append(c.get())
assert seen[0].get('method')=='textDocument/publishDiagnostics' and seen[0]['params']['version']==2,seen
assert seen[1]['id']=='queued' and len(seen[1]['result'])==1,seen
# Edits invalidate pending requests, with copied string IDs surviving intake teardown.
c.change(big,3)
c.send('textDocument/references',{'textDocument':{'uri':'untitled:test'},'position':{'line':1,'character':1},'context':{'includeDeclaration':True}},'stale')
c.change('digraph { z -> z }',4)
got={}
while 'stale' not in got or 'diag4' not in got:
    reply=c.get()
    if reply.get('id')=='stale':got['stale']=reply;assert reply['error']['code']==-32801,reply
    elif reply.get('method')=='textDocument/publishDiagnostics' and reply['params']['version']==4:got['diag4']=reply
assert len(locations(c,0,10))==2
# Pending references support explicit cancellation.
c.change(big,5)
c.send('textDocument/references',{'textDocument':{'uri':'untitled:test'},'position':{'line':1,'character':1},'context':{'includeDeclaration':True}},'cancel-me')
c.send('$/cancelRequest',{'id':'cancel-me'})
got={}
while 'cancel' not in got or 'diag5' not in got:
    reply=c.get()
    if reply.get('id')=='cancel-me':got['cancel']=reply;assert reply['error']['code']==-32800,reply
    elif reply.get('method')=='textDocument/publishDiagnostics' and reply['params']['version']==5:got['diag5']=reply
c.stop()
# A new document's diagnostics take priority over an older document's index.
c=Client();c.init();c.open(big);c.diag(1)
c.send('textDocument/references',{'textDocument':{'uri':'untitled:test'},'position':{'line':1,'character':1},'context':{'includeDeclaration':True}},'older-index')
c.open('digraph { broken -> }',uri='untitled:priority')
first=c.get();assert first.get('method')=='textDocument/publishDiagnostics' and first['params']['uri']=='untitled:priority',first
reply=c.get();assert reply.get('id')=='older-index' and len(reply['result'])==1,reply
c.stop()
# A large malformed packet must release intake priority and resume queued indexing.
c=Client();c.init();c.open(big);c.diag(1)
c.send('textDocument/references',{'textDocument':{'uri':'untitled:test'},'position':{'line':1,'character':1},'context':{'includeDeclaration':True}},'resume')
c.raw(b' '*1000000+b'{')
responses=[c.get(),c.get()]
assert any(r.get('id')=='resume' and len(r.get('result',[]))==1 for r in responses),responses
assert any(r.get('error',{}).get('code')==-32700 for r in responses),responses
c.stop()
# Oversized responses fail explicitly instead of returning incomplete locations.
c=Client(); c.init(); c.open('digraph { '+('a; '*10001)+'}'); assert c.diag(1)==[]
assert request(c,0,10)['error']['code']==-32803
assert len(locations(c,0,10,False))==10000
c.stop()

# Separate graph documents have independent identities.
c=Client(); c.init(); c.open('digraph { a; a; }'); c.diag(1)
c.open('digraph { a; }',uri='untitled:other'); c.diag(1)
reply=request(c,0,10,uri='untitled:other'); assert len(reply['result'])==1 and reply['result'][0]['uri']=='untitled:other'
assert len(locations(c,0,10))==2
c.stop()
for left,right in [('a','"a"'),('1','"1"'),('<a>','a'),('"a\\"b"','"a\\"b"'),('""','""')]:
    c=Client(); c.init(); source='digraph { '+left+' -> '+right+'; }';c.open(source);assert c.diag(1)==[],source
    assert len(locations(c,0,10))==2,(source,locations(c,0,10))
    c.stop()

print('Node references: identities, chains, scopes, encodings, limits, invalid syntax and lifecycle passed')
