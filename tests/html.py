#!/usr/bin/env python3
"""Staged HTML diagnostics, exact rebasing, label selection and lifecycle."""
from lsp import Client

def merged(c,version,syntax=False):
    first=c.diag(version); assert bool(first)==syntax,first
    second=c.diag(version)
    assert all(d in second for d in first),(first,second)
    return second

def start(encoding='utf-16'):
    c=Client()
    c.send('initialize',{'capabilities':{'general':{'positionEncodings':[encoding]},'textDocument':{'publishDiagnostics':{'relatedInformation':True}}}},1)
    assert c.get()['result']['capabilities']['positionEncoding']==encoding
    c.send('initialized',{})
    return c

def units(text,encoding):
    return len(text.encode({'utf-16':'utf-16-le','utf-32':'utf-32-le'}.get(encoding,encoding)))//{'utf-8':1,'utf-16':2,'utf-32':4}[encoding]

for encoding in ('utf-8','utf-16','utf-32'):
    c=start(encoding)
    base='\ufeffdigraph {\r\n  "😀" [label=<<TABLE><TR></TABLE>>];\r}'
    c.open(base);d=merged(c,1)
    mismatch=next(x for x in d if 'closing tag' in x['message'])
    line=base.split('\r\n')[1].split('\r')[0]
    column=units(line[:line.index('</TABLE>')+2],encoding)
    assert mismatch['range']['start']=={'line':1,'character':column},(encoding,mismatch)
    assert mismatch['relatedInformation'],mismatch
    # Outer-only edits reuse the same content but must map to new coordinates.
    moved=base[:1]+'\n// shifted\n'+base[1:]
    c.change(moved,2);d2=merged(c,2)
    mismatch2=next(x for x in d2 if 'closing tag' in x['message'])
    assert mismatch2['range']['start']=={'line':3,'character':column},mismatch2
    assert mismatch2['relatedInformation'][0]['location']['range']['start']['line']==3
    # Same-length inner edit repairs the mismatch. No stale cached error survives.
    fixed=moved.replace('<TR>','<TD>').replace('</TABLE>','</TD></TABLE>')
    c.change(fixed,3);assert merged(c,3)==[]
    # Newlines inside the HTML are real content changes and must rebase too.
    broken=moved.replace('<TR>','<TR>\n')
    c.change(broken,4);d4=merged(c,4)
    assert any(x['range']['start']['line']==4 for x in d4),d4
    c.send('textDocument/didClose',{'textDocument':{'uri':'untitled:test'}});assert c.diag()==[]
    c.stop()

# Every supported label key and logical quoted/concatenated spelling.
for key in ('label','xlabel','headlabel','taillabel','"label"','"la"+"bel"','<label>'):
    c=start();c.open('digraph { a ['+key+'=<<B>bad</I>>]; }')
    assert merged(c,1),key
    c.stop()
c=start();c.open('digraph { label=<<B>x</I>>; }');assert merged(c,1);c.stop()
# Ordinary HTML-like IDs, unrelated attributes and quoted values are not labels.
c=start();c.open('digraph { <<B>x</I>> [other=<<B>x</I>>,label="<B>x</I>"]; }');assert c.diag(1)==[]
c.send('textDocument/completion',{'textDocument':{'uri':'untitled:test'},'position':{'line':0,'character':0}},50)
assert c.get().get('id')==50 # no unexpected second diagnostic publication
c.stop()
# Graphviz tag case matching; vocabulary checks are deliberately separate.
c=start();c.open('digraph { a [label=<<b>ok</B>>]; }');assert merged(c,1)==[];c.stop()
# A parser upgrade must not silently enable the deferred vocabulary rules.
for fragment in ('<TABLE><B>text</B></TABLE>', '<TABLE BORDER="nope"></TABLE>', '<B>&madeup;</B>'):
    c=start();c.open('digraph { a [label=<'+fragment+'>]; }')
    assert merged(c,1)==[],fragment
    c.stop()
# Syntax findings survive the later label publication.
c=start();c.open('digraph { a [label=<<B>x</I>>]; broken -> }');d=merged(c,1,True)
assert any('edge operator' in x['message'] for x in d),d
assert any(x['message'].startswith('HTML label:') for x in d),d
c.stop()
# Local validation and incomplete-resource notices.
for html,needle in [('<B a="x" a="y">x</B>','repeated attribute'),('<B>&broken</B>','reference'),('<B>'+('<I>'*260)+'x'+('</I>'*260)+'</B>','capacity')]:
    c=start();c.open('digraph { a [label=<'+html+'>]; }');d=merged(c,1)
    assert any(needle in x['message'] for x in d),(needle,d)
    if needle=='capacity':assert any(x['code']=='dot-ls:html-incomplete' for x in d),d
    c.stop()
# Burst edits may omit obsolete stages, but cannot publish an old version later.
c=start();large='digraph { a [label=<<B>'+('text '*500000)+'</B>>]; }'
c.open(large)
for version in range(2,7):c.change(large.replace('text','next',1),version)
c.change('digraph { a [label=<<B>final</I>>]; }',7)
last=0;seen_final=0
while seen_final<2:
    reply=c.get();assert reply.get('method')=='textDocument/publishDiagnostics',reply
    version=reply['params']['version'];assert version>=last,(last,version);last=version
    if version==7:seen_final+=1
c.stop()
# HTML errors do not prevent a valid outer DOT reference index.
c=start();c.open('digraph { a [label=<<B>x</I>>]; a -> b; }');merged(c,1)
c.send('textDocument/references',{'textDocument':{'uri':'untitled:test'},'position':{'line':0,'character':10},'context':{'includeDeclaration':True}},50)
assert len(c.get()['result'])==2
c.stop()
# More than the former 65,536 selected-label limit. The final label must be checked,
# even after an outer newline shift and exact-content cache reuse.
c=start();record='a [label=<<B>x</B>>];\n';count=70000
large='digraph {\n'+record*(count-1)+record.replace('</B>','</I>')+'}\n'
c.open(large);d=merged(c,1)
assert not any('incomplete' in str(x['code']) for x in d),d
assert any('closing tag' in x['message'] and x['range']['start']['line']==count for x in d),d
shifted=large.replace('digraph {\n','digraph {\n\n',1)
c.change(shifted,2);d=merged(c,2)
assert not any('incomplete' in str(x['code']) for x in d),d
assert any('closing tag' in x['message'] and x['range']['start']['line']==count+1 for x in d),d
c.change(shifted.replace('</I>','</B>'),3);assert merged(c,3)==[]
c.stop()
print('HTML: staged merge, selection, UTF-8/16/32, moved labels, repairs, limits, 70,000-label tail coverage and obsolete generations passed')
