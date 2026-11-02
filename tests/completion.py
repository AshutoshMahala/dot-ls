#!/usr/bin/env python3
"""Context selection, encodings and deferred request lifecycle."""
from lsp import Client
header={'strict','graph','digraph'}
body={'graph','node','edge','subgraph'}

def query(c, line, character, identifier=50):
    c.send('textDocument/completion',{'textDocument':{'uri':'untitled:test'},'position':{'line':line,'character':character}},identifier)
    reply=c.get();assert reply.get('id')==identifier,reply
    return reply

cases=[
    ('|',header), ('str|',header), ('strict |',{'graph','digraph'}),
    ('strict graph na|',set()), ('digraph { |',body),
    ('digraph { a -> |',{'subgraph'}), ('digraph { a -> sub|',{'subgraph'}),
    ('digraph { subgraph cluster { |',body), ('digraph { subgraph na|',set()),
    ('digraph { a [label=no|]',set()),
    ('digraph { a [label=x]; no|',body), ('digraph { rankdir=no|',set()),
    ('digraph { a:no|',set()), ('digraph { "no|de" }',set()),
    ('digraph { // no|',set()), ('digraph { /* no|',set()),
    ('digraph { # no|',set()), ('digraph { /* x */ |',body),
    ('digraph { a [label=<<B>no|</B>>] }',set()),
    ('digraph { "unfinished|',set()), ('digraph { @ |',set()),
    ('digraph { | @',body), ('digraph {} |',set()),
    ('\ufeffdigraph {\r\n"😀";\rno|',body),
    ('digraph { "😀"; no|',body),
]
for encoding in ('utf-8','utf-16','utf-32'):
    c=Client();c.init([encoding])
    for version,(marked,expected) in enumerate(cases,1):
        prefix,suffix=marked.split('|');source=prefix+suffix
        if version==1:c.open(source,version)
        else:c.change(source,version)
        c.diag(version)
        if 'label=<' in source: c.diag(version)
        # CRLF is one line break. All three encodings must select the same region.
        lines=prefix.replace('\r\n','\n').replace('\r','\n').split('\n')
        column=len(lines[-1].encode({'utf-16':'utf-16-le','utf-32':'utf-32-le'}.get(encoding,encoding)))//(1 if encoding=='utf-8' else 2 if encoding=='utf-16' else 4)
        reply=query(c,len(lines)-1,column)
        assert {x['label'] for x in reply['result']['items']}==expected,(encoding,marked,reply)
    assert query(c,999999,0)['result']['items']==[]
    assert query(c,0,999999)['result']['items']==[]
    c.stop()

# Requests sent during a long current generation are cancelled or invalidated;
# they must never return candidates from an older generation.
large='digraph {\n'+'a -> b;\n'*500000+'}'
for action,code in [('cancel',-32800),('edit',-32801),('close',-32801)]:
    c=Client();c.init();c.open(large)
    c.send('textDocument/completion',{'textDocument':{'uri':'untitled:test'},'position':{'line':0,'character':0}},'deferred')
    if action=='cancel':c.send('$/cancelRequest',{'id':'deferred'})
    elif action=='edit':c.change('digraph { a -> }',2)
    else:c.send('textDocument/didClose',{'textDocument':{'uri':'untitled:test'}})
    while True:
        reply=c.get()
        if reply.get('id')=='deferred':break
    assert reply['error']['code']==code,(action,reply)
    c.stop()
# Completion and references share one bounded deferred queue.
c=Client();c.init();c.open(large)
for n in range(65):
    params={'textDocument':{'uri':'untitled:test'},'position':{'line':0,'character':0}}
    if n%2:params['context']={'includeDeclaration':True}
    c.send('textDocument/references' if n%2 else 'textDocument/completion',params,1000+n)
while True:
    reply=c.get()
    if reply.get('id')==1064:break
assert reply['error']['code']==-32803,reply
c.stop()
print('Completion: contexts, partial input, UTF-8/16/32, line endings, limits and deferred lifecycle passed')
