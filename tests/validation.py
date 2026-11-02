#!/usr/bin/env python3
"""Editor policy: wire severity/ranges/notes, bounded work and repair."""
import lsp

def check():
    for enc in ['utf-8','utf-16','utf-32']:
        c=lsp.Client()
        c.send('initialize',{'capabilities':{'general':{'positionEncodings':[enc]},'textDocument':{'publishDiagnostics':{'relatedInformation':True}}}},1)
        assert c.get()['result']['capabilities']['positionEncoding']==enc
        c.send('initialized',{})
        source='digraph { "😀" -- b [color=red]["co"+"lor"=blue]; }'
        c.open(source);ds=c.diag(1)
        assert len(ds)==2,ds
        error=next(d for d in ds if d['severity']==1)
        warning=next(d for d in ds if d['severity']==2)
        def units(text):return len(text.encode('utf-8')) if enc=='utf-8' else len(text.encode('utf-16-le'))//2 if enc=='utf-16' else len(text)
        assert error['range']['start']=={'line':0,'character':units(source[:source.index('--')])},error
        assert error['relatedInformation'][0]['location']['range']['start']=={'line':0,'character':0},error
        assert warning['range']['start']['character']==units(source[:source.index('"co"')]),warning
        assert warning['relatedInformation'][0]['location']['range']['start']['character']==units(source[:source.index('color=')]),warning
        c.change('digraph { "😀" -> b [color=red]; }',2);assert c.diag(2)==[]
        # Reuse across statements is intentional DOT state and must not warn.
        c.change('graph { a:p -- { b:q [x=1]; }; a [x=2]; node [x=1]; node [x=2]; x=1; x=2; }',3);assert c.diag(3)==[]
        many='digraph { a ['+' '.join(f'k{i}=x' for i in range(300))+']; b [x=1 x=2]; }'
        c.change(many,4);ds=c.diag(4)
        assert sum(d['severity']==2 for d in ds)==1,ds
        assert any(d['code']=='dot-ls:validation-incomplete' for d in ds),ds
        c.change('digraph { a ['+'k'*4097+'=x]; b [x=1 x=2]; }',5);ds=c.diag(5)
        assert any(d['code']=='dot-ls:validation-incomplete' for d in ds),ds
        assert sum(d['severity']==2 for d in ds)==1,ds
        c.change('digraph { '+'a -- b; '*1200+'}',6);ds=c.diag(6)
        assert sum(d['severity']==1 for d in ds)==1000,len(ds)
        assert any(d['code']=='dot-ls:validation-incomplete' for d in ds),ds[-1]
        c.change('digraph { a -> b; }',7);assert c.diag(7)==[]
        c.stop()
    # HTML staging must preserve the new DOT findings in its merged result.
    c=lsp.Client();c.init();c.open('digraph { a -- b [label=<<B>x</I>>]; }')
    first=c.diag(1);final=c.diag(1)
    assert len([d for d in first if d['severity']==1])==1,first
    assert len([d for d in final if d['severity']==1])>1,final
    assert all(d in final for d in first),final
    c.stop()
    print('DOT policy protocol checks passed (UTF-8/16/32, limits, repair, HTML merge).')

if __name__=='__main__':check()
