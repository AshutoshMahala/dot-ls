#!/usr/bin/env python3
"""Build release archives. Never creates tags, repositories or uploads.

Python 3.9+, Zig 0.17.0. Optional Zed packaging also needs Rust/rustup,
wasm32-wasip2, Git and a WASI SDK clang. Consumers need none of these tools.
"""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TARGETS = ['aarch64-macos', 'x86_64-macos', 'aarch64-linux-musl', 'x86_64-linux-musl']
GRAMMARS = {
    'dot': ('https://github.com/rydesun/tree-sitter-dot', '9ab85550c896d8b294d9b9ca1e30698736f08cea'),
    'html': ('https://github.com/tree-sitter/tree-sitter-html', 'bfa075d83c6b97cd48440b3829ab8d24a2319809'),
}


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def output(args, **kwargs):
    return subprocess.check_output([str(a) for a in args], text=True, **kwargs).strip()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def archive(path, files):
    """Flat, deterministic payload. No links, machine paths, timestamps or owners."""
    with path.open('wb') as raw, gzip.GzipFile(filename='', fileobj=raw, mode='wb', mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode='w') as tar:
            for name, (data, mode) in sorted(files.items()):
                assert not Path(name).is_absolute() and '..' not in Path(name).parts
                item = tarfile.TarInfo(name)
                item.size = len(data); item.mode = mode; item.mtime = 0
                tar.addfile(item, io.BytesIO(data))


def add(files, name, path, mode=0o644):
    files[name] = (Path(path).read_bytes(), mode)


def common():
    return {name: ((ROOT/name).read_bytes(), 0o644) for name in ['LICENSE-MIT', 'LICENSE-APACHE']}


def version_checks(version):
    assert re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?', version), 'Invalid VERSION'
    for relative, pattern in [
        ('build.zig.zon', r'\.version = "([^"]+)"'),
        ('editors/zed/Cargo.toml', r'^version = "([^"]+)"'),
        ('editors/zed/extension.toml', r'^version = "([^"]+)"'),
        ('editors/zed/src/resolver.rs', r'pub const VERSION: &str = "([^"]+)"'),
    ]:
        match = re.search(pattern, (ROOT/relative).read_text(), re.M)
        assert match and match[1] == version, f'Version mismatch in {relative}'


def native(a, version, target):
    with tempfile.TemporaryDirectory(prefix='dot-ls-package-') as temporary:
        prefix = Path(temporary)/'install'
        # Pin the deployment floor instead of inheriting a future compiler default.
        build_target = target+'.15.0' if target.endswith('macos') else target
        command = [a.zig, 'build', '-Doptimize=safe', '-Dstrip=true', '-Dcpu=baseline',
                   f'-Dversion={version}', f'-Dtarget={build_target}', '--prefix', prefix]
        if a.cache_dir:
            command += ['--cache-dir', a.cache_dir]
        run(command, cwd=ROOT)
        files = common()
        data = (prefix/'bin/dot-ls').read_bytes()
        files['dot-ls'] = (data, 0o755)
        for name in ['LICENSE-MIT', 'LICENSE-APACHE', 'src/string/UNICODE_LICENSE.txt']:
            add(files, 'licenses/dot-parser/'+Path(name).name, ROOT/'vendor/dot-parser'/name)
        add(files, 'licenses/dot-parser/upstream.json', ROOT/'vendor/upstream.json')
        for name in json.loads((ROOT/'vendor/upstream.json').read_text())['patches']:
            patch = ROOT/'vendor/patches'/name
            add(files, 'licenses/dot-parser/'+patch.name, patch)
        zig = Path(shutil.which(a.zig) or a.zig).resolve()
        license_path = next((p for p in [zig.parent/'LICENSE', zig.parent.parent/'LICENSE'] if p.is_file()), None)
        assert license_path, 'Cannot locate Zig license beside the compiler'
        add(files, 'licenses/zig/LICENSE', license_path)
        files['THIRD-PARTY-NOTICES.txt'] = (b'dot-ls: MIT OR Apache-2.0.\n'
            b'dot-parser: MIT OR Apache-2.0. See licenses/dot-parser/upstream.json for the pin and any declared patches.\n'
            b'Unicode data and Zig standard/compiler runtime notices are included under licenses/.\n', 0o644)
        metadata = {'version': version, 'target': target, 'zig': '0.17.0', 'optimize': 'safe',
                    'cpu': 'baseline', 'build_target': build_target, 'stripped': True, 'binary_sha256': digest(data),
                    'parser': json.loads((ROOT/'vendor/upstream.json').read_text())['commit']}
        files['RELEASE.json'] = ((json.dumps(metadata, indent=2)+'\n').encode(), 0o644)
        files['README.txt'] = (f'dot-ls {version} ({target})\n\n'
            'dot-ls is a language server for Graphviz DOT files.\n'
            'Put dot-ls on your PATH, or set your editor to its full path.\n'
            'Start it with the argument lsp. It uses standard input and output and opens no network port.\n'
            'It does not need Zig, Rust, Graphviz or a project checkout.\n'
            'macOS builds are not signed with an Apple Developer ID and are not notarized.\n'
            'Setup guide: https://github.com/AshutoshMahala/dot-ls\n').encode(), 0o644
        path = a.output/f'dot-ls-{version}-{target}.tar.gz'
        archive(path, files)
        print(path, flush=True)


