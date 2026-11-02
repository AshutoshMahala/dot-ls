#!/usr/bin/env python3
"""Capture read-only macOS allocation reports for an isolated benchmark PID."""
import json
from pathlib import Path
import subprocess
import sys
import time
ROOT = Path(__file__).resolve().parents[1] / 'bench/results/zed-grammar-study'
ROOT.mkdir(parents=True,exist_ok=True)
pid = int(sys.argv[1])
label = sys.argv[2]
if not label.replace('-', '').replace('_', '').isalnum():
    raise SystemExit('Use a simple report label')
for name, args in [('vmmap', ['vmmap', '-summary', str(pid)]),
                   ('heap', ['heap', '-s', str(pid)])]:
    with (ROOT / f'{label}-{name}.txt').open('w') as out:
        r = subprocess.run(args, stdout=out, stderr=subprocess.STDOUT, timeout=60)
    print(json.dumps({'report': name, 'returncode': r.returncode, 'label': label}))
if '--stacks' in sys.argv:
    with (ROOT / f'{label}-stacks.txt').open('w') as out:
        r = subprocess.run(['malloc_history', str(pid), '-callTree', '-ignoreThreads', '-collapseRecursion', '-noContent'], stdout=out, stderr=subprocess.STDOUT, timeout=60)
    print(json.dumps({'report': 'stacks', 'returncode': r.returncode, 'label': label}))
