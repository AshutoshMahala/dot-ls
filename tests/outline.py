#!/usr/bin/env python3
"""Hierarchical symbols, recovery, encoding and snapshot checks."""
import lsp

def init(c,enc='utf-16'):
    c.send('initialize',{'capabilities':{'general':{'positionEncodings':[enc]},'textDocument':{'documentSymbol':{'hierarchicalDocumentSymbolSupport':True}}}},1)
    r=c.get();assert r['result']['capabilities']['documentSymbolProvider'],r
    c.send('initialized',{})

def ask(c, ident=20):
    c.send('textDocument/documentSymbol',{'textDocument':{'uri':'untitled:test'}},ident)
    while True:
        r=c.get()
        if r.get('id')==ident:return r
        assert r.get('method')=='textDocument/publishDiagnostics',r

def tree(rows):
    return [(r['name'],tree(r.get('children',[]))) for r in rows]

def check(source,expected):
    c=lsp.Client();init(c);c.open(source)
    r=ask(c);assert 'result' in r,r
    assert tree(r['result'])==expected,(source,tree(r['result']))
    def valid(rows,parent=None):
        for r in rows:
            a,b=r['range']['start'],r['range']['end'];s,e=r['selectionRange']['start'],r['selectionRange']['end']
            key=lambda p:(p['line'],p['character'])
            assert key(a)<=key(s)<=key(e)<=key(b),r
            if parent:assert key(parent['range']['start'])<=key(a)<=key(b)<=key(parent['range']['end']),(parent,r)
            valid(r.get('children',[]),r)
    valid(r['result']);c.stop();return r['result']