def extension(a, version):
    assert a.wasi_clang, '--zed requires --wasi-clang /path/to/wasi-sdk/bin/clang'
    with tempfile.TemporaryDirectory(prefix='dot-ls-zed-package-') as temporary:
        stage = Path(temporary)
        # Use the installed rustup toolchain, not a machine-specific Cargo config.
        cargo = output(['rustup', 'which', 'cargo'])
        rustc = output(['rustup', 'which', 'rustc'])
        import os
        env = dict(os.environ, RUSTC=rustc)
        manifest = ROOT/'editors/zed/Cargo.toml'
        run([cargo, 'build', '--locked', '--release', '--target', 'wasm32-wasip2',
             '--target-dir', stage/'cargo', '--manifest-path', manifest], cwd=ROOT, env=env)
        files = common()
        wasm = stage/'cargo/wasm32-wasip2/release/dotls_zed.wasm'
        assert wasm.read_bytes().startswith(b'\0asm')
        add(files, 'extension.wasm', wasm)
        for f in sorted((ROOT/'editors/zed/languages').rglob('*')):
            if f.is_file(): add(files, str(f.relative_to(ROOT/'editors/zed')), f)
        add(files, 'extension.toml', ROOT/'editors/zed/extension.toml')
        notices = ['dot-ls Zed adapter: MIT OR Apache-2.0.', 'Compiled Rust dependencies and standard library notices are included under licenses/.']
        for name, (url, rev) in GRAMMARS.items():
            checkout = a.grammar_cache/name
            if not checkout.exists():
                run(['git', 'clone', '--no-checkout', url, checkout])
            source = stage/name
            tracked = output(['git', '-C', checkout, 'ls-tree', '-r', '--name-only', rev]).splitlines()
            for f in tracked:
                if f == 'LICENSE' or (f.startswith('src/') and f.endswith(('.c', '.h'))):
                    dest = source/f; dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.write_bytes(subprocess.check_output(['git', '-C', str(checkout), 'show', f'{rev}:{f}']))
            sources = [source/'src/parser.c']
            if (source/'src/scanner.c').exists(): sources.append(source/'src/scanner.c')
            dest = stage/f'{name}.wasm'
            run([a.wasi_clang, '-fPIC', '-shared', '-Os', f'-Wl,--export=tree_sitter_{name}',
                 '-I', source/'src', *sources, '-o', dest])
            assert dest.read_bytes().startswith(b'\0asm')
            add(files, f'grammars/{name}.wasm', dest)
            add(files, f'licenses/tree-sitter-{name}/LICENSE', source/'LICENSE')
            notices.append(f'tree-sitter-{name}: {url} at {rev}, MIT. Pinned default grammar; compact grammar experiments are not packaged.')
        metadata = json.loads(output([cargo, 'metadata', '--locked', '--offline', '--format-version', '1', '--manifest-path', manifest], cwd=ROOT, env=env))
        dependencies = []
        for package in metadata['packages']:
            if package['name'] == 'dotls-zed': continue
            dependency = {'name': package['name'], 'version': package['version'], 'license': package['license']}
            dependencies.append(dependency)
            for f in sorted(Path(package['manifest_path']).parent.iterdir()):
                if f.is_file() and f.name.startswith(('LICENSE', 'COPYING', 'NOTICE')):
                    add(files, f"licenses/rust/{package['name']}-{package['version']}/{f.name}", f)
        sysroot = Path(output([rustc, '--print', 'sysroot']))/'share/doc/rust'
        for f in [sysroot/'COPYRIGHT-library.html', *sorted((sysroot/'licenses').glob('*'))]:
            if f.is_file(): add(files, 'licenses/rust-stdlib/'+f.name, f)
        files['THIRD-PARTY-NOTICES.txt'] = (('\n'.join(notices)+'\n').encode(), 0o644)
        files['DEPENDENCIES.json'] = ((json.dumps(dependencies, indent=2)+'\n').encode(), 0o644)
        files['RELEASE.json'] = ((json.dumps({'version': version, 'rustc': output([rustc, '--version']),
            'grammars': {name: {'repository': url, 'revision': rev} for name, (url, rev) in GRAMMARS.items()},
            'wasm_sha256': digest(wasm.read_bytes()), 'server_repository': 'AshutoshMahala/dot-ls',
            'server_tag': 'v'+version}, indent=2)+'\n').encode(), 0o644)
        path = a.output/f'dot-ls-zed-{version}.tar.gz'
        archive(path, files)
        print(path, flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, default=ROOT/'dist')
    p.add_argument('--targets', nargs='+', choices=TARGETS, default=TARGETS)
    p.add_argument('--zig', default='zig')
    p.add_argument('--cache-dir', type=Path)
    p.add_argument('--zed', action='store_true')
    p.add_argument('--zed-only', action='store_true')
    p.add_argument('--wasi-clang', type=Path)
    p.add_argument('--grammar-cache', type=Path, default=ROOT/'editors/zed/grammars')
    a = p.parse_args(); a.output = a.output.resolve(); a.output.mkdir(parents=True, exist_ok=True)
    version = (ROOT/'VERSION').read_text().strip(); version_checks(version)
    assert output([a.zig, 'version']) == '0.17.0', 'Use Zig 0.17.0'
    if not a.zed_only:
        for target in a.targets: native(a, version, target)
    if a.zed or a.zed_only: extension(a, version)
    archives = sorted(a.output.glob(f'*-{version}*.tar.gz'))
    (a.output/'SHA256SUMS').write_text(''.join(f'{digest(f.read_bytes())}  {f.name}\n' for f in archives))


if __name__ == '__main__':
    main()
