#!/usr/bin/env python3
"""Measure the large-single-label tradeoff in a native Tree-sitter parser.
Not an editor benchmark; excludes the injected HTML grammar and all UI work.
"""
import argparse
import ctypes as c
import ctypes.util
import json
import os
import statistics
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('grammar_library')
p.add_argument('--symbol', default='tree_sitter_dot_ls')
p.add_argument('--runtime', default=os.environ.get('TREE_SITTER_LIBRARY') or c.util.find_library('tree-sitter') or '/opt/homebrew/lib/libtree-sitter.dylib')
a = p.parse_args()
lib = c.CDLL(a.runtime)
grammar = c.CDLL(a.grammar_library)
getlang = getattr(grammar, a.symbol)
getlang.restype = c.c_void_p
class Point(c.Structure):
    _fields_ = [('row', c.c_uint32), ('column', c.c_uint32)]
class Edit(c.Structure):
    _fields_ = [('start_byte', c.c_uint32), ('old_end_byte', c.c_uint32), ('new_end_byte', c.c_uint32), ('start_point', Point), ('old_end_point', Point), ('new_end_point', Point)]
class Node(c.Structure):
    _fields_ = [('context', c.c_uint32 * 4), ('id', c.c_void_p), ('tree', c.c_void_p)]
def bind(name, args, result):
    fn = getattr(lib, name); fn.argtypes = args; fn.restype = result; return fn
new = bind('ts_parser_new', [], c.c_void_p)
setlang = bind('ts_parser_set_language', [c.c_void_p, c.c_void_p], c.c_bool)
parse = bind('ts_parser_parse_string', [c.c_void_p, c.c_void_p, c.c_char_p, c.c_uint32], c.c_void_p)
root = bind('ts_tree_root_node', [c.c_void_p], Node)
error = bind('ts_node_has_error', [Node], c.c_bool)
edit = bind('ts_tree_edit', [c.c_void_p, c.POINTER(Edit)], None)
delete = bind('ts_tree_delete', [c.c_void_p], None)
drop = bind('ts_parser_delete', [c.c_void_p], None)
rows = []
for mb in [1, 5]:
    source = b'digraph { a [label=<' + b'<B>alpha</B>\n' * (mb * 1_000_000 // 13) + b'>]; }'
    at = source.index(b'alpha')
    changed = source[:at] + b'x' + source[at:]
    timings = []
    for _ in range(3):
        parser = new(); assert setlang(parser, getlang())
        old = parse(parser, None, source, len(source)); assert old and not error(root(old))
        e = Edit(at, at, at + 1, Point(0, at), Point(0, at), Point(0, at + 1))
        edit(old, c.byref(e))
        start = time.perf_counter()
        tree = parse(parser, old, changed, len(changed))
        timings.append(time.perf_counter() - start)
        assert tree and not error(root(tree))
        delete(old); delete(tree); drop(parser)
    rows.append({'symbol': a.symbol, 'source_bytes': len(source), 'incremental_seconds': timings, 'median_seconds': statistics.median(timings)})
print(json.dumps(rows, indent=2))
