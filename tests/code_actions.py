#!/usr/bin/env python3
"""Parser fixes through LSP: apply, recheck, encodings and stale generations."""
import lsp

def init(c,enc='utf-16',versioned=True):
    c.send('initialize',{'capabilities':{'general':{'positionEncodings':[enc]},'workspace':{'workspaceEdit':{'documentChanges':versioned}},'textDocument':{'publishDiagnostics':{'relatedInformation':True,'dataSupport':True},'codeAction':{'codeActionLiteralSupport':{'codeActionKind':{'valueSet':['quickfix']}}}}}},1)
    reply=c.get();assert reply['result']['capabilities']['codeActionProvider']['codeActionKinds']==['quickfix'],reply
    c.send('initialized',{})

def request(c,diagnostics,range=None,only=None,uri='untitled:test',ident=12):
    ctx={'diagnostics':diagnostics}
    if only is not None:ctx['only']=only
    c.send('textDocument/codeAction',{'textDocument':{'uri':uri},'range':range or {'start':{'line':0,'character':0},'end':{'line':999999,'character':0}},'context':ctx},ident)
    reply=c.get();assert reply['id']==ident,reply
    return reply

def offset(text,p,enc):
    # Handles CRLF and lone CR through splitlines(keepends=True).
    lines=text.splitlines(keepends=True)
    if p['line']==len(lines):return len(text)
    start=sum(map(len,lines[:p['line']]))
    if enc=='utf-32':return start+p['character']
    codec='utf-8' if enc=='utf-8' else 'utf-16-le'
    width=1 if enc=='utf-8' else 2
    return start+len(lines[p['line']].encode(codec)[:p['character']*width].decode(codec))

def apply(text,action,enc,version=1):
    changes=action['edit']['documentChanges'];assert len(changes)==1,action
    assert changes[0]['textDocument']=={'uri':'untitled:test','version':version},action
    edits=[(offset(text,e['range']['start'],enc),offset(text,e['range']['end'],enc),e['newText']) for e in changes[0]['edits']]
    for start,end,replacement in sorted(edits,reverse=True):text=text[:start]+replacement+text[end:]
    return text

def checks():
    cases=[
        ('graph { a -> b; }',"Replace with '--'"),
        ('digraph { a -- b; }',"Replace with '->'"),
        ('digraph { a [color=red }',"Insert closing ']'"),
        ('digraph { a -> b;',"Insert closing '}'"),
        ('digraph { a [color red]; }',"Insert '='"),
        ('digraph { a -> node; }','Put double quotes around this name'),
        ('digraph { ; a -> b; }','Remove unexpected text'),
        ('diagraph { a -> b; }',"Replace with 'digraph'"),
    ]
    for enc in ['utf-8','utf-16','utf-32']:
        for source,title in cases:
            # Multibyte text and mixed line endings precede all edited positions.
            source='// 😀 é\r\n'+source
            c=lsp.Client();init(c,enc);c.open(source);ds=c.diag(1)
            actions=request(c,ds)['result']
            chosen=[a for a in actions if a['title']==title]
            assert len(chosen)==1,(source,title,ds,actions)
            repaired=apply(source,chosen[0],enc)
            c.change(repaired,2);new=c.diag(2)
            assert new==[],(source,repaired,new)
            stale=request(c,ds)
            assert stale['error']['code']==-32801,stale
            c.stop()
    # HTML fix ranges are fragment-local in the parser; LSP must rebase them.
    for enc in ['utf-8','utf-16','utf-32']:
        c=lsp.Client();init(c,enc)
        source='digraph {\r\n "😀" [label=<\n<B>&amp</B>\n>];\r}'
        c.open(source);assert c.diag(1)==[];ds=c.diag(1)
        result=request(c,ds)['result'];assert len(result)==1,(ds,result)
        assert result[0]['title']=="Insert ';'",result
        repaired=apply(source,result[0],enc)
        c.change(repaired,2);assert c.diag(2)==[];assert c.diag(2)==[]
        c.stop()
    c=lsp.Client();init(c);source='digraph { a -- b; }';c.open(source);ds=c.diag(1)
    assert request(c,ds,only=['source.fixAll'])['result']==[]
    assert request(c,ds,only=[])['result']==[]
    assert request(c,ds,only=['quickfix']*65)['error']['code']==-32602
    assert request(c,ds*1025)['error']['code']==-32602
    assert len(request(c,ds,only=['quickfix'])['result'])==1
    assert request(c,ds,range={'start':{'line':0,'character':0},'end':{'line':0,'character':3}})['result']==[]
    assert request(c,ds,range={'start':{'line':-1,'character':0},'end':{'line':0,'character':0}})['error']['code']==-32602
    assert request(c,ds,uri='untitled:missing')['error']['code']==-32602
    c.send('textDocument/didClose',{'textDocument':{'uri':'untitled:test'}});assert c.diag()==[]
    c.open(source);c.diag(1)
    assert request(c,ds)['error']['code']==-32801 # Same version, different incarnation.
    c.stop()
    c=lsp.Client();init(c,versioned=False);c.open(source);ds=c.diag(1)
    assert request(c,ds)['result']==[] # No unsafe unversioned fallback.
    c.stop()
    print('Code actions: parser edits apply cleanly; UTF-8/16/32, HTML rebase, filters, stale generations and versioned edits passed.')

if __name__=='__main__':checks()