if __name__=='__main__':
    basic='digraph G { a; subgraph cluster_x { b; c; } d; { e; } f; a -> b; graph [x=y]; label=x; }'
    rows=check(basic,[('G',[('a',[]),('cluster_x',[('b',[]),('c',[])]),('d',[]),('{…}',[('e',[])]),('f',[])])])
    assert rows[0]['kind']==3 and rows[0]['children'][1]['kind']==2 and rows[0]['children'][3]['kind']==4,rows
    check('digraph G { a; subgraph cluster_x { b; c; } d [sha; e; f; }',[('G',[('a',[]),('cluster_x',[('b',[]),('c',[])]),('d',[]),('e',[]),('f',[])])])
    check('digraph G { a; broken -> ; subgraph later { b; } c; }',[('G',[('a',[]),('later',[('b',[])]),('c',[])])])
    check('digraph G { a; subgraph x { b;',[('G',[('a',[]),('x',[('b',[])])])])
    check('digraph { a [label=<<TABLE><TR><TD>x</TD></TR></TABLE>>]; "a"+"b"; }',[('digraph',[('a',[]),('ab',[])])])
    check('diagraph G { a; }',[])
    check('digraph "" { ""; subgraph "" { ""+""; } }',[('""',[('""',[]),('""',[('""+""',[])])])])
    check('digraph G { a -> { b; c; } -> subgraph cluster_x { d; }; }',[('G',[('{…}',[('b',[]),('c',[])]),('cluster_x',[('d',[])])])])
    check('digraph G { a',[('G',[('a',[])])])
    check('digraph G { subgraph s { a:p',[('G',[('s',[('a',[])])])])
    check('digraph G { subgraph s { a [x=y]',[('G',[('s',[('a',[])])])])
    check('digraph G { subgraph s { a [x=; } b; }',[('G',[('s',[('a',[])]),('b',[])])])
    check('digraph G { a -> ; b; c = ; d; }',[('G',[('b',[]),('d',[])])])
    check('digraph G { a /* closed comment */',[('G',[('a',[])])])
    check('digraph G { a:p:n',[('G',[('a',[])])])
    check('digraph G { a [label="unfinished',[('G',[('a',[])])])
    # An unfinished port/assignment/edge or lexical failure is not a node head.
    for suffix in ('a:', 'a ->', 'a =', 'graph', 'subgraph name', '"unfinished', 'a /* unfinished'):
        check('digraph G { '+suffix,[('G',[])])
    # Braces inside strings, comments and HTML do not close a DOT scope.
    check('digraph G { /* { } */ a [label="}"]; b [label=<<B>{}</B>>]; }',[('G',[('a',[]),('b',[])])])
    check('digraph {a[x=1][y=2]; a; a:p [x=2];}',[('digraph',[('a',[]),('a',[]),('a',[])])])
    # Preserve full statement and graph ranges, including ports/attributes.
    ranged='digraph G { a:p [label="x"][color=red]; }\n// trailing comment'
    rows=check(ranged,[('G',[('a',[])])])
    assert rows[0]['range']['end']=={'line':0,'character':ranged.index('}')+1}
    assert rows[0]['children'][0]['range']['end']=={'line':0,'character':ranged.index(';')}
    # Public extents include interior trivia and all lists, but omit trailing trivia.
    ranged='digraph G { a:p:n [] /* gap */ [x=y] /* tail */ ; } // trailing'
    rows=check(ranged,[('G',[('a',[])])])
    assert rows[0]['children'][0]['range']['end']=={'line':0,'character':ranged.index(' /* tail */')}
    assert rows[0]['range']['end']=={'line':0,'character':ranged.index('}')+1}
    for enc,width in [('utf-8',6),('utf-16',3),('utf-32',2)]:
        c=lsp.Client();init(c,enc);c.open('// é😀\r\ndigraph "é😀" {\r "é😀";\n}')
        rows=ask(c)['result'];g=rows[0];n=g['children'][0]
        assert g['selectionRange']=={'start':{'line':1,'character':8},'end':{'line':1,'character':10+width}},(enc,g)
        assert n['selectionRange']=={'start':{'line':2,'character':1},'end':{'line':2,'character':3+width}},(enc,n)
        c.change('digraph Replaced { z; }',2)
        r=ask(c);assert tree(r['result'])==[('Replaced',[('z',[])])],r
        c.stop()
    # Clients without hierarchy support get the standard flat fallback.
    c=lsp.Client();c.init();c.open('digraph G { subgraph s { a; } }')
    flat=ask(c)['result'];assert [s['name'] for s in flat]==['G','s','a'],flat
    assert flat[2]['containerName']=='s' and flat[2]['location']['uri']=='untitled:test',flat
    c.stop()
    # Explicit bounds must not become a silently truncated success.
    c=lsp.Client();init(c);c.open('digraph G {'+' a;'*250000+'}')
    reply=ask(c);assert reply['error']['code']==-32803,reply
    c.change('digraph Small { a; }',2);assert tree(ask(c)['result'])==[('Small',[('a',[])])]
    c.stop()
    # Long and concatenated names keep full navigation ranges but bounded labels.
    check('digraph "clu"+/*glue*/"ster_g" { subgraph "clu"+"ster_x" { "é"+"😀"; } }',[('cluster_g',[('cluster_x',[('é😀',[])])])])
    rows=check('digraph G { "'+('😀'*1000)+'"; }',[('G',[('😀'*32+'…',[])])])
    assert rows[0]['children'][0]['selectionRange']['end']['character']>1000
    # Queued requests belong to one generation; edits and close/reopen retire them.
    c=lsp.Client();init(c)
    c.open('digraph Old {'+' a;'*200000+'}')
    c.send('textDocument/documentSymbol',{'textDocument':{'uri':'untitled:test'}},'old')
    c.change('digraph New { z; }',2)
    c.send('textDocument/documentSymbol',{'textDocument':{'uri':'untitled:test'}},'new')
    replies={}
    while len(replies)<2:
        r=c.get()
        if 'id' in r:replies[r['id']]=r
    assert tree(replies['new']['result'])==[('New',[('z',[])])],replies['new']
    assert replies['old'].get('error',{}).get('code')==-32801 or replies['old'].get('result',[{}])[0].get('name')=='Old',replies['old']
    c.send('textDocument/didClose',{'textDocument':{'uri':'untitled:test'}})
    c.open('digraph Reopened { q; }',1)
    assert tree(ask(c)['result'])==[('Reopened',[('q',[])])]
    c.stop()
    print('document outline protocol checks passed')
