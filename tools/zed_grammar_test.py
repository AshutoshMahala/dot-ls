#!/usr/bin/env python3
"""Boundary and incremental-reparse tests for the experimental private grammar.
Pass a native shared library built from its parser.c and scanner.c.
"""
import ctypes as c
import sys
import os
import ctypes.util
from pathlib import Path
class Point(c.Structure): _fields_=[('row',c.c_uint32),('column',c.c_uint32)]
class Node(c.Structure): _fields_=[('context',c.c_uint32*4),('id',c.c_void_p),('tree',c.c_void_p)]
class Edit(c.Structure): _fields_=[('start_byte',c.c_uint32),('old_end_byte',c.c_uint32),('new_end_byte',c.c_uint32),('start_point',Point),('old_end_point',Point),('new_end_point',Point)]
lib=c.CDLL(os.environ.get('TREE_SITTER_LIBRARY') or c.util.find_library('tree-sitter') or '/opt/homebrew/lib/libtree-sitter.dylib');grammar=c.CDLL(sys.argv[1]);grammar.tree_sitter_dot_ls.restype=c.c_void_p

def bind(name, args, result):
 f=getattr(lib,name);f.argtypes=args;f.restype=result;return f
new=bind('ts_parser_new',[],c.c_void_p)
setlang=bind('ts_parser_set_language',[c.c_void_p,c.c_void_p],c.c_bool)
parse=bind('ts_parser_parse_string',[c.c_void_p,c.c_void_p,c.c_char_p,c.c_uint32],c.c_void_p)
root=bind('ts_tree_root_node',[c.c_void_p],Node)
error=bind('ts_node_has_error',[Node],c.c_bool)
kind=bind('ts_node_type',[Node],c.c_char_p)
start=bind('ts_node_start_byte',[Node],c.c_uint32)
end=bind('ts_node_end_byte',[Node],c.c_uint32)
count=bind('ts_node_named_child_count',[Node],c.c_uint32)
child=bind('ts_node_named_child',[Node,c.c_uint32],Node)
edit=bind('ts_tree_edit',[c.c_void_p,c.POINTER(Edit)],None)
string=bind('ts_node_string',[Node],c.c_void_p)
delete=bind('ts_tree_delete',[c.c_void_p],None)
drop=bind('ts_parser_delete',[c.c_void_p],None)
free=c.CDLL(None).free;free.argtypes=[c.c_void_p]
p=new();assert setlang(p,grammar.tree_sitter_dot_ls())

def shape(t):
 ptr=string(root(t));s=c.string_at(ptr);free(ptr);return s

def spans(n):
 result=[]
 if kind(n)==b'html_string':result.append((start(n),end(n)))
 for i in range(count(n)):result.extend(spans(child(n,i)))
 return result

def point(s):return Point(s.count(b'\n'),len(s.rsplit(b'\n',1)[-1]))

labels=[b'<plain>',b'<>',b'<<B>alpha</B>>',b'<\n<TABLE><TR><TD>alpha</TD></TR></TABLE>\n>',
        b'<<B TITLE="a>b<c">alpha</B>>',b"<<B TITLE='a>b<c'>alpha</B>>",
        b'<<B><!-- unmatched > and < and " -->alpha</B>>',
        b'<<B><![CDATA[a > b < c]]>alpha</B>>',b'<<B>it\'s alpha</B>>',
        '<<B>α alpha</B>>'.encode()]
checks=0
for label in labels:
 s=b'digraph G { a [label='+label+b']; b [label=<<B>beta</B>>]; c [label="<B>quoted</B>"]; a -> b; }'
 t=parse(p,None,s,len(s));assert t and not error(root(t)),(label,shape(t))
 first=s.index(label);second=s.index(b'<<B>beta')
 assert spans(root(t))==[(first,first+len(label)),(second,second+len(b'<<B>beta</B>>'))],(label,spans(root(t)))
 # Reparse changed body bytes, shifted ranges and a shifted line start.
 for inserted in [b'X',b'\n',b'\xce\xb1']:
  # Insert at the first inner text location when present, otherwise in graph ID.
  at=s.find(b'alpha');at=at if at>=0 else s.index(b'G')
  changed=s[:at]+inserted+s[at:]
  old=parse(p,None,s,len(s))
  e=Edit(at,at,at+len(inserted),point(s[:at]),point(s[:at]),point(changed[:at+len(inserted)]))
  edit(old,c.byref(e));incremental=parse(p,old,changed,len(changed));fresh=parse(p,None,changed,len(changed))
  assert not error(root(fresh)) and shape(incremental)==shape(fresh),(label,inserted)
  assert spans(root(incremental))==spans(root(fresh))
  for tree in [old,incremental,fresh]:delete(tree)
  checks+=1
 delete(t);checks+=1
for s in [b'digraph { a [label=<<B>alpha</B>]; }', b'digraph { a [label=<<B X="oops>alpha</B>>]; }', b'digraph { a [label=<<!--oops]; }']:
 t=parse(p,None,s,len(s));assert t and error(root(t));delete(t);checks+=1
# A quoted value must not create an HTML injection.
s=b'digraph { a [label="<B>alpha</B>"]; }';t=parse(p,None,s,len(s));assert not error(root(t)) and spans(root(t))==[];delete(t);checks+=1
# Error recovery must not let the external token consume unrelated DOT text.
valid=b'digraph G { a [label=<<B>alpha</B>>]; b; }'
for broken,at,old_len,inserted in [(b'x'+valid,0,1,b''),(valid[:-1],len(valid)-1,0,b'}')]:
 old=parse(p,None,broken,len(broken));assert error(root(old))
 repaired=broken[:at]+inserted+broken[at+old_len:]
 e=Edit(at,at+old_len,at+len(inserted),point(broken[:at]),point(broken[:at+old_len]),point(repaired[:at+len(inserted)]))
 edit(old,c.byref(e));incremental=parse(p,old,repaired,len(repaired));fresh=parse(p,None,repaired,len(repaired))
 assert not error(root(incremental)) and shape(incremental)==shape(fresh)
 for tree in [old,incremental,fresh]:delete(tree)
 checks+=1
# Every existing DOT editor query must compile against the private node schema.
query_new=bind('ts_query_new',[c.c_void_p,c.c_char_p,c.c_uint32,c.POINTER(c.c_uint32),c.POINTER(c.c_int)],c.c_void_p)
query_delete=bind('ts_query_delete',[c.c_void_p],None)
for path in (Path(__file__).resolve().parents[1]/'editors/zed/languages/dot').glob('*.scm'):
 data=path.read_bytes();offset=c.c_uint32();failure=c.c_int()
 q=query_new(grammar.tree_sitter_dot_ls(),data,len(data),c.byref(offset),c.byref(failure))
 assert q,(path,offset.value,failure.value)
 query_delete(q);checks+=1
drop(p)
print(f'{checks} boundary, recovery and incremental checks passed')
