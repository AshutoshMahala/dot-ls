#!/usr/bin/env python3
"""Owner filtering, hover spans, broken input, encodings and request lifetime."""
from lsp import Client

def request(c,method,point,ident=60):
    c.send('textDocument/'+method,{'textDocument':{'uri':'untitled:test'},'position':point},ident)
    while True:
        reply=c.get()
        if reply.get('id')==ident:return reply
        assert reply.get('method')=='textDocument/publishDiagnostics',reply

def point(prefix,encoding):
    text=prefix.replace('\r\n','\n').replace('\r','\n').split('\n')
    return {'line':len(text)-1,'character':len(text[-1].encode({'utf-16':'utf-16-le','utf-32':'utf-32-le'}.get(encoding,encoding)))//{'utf-16':2,'utf-32':4}.get(encoding,1)}

cases=[
 ('digraph { node [|',{'shape','label','color'},{'rankdir','arrowhead','rank'}),
 ('digraph { a [sha|',{'shape'},{'rankdir','arrowhead'}),
 ('digraph { a:p [|',{'shape'},{'arrowhead'}),
 ('digraph { edge [|',{'arrowhead','weight'},{'shape','rankdir'}),
 ('digraph { a -> b -> c [|',{'arrowhead'},{'shape'}),
 ('digraph { a -> { b; } -> c [|',{'arrowhead'},{'shape'}),
 ('digraph { graph [|',{'rankdir','bgcolor'},{'shape','arrowhead','rank'}),
 ('digraph { subgraph s { graph [|',{'rank'},{'shape','rankdir','arrowhead'}),
 ('digraph { subgraph "clu"+"ster_x" { graph [|',{'rank','bgcolor','pencolor'},{'shape','rankdir','arrowhead'}),
 ('digraph { subgraph cluster_x { a; } b [|',{'shape'},{'pencolor'}),
 ('digraph { a [label=x, |',{'shape'},set()),
 ('digraph { a [label=x][|',{'shape'},set()),
 ('digraph { [|',set(),{'shape'}),
 ('digraph { a=x [|',set(),{'shape'}),
 ('digraph { subgraph x {} [|',set(),{'shape'}),
 ('digraph { a [label=|',set(),{'shape','label'}),
 ('digraph { a [label="sh|ape"]',set(),{'shape'}),
 ('digraph { a [/* sh|',set(),{'shape'}),
 ('digraph { a [label=<<B>sh|</B>>]',set(),{'shape'}),
]
for encoding in ('utf-8','utf-16','utf-32'):
    c=Client();init=c.init([encoding]);assert init['result']['capabilities']['hoverProvider']
    for version,(marked,yes,no) in enumerate(cases,1):
        prefix,suffix=marked.split('|');source=prefix+suffix
        if version==1:c.open(source,version)
        else:c.change(source,version)
        reply=request(c,'completion',point(prefix,encoding))
        names={x['label'] for x in reply['result']['items']}
        assert yes<=names and not no&names,(marked,names)
        assert not names&{'node','edge','digraph'},(marked,names)
    for version,marked in enumerate([
        '// é😀\r\ndigraph {\r "😀" [sh|ape=box];\n}',
        'digraph { a ["sh|ape"=box]; }',
        'digraph { a ["sh"+"ap|e"=box]; }',
        'digraph { rank|dir=LR; }',
    ],100):
        prefix,suffix=marked.split('|');c.change(prefix+suffix,version)
        reply=request(c,'hover',point(prefix,encoding));h=reply['result'];assert h and 'Type:' in h['contents']['value'] and 'Default:' in h['contents']['value'],reply
        assert 'Applies to:' in h['contents']['value'],h
        assert h['range']['start']['line']==point(prefix,encoding)['line']
    for version,marked in enumerate(['digraph { sh|ape; }','digraph { a [label="sh|ape"]; }','digraph { // sh|ape\n}','digraph { a [noSuch|Attribute=x]; }','digraph { a [label=<<B>sh|ape</B>>]; }'],200):
        prefix,suffix=marked.split('|');c.change(prefix+suffix,version)
        assert request(c,'hover',point(prefix,encoding))['result'] is None,marked
    assert request(c,'hover',{'line':999999,'character':0})['result'] is None
    c.stop()
# Hover requests use the same cancellation and generation rules as completion.
large='digraph {\n'+'a [shape=box];\n'*500000+'}'
for action,code in [('cancel',-32800),('edit',-32801),('close',-32801)]:
    c=Client();c.init();c.open(large)
    c.send('textDocument/hover',{'textDocument':{'uri':'untitled:test'},'position':{'line':1,'character':4}},'waiting')
    if action=='cancel':c.send('$/cancelRequest',{'id':'waiting'})
    elif action=='edit':c.change('digraph { a; }',2)
    else:c.send('textDocument/didClose',{'textDocument':{'uri':'untitled:test'}})
    while True:
        reply=c.get()
        if reply.get('id')=='waiting':break
    assert reply['error']['code']==code,(action,reply)
    c.stop()
print('Attributes: owner filtering, quoted names, UTF-8/16/32, hover exclusions and stale/cancelled requests passed')
