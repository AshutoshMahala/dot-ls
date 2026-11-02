#!/usr/bin/env python3
"""Check project layout and local documentation links without building the server."""
import ast
from pathlib import Path
import re
import sys
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
DOCS = {'README.md', 'ARCHITECTURE.md', 'REQUIREMENTS.md', 'FEATURES.md',
        'DEVELOPMENT.md', 'PERFORMANCE.md'}
issues = []
actual = {p.name for p in (ROOT / 'docs').iterdir() if p.name != '.DS_Store'}
if actual != DOCS:
    issues.append(f'docs/: expected only authoritative files; missing={sorted(DOCS-actual)}, extra={sorted(actual-DOCS)}')

markdown = [ROOT / 'README.md', ROOT / 'AGENTS.md', ROOT / 'tools/README.md']
markdown += list((ROOT / 'docs').glob('*.md'))
markdown += list((ROOT / 'bench').glob('*.md'))
markdown += list((ROOT / 'bench/reports').glob('*.md'))
markdown += list((ROOT / 'bench/history').glob('*.md'))
markdown += [ROOT / 'editors/zed/README.md', ROOT / 'editors/experiments/compact-dot/README.md']
for source in markdown:
    if not source.exists():
        issues.append(f'missing documentation: {source.relative_to(ROOT)}')
        continue
    for match in re.finditer(r'\]\(([^\s)]+)\)', source.read_text()):
        target = match.group(1)
        if re.match(r'^[a-zA-Z][\w+.-]*:|^#', target):
            continue
        target = unquote(target.split('#', 1)[0].strip('<>'))
        resolved = (source.parent / target).resolve()
        if not resolved.is_relative_to(ROOT):
            issues.append(f'{source.relative_to(ROOT)}: local link leaves project: {target}')
        elif not resolved.exists():
            issues.append(f'{source.relative_to(ROOT)}: missing link target: {target}')

for source in (ROOT / 'tools').glob('*.py'):
    try:
        ast.parse(source.read_text(), filename=str(source))
    except SyntaxError as exc:
        issues.append(str(exc))
    if source.name != 'check_layout.py' and re.search(r"['\"]docs(?:/|['\"]\s*/)", source.read_text()):
        issues.append(f'{source.relative_to(ROOT)}: tool output/reference still points into docs/')

external = {'std', 'dot_parser', 'markup_parser', 'build_options'}
for source in (ROOT / 'src').rglob('*.zig'):
    for target in re.findall(r'@import\("([^\"]+)"\)', source.read_text()):
        if target in external:
            continue
        resolved = (source.parent / target).resolve()
        if not resolved.is_relative_to(ROOT / 'src') or not resolved.is_file():
            issues.append(f'{source.relative_to(ROOT)}: invalid local source import: {target}')
        elif source == ROOT / 'src/app.zig' and not any(resolved.is_relative_to(ROOT / 'src' / layer) for layer in ('runtime', 'protocol', 'text')):
            issues.append(f'{source.relative_to(ROOT)}: application bypasses runtime/protocol boundaries: {target}')
        elif source.is_relative_to(ROOT / 'src/text') and not resolved.is_relative_to(ROOT / 'src/text'):
            issues.append(f'{source.relative_to(ROOT)}: shared text imports a higher layer: {target}')
        elif source == ROOT / 'src/analysis/pipeline.zig' and not any(resolved.is_relative_to(ROOT / 'src' / layer) for layer in ('analysis', 'features', 'text')):
            issues.append(f'{source.relative_to(ROOT)}: pipeline imports runtime/protocol/application state: {target}')
        elif source.is_relative_to(ROOT / 'src/analysis') and not any(resolved.is_relative_to(ROOT / 'src' / layer) for layer in ('analysis', 'features', 'text')):
            issues.append(f'{source.relative_to(ROOT)}: analysis imports a higher layer: {target}')
        elif source.is_relative_to(ROOT / 'src/runtime') and not any(resolved.is_relative_to(ROOT / 'src' / layer) for layer in ('runtime', 'analysis', 'features', 'text')):
            issues.append(f'{source.relative_to(ROOT)}: runtime imports protocol/application state: {target}')
        elif source.is_relative_to(ROOT / 'src/protocol') and not (resolved.is_relative_to(ROOT / 'src/protocol') or resolved.is_relative_to(ROOT / 'src/features') or resolved.is_relative_to(ROOT / 'src/text') or resolved == ROOT / 'src/analysis/diagnostic_text.zig'):
            issues.append(f'{source.relative_to(ROOT)}: protocol imports application/runtime state: {target}')
        elif source == ROOT / 'src/main.zig' and resolved != ROOT / 'src/app.zig':
            issues.append(f'{source.relative_to(ROOT)}: production entry must use the application boundary: {target}')
        elif source.is_relative_to(ROOT / 'src/features') and not (resolved.is_relative_to(ROOT / 'src/features') or resolved.is_relative_to(ROOT / 'src/text')):
            issues.append(f'{source.relative_to(ROOT)}: feature imports a higher layer: {target}')
        elif source == ROOT / 'src/main.zig' and (resolved == ROOT / 'src/tests.zig' or resolved.is_relative_to(ROOT / 'src/tests')):
            issues.append(f'{source.relative_to(ROOT)}: production entry imports test modules: {target}')
        elif source.name == 'outline.zig' and resolved.name == 'completion_context.zig':
            issues.append(f'{source.relative_to(ROOT)}: outline must use shared text coordinates: {target}')

# Audit the whole source graph, not only folder direction. Test imports count too.
graph = {}
for source in (ROOT / 'src').rglob('*.zig'):
    graph[source.resolve()] = [(source.parent / name).resolve() for name in re.findall(r'@import\("([^\"]+)"\)', source.read_text()) if name not in external]
visiting, visited = set(), set()
def visit(source, chain):
    if source in visiting:
        issues.append('source import cycle: ' + ' -> '.join(str(p.relative_to(ROOT)) for p in chain + [source]))
        return
    if source in visited: return
    visiting.add(source)
    for target in graph.get(source, []): visit(target, chain + [source])
    visiting.remove(source)
    visited.add(source)
for source in graph: visit(source, [])
app_source = (ROOT / 'src/app.zig').read_text().split('\ntest \"', 1)[0]
if re.search(r'\.state\.(documents|active|generation|source_bytes|index_bytes|context_bytes|outline_bytes|html_cache_bytes)\b', app_source):
    issues.append('src/app.zig: application accesses mutable document/accounting fields instead of runtime operations')

if issues:
    print('\n'.join(issues), file=sys.stderr)
    raise SystemExit(1)
print(f'Layout checks passed: {len(DOCS)} authoritative docs, local links, tool syntax/outputs and source imports.')
