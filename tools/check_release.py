#!/usr/bin/env python3
"""Verify local archives and run native protocol suites after clean extraction."""
import argparse
import json
from pathlib import Path
import platform
import struct
import subprocess
import sys
import tarfile
import tempfile
import package_release as package


def contents(path):
    files = {}
    with tarfile.open(path, 'r:gz') as archive:
        for member in archive.getmembers():
            assert member.isfile() and not member.name.startswith('/') and '..' not in Path(member.name).parts, member.name
            assert member.name not in files, member.name
            files[member.name] = (archive.extractfile(member).read(), member.mode)
    return files


def native_header(data, target):
    if target.endswith('macos'):
        assert data[:4] == b'\xcf\xfa\xed\xfe'
        assert struct.unpack_from('<I', data, 4)[0] == (0x100000c if target.startswith('aarch64') else 0x1000007)
        assert struct.unpack_from('<I', data, 12)[0] == 2, 'Not a Mach-O executable'
        offset = 32
        for _ in range(struct.unpack_from('<I', data, 16)[0]):
            cmd, size = struct.unpack_from('<II', data, offset)
            assert size >= 8
            if cmd in (12, 0x80000018, 0x8000001f):
                name_offset = struct.unpack_from('<I', data, offset+8)[0]
                name = data[offset+name_offset:offset+size].split(b'\0', 1)[0]
                assert name.startswith((b'/usr/lib/', b'/System/Library/')), name
            assert cmd != 0x8000001c, 'Unexpected runtime library search path'
            offset += size
    else:
        assert data[:6] == b'\x7fELF\x02\x01'
        assert struct.unpack_from('<H', data, 18)[0] == (183 if target.startswith('aarch64') else 62)
        at = struct.unpack_from('<Q', data, 32)[0]
        width, count = struct.unpack_from('<HH', data, 54)
        assert all(struct.unpack_from('<I', data, at+i*width)[0] != 3 for i in range(count)), 'Linux binary requires a dynamic interpreter'


def extract(files, destination):
    for name, (data, mode) in files.items():
        path = destination/name; path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data); path.chmod(mode)


def host_target():
    arch = {'arm64': 'aarch64', 'aarch64': 'aarch64', 'x86_64': 'x86_64', 'AMD64': 'x86_64'}.get(platform.machine())
    os = {'Darwin': 'macos', 'Linux': 'linux-musl'}.get(platform.system())
    return f'{arch}-{os}'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('directory', type=Path)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--runtime', action='store_true', help='Run all protocol suites on the matching host archive')
    a = p.parse_args(); rows = []; version = (package.ROOT/'VERSION').read_text().strip()
    sums = {line.split('  ', 1)[1]: line.split('  ', 1)[0] for line in (a.directory/'SHA256SUMS').read_text().splitlines()}
    assert set(sums) == {p.name for p in a.directory.glob('*.tar.gz')}, 'Missing/extra checksum entry'
    for name, sha in sums.items():
        path = a.directory/name
        assert package.digest(path.read_bytes()) == sha, name
        files = contents(path)
        assert {'LICENSE-MIT', 'LICENSE-APACHE', 'THIRD-PARTY-NOTICES.txt', 'RELEASE.json'} <= files.keys()
        metadata = json.loads(files['RELEASE.json'][0]); assert metadata['version'] == version
        row = {'archive': name, 'sha256': sha, 'archive_bytes': path.stat().st_size,
               'files': len(files), 'runtime_tested': False}
        if 'dot-ls' in files:
            target = metadata['target']; native_header(files['dot-ls'][0], target)
            assert name == f'dot-ls-{version}-{target}.tar.gz'
            assert files['dot-ls'][1] == 0o755
            assert package.digest(files['dot-ls'][0]) == metadata['binary_sha256']
            assert str(package.ROOT).encode() not in files['dot-ls'][0], 'Development checkout path embedded in binary'
            assert 'licenses/dot-parser/UNICODE_LICENSE.txt' in files and 'licenses/zig/LICENSE' in files
            if a.runtime and target == host_target():
                with tempfile.TemporaryDirectory(prefix='dot-ls-clean-install-') as temporary:
                    clean = Path(temporary); extract(files, clean/'package')
                    binary = clean/'package/dot-ls'
                    env = {'PATH': '/usr/bin:/bin', 'TMPDIR': temporary,
                           'PYTHONNOUSERSITE': '1', 'PYTHONDONTWRITEBYTECODE': '1'}
                    actual = subprocess.check_output([str(binary), '--version'], env=env, cwd=clean, text=True).strip()
                    assert actual.startswith('dot-ls '+version+';'), actual
                    row['version_output'] = actual; row['suites'] = []
                    for suite in ['lsp', 'protocol', 'validation', 'completion', 'attributes', 'references', 'html', 'code_actions', 'outline', 'output', 'templates']:
                        run = subprocess.run([sys.executable, str(package.ROOT/f'tests/{suite}.py'), str(binary)],
                                             cwd=clean, env=env, capture_output=True, text=True, timeout=90)
                        row['suites'].append({'name': suite, 'exit_code': run.returncode, 'output': run.stdout+run.stderr})
                        assert run.returncode == 0, row['suites'][-1]
                    row['runtime_tested'] = True
        else:
            assert files['extension.wasm'][0].startswith(b'\0asm')
            assert package.digest(files['extension.wasm'][0]) == metadata['wasm_sha256']
            for grammar in ['dot', 'html']:
                assert files[f'grammars/{grammar}.wasm'][0][:8] == b'\0asm\x01\0\0\0'
                assert f'licenses/tree-sitter-{grammar}/LICENSE' in files
            assert 'Cargo.toml' not in files and not any(n.startswith(('src/', '.cargo/', 'target/')) for n in files)
            assert json.loads(files['DEPENDENCIES.json'][0])
        rows.append(row); print(name, 'passed', flush=True)
    if a.runtime: assert any(row['runtime_tested'] for row in rows), 'No matching host archive tested'
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(json.dumps({'host': host_target(), 'passed': True, 'archives': rows}, indent=2)+'\n')


if __name__ == '__main__':
    main()
