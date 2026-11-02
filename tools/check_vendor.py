#!/usr/bin/env python3
"""Verify pinned upstream bytes, reversing any declared local patches first."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    manifest = json.loads((ROOT / 'vendor/upstream.json').read_text())
    patches = ROOT / 'vendor/patches'
    actual_patches = {p.name for p in patches.iterdir()} if patches.exists() else set()
    assert actual_patches == set(manifest['patches']), 'Undeclared patch file'
    with tempfile.TemporaryDirectory(prefix='dot-ls-vendor-') as temporary:
        restored = Path(temporary) / 'parser'
        shutil.copytree(ROOT / 'vendor/dot-parser', restored)
        for name in reversed(manifest['patches']):
            patch = patches / name
            # Only dependency-relative paths are allowed in these local patches.
            for line in patch.read_text().splitlines():
                if line.startswith(('--- ', '+++ ')):
                    path = line[4:].split('\t')[0]
                    assert path == '/dev/null' or (path.startswith(('a/', 'b/')) and '..' not in Path(path).parts), path
            result = subprocess.run(['patch', '--batch', '--reverse', '-p1', '-i', str(patch)], cwd=restored, text=True, capture_output=True)
            assert result.returncode == 0, result.stdout + result.stderr
        actual = {str(p.relative_to(restored)): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in restored.rglob('*') if p.is_file()}
        assert actual == manifest['files'], 'Vendored source differs from the declared upstream plus patches'
    print(f"Vendor checks passed: {manifest['commit'][:8]}, {len(manifest['patches'])} patches, exact upstream bytes restored.")


if __name__ == '__main__':
    main()
