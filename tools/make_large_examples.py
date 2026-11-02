#!/usr/bin/env python3
"""Write the large editor test files into examples/. They are not kept in Git.

Each file is a header, numbered edges and a closing brace. The output bytes and
SHA-256 values match the fixtures used by earlier benchmark results.
"""
import argparse
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRY = '// Try opening, scrolling, searching, and editing this file.'
REPAIR = '// Add an incomplete edge to test diagnostics, then repair it.'
# Size in MB: header lines, edge count, padding line or None, SHA-256.
FIXTURES = {
    5: ([TRY, REPAIR], 102036, '//', '4f2b56910505c3bb5e2718309b6a7f67f0dd0e288ed247da8353c516c6b8994b'),
    20: ([TRY, REPAIR], 408159, None, '9d6cca7a445566cb869d027615658373693fad7e53ba1e744d00f58bc266cd40'),
    40: ([TRY, REPAIR], 816322, '//' + ' ' * 31, '60b6ab188f25b09d7e728533aad6ed2d467299aaca94ab23aeb1c25aa2f7b415'),
    100: ([TRY, '// Fits the current dotls 200 MiB source and 256 MiB message limits.',
           '// Use this file to test editor and dotls responsiveness.'], 2040810, None,
           '6b99804e5220050acf738360b952771df8b68f2ab080578b493dd97240faaa7d'),
}


def write(mb, path):
    lines, edges, padding, expected = FIXTURES[mb]
    digest = hashlib.sha256()
    with path.open('wb') as out:
        def put(data):
            out.write(data); digest.update(data)
        put((f'// {mb} MB editor test: {mb * 1_000_000:,} bytes.\n' + ''.join(l + '\n' for l in lines)
             + 'digraph editor_test {\n').encode())
        for start in range(0, edges, 10_000):
            put(''.join(f'    n{i:07d} -> n{i + 1:07d} [label="edge {i:07d}"];\n'
                        for i in range(start, min(start + 10_000, edges))).encode())
        put(((padding + '\n') if padding is not None else '').encode() + b'}\n')
    actual = digest.hexdigest()
    assert actual == expected, f'{path.name}: unexpected SHA-256 {actual}'
    return actual


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sizes', nargs='+', type=int, choices=sorted(FIXTURES), default=sorted(FIXTURES))
    p.add_argument('--output', type=Path, default=ROOT / 'examples')
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=True)
    for mb in a.sizes:
        path = a.output / f'editor-{mb}mb.dot'
        print(write(mb, path), path, flush=True)


if __name__ == '__main__':
    main()
