#!/usr/bin/env python3
"""Build the portable experimental DOT grammar with a WASI SDK clang.
The customer receives the resulting WebAssembly grammar, not these build tools.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

PROJECT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--clang', required=True, help='WASI SDK bin/clang (not the host compiler)')
p.add_argument('--output', type=Path, required=True)
p.add_argument('--regenerate', help='Optional pinned Tree-sitter 0.27.1 executable')
a=p.parse_args()
grammar=PROJECT/'editors/experiments/compact-dot'
if a.regenerate:
 version=subprocess.check_output([a.regenerate,'--version'],text=True)
 if not version.startswith('tree-sitter 0.27.1'):
  raise SystemExit('Use Tree-sitter CLI 0.27.1 to regenerate the checked-in sources')
 subprocess.run([a.regenerate,'generate','--abi','14'],cwd=grammar,check=True)
a.output.parent.mkdir(parents=True,exist_ok=True)
subprocess.run([a.clang,'-fPIC','-shared','-Os','-Wl,--export=tree_sitter_dot_ls',
                '-I',str(grammar/'src'),str(grammar/'src/parser.c'),
                str(grammar/'src/scanner.c'),'-o',str(a.output)],check=True)
data=a.output.read_bytes()
if data[:4]!=b'\0asm':raise SystemExit('Compiler did not produce WebAssembly; use WASI SDK clang')
print(json.dumps({'grammar':'dot_ls','abi':14,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}))
