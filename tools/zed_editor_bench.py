#!/usr/bin/env python3
"""Prepare isolated Zed query variants and sample macOS editor resources.

UI actions must be performed separately in Zed. This tool does not drive the UI.
Only this adapter is preseeded. Zed can install its default HTML extension.
User settings are never changed.
"""
import argparse
import ctypes
import hashlib
import json
import os
import plistlib
from pathlib import Path
import shutil
import signal
import subprocess
import time

PROJECT = Path(__file__).resolve().parents[1]
ROOT = Path('/private/tmp/dot-ls-zed-isolated')
BASE_VARIANTS = ['dot', 'colors', 'pairs', 'full']
VARIANTS = BASE_VARIANTS + ['compact-dot', 'compact-full']


def prepare_app():
    """Copy the installed app so computer-use tools can select a distinct app."""
    app = ROOT / 'Zed Bench.app'
    if app.exists():
        raise SystemExit(f'{app} already exists; reuse it instead of overwriting it')
    shutil.copytree('/Applications/Zed.app', app)
    path = app / 'Contents/Info.plist'
    info = plistlib.loads(path.read_bytes())
    info.update(CFBundleIdentifier='dev.dotls.ZedBench',
                CFBundleName='Zed Bench', CFBundleDisplayName='Zed Bench')
    path.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)


def timebase():
    class Timebase(ctypes.Structure):
        _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]
    value = Timebase()
    result = ctypes.CDLL('/usr/lib/libSystem.B.dylib').mach_timebase_info(ctypes.byref(value))
    if result or not value.denom:
        raise RuntimeError('Cannot read the macOS CPU counter timebase')
    return value.numer, value.denom


def prepare():
    ROOT.mkdir(parents=True,exist_ok=True)
    (ROOT / 'fixtures').mkdir(parents=True,exist_ok=True)
    manifest = json.loads((Path.home() / 'Library/Application Support/Zed/extensions/index.json').read_text())
    extension = manifest['extensions']['dotls']
    for variant in BASE_VARIANTS:
        profile = ROOT / variant
        adapter = profile / 'extensions/installed/dotls'
        adapter.mkdir(parents=True, exist_ok=True)
        source = PROJECT / 'editors/zed'
        shutil.copy2(source / 'extension.toml', adapter)
        shutil.copy2(source / 'extension.wasm', adapter)
        shutil.copytree(source / 'languages', adapter / 'languages', dirs_exist_ok=True)
        (adapter / 'grammars').mkdir(parents=True,exist_ok=True)
        for grammar in ['dot', 'html']:
            shutil.copy2(source / f'grammars/{grammar}.wasm', adapter / f'grammars/{grammar}.wasm')
        dot = adapter / 'languages/dot'
        html = adapter / 'languages/dot-html'
        if variant == 'dot':
            (dot / 'injections.scm').write_text('')
            p = dot / 'highlights.scm'
            s = p.read_text()
            start = s.index('(html_string')
            end = s.index('(number_literal)')
            p.write_text(s[:start] + '(html_string) @string\n' + s[end:])
        if variant in ['dot', 'colors']:
            (dot / 'brackets.scm').write_text('("{" @open "}" @close)\n("[" @open "]" @close)\n')
            (html / 'brackets.scm').write_text('')
        if variant != 'full':
            (dot / 'indents.scm').write_text('(block "{" @start "}"? @end) @indent\n(attr_list "[" @start "]"? @end) @indent\n')
            (html / 'indents.scm').write_text('')
        index = {'extensions': {'dotls': extension}, 'languages': {k:v for k,v in manifest['languages'].items() if v['extension'] == 'dotls'}, 'themes': {}, 'icon_themes': {}}
        index['extensions']['dotls']['dev'] = False
        (profile / 'extensions/index.json').write_text(json.dumps(index))
        settings = {
            'theme': 'One Dark', 'buffer_font_size': 16,
            'ui_font_size': 14, 'enable_language_server': False,
            'languages': {'DOT (dot-ls)': {'enable_language_server': False}},
            'telemetry': {'diagnostics': False, 'metrics': False},
            'auto_update': False, 'autosave': 'off',
            'restore_on_startup': 'none', 'on_new_window': 'empty_tab',
            'show_edit_predictions': False,
            'file_types': {'DOT (dot-ls)': ['**/*.dot']},
            'instrumentation': {'performance_profiler': {'enabled': False}},
        }
        (profile / 'config').mkdir(parents=True,exist_ok=True)
        (profile / 'config/settings.json').write_text(json.dumps(settings, indent=2))
    for mb in [5, 20, 40]:
        target = mb * 1_000_000
        header = b'digraph editor_bench {\n'
        block = (b'    n00000000 [label=<\n'
                 b'        <TABLE BORDER="0"><TR><TD>\n'
                 b'            <B>alpha</B><BR/>beta\n'
                 b'        </TD></TR></TABLE>\n'
                 b'    >];\n'
                 b'    n00000000 -> n00000001 [color="blue"];\n')
        count = (target - len(header) - 4) // len(block)
        path = ROOT / f'fixtures/html-{mb}mb.dot'
        with path.open('wb') as f:
            f.write(header)
            for i in range(count):
                f.write(block.replace(b'n00000000', f'n{i:08d}'.encode()).replace(b'n00000001', f'n{i+1:08d}'.encode()))
            remain = target - f.tell() - 2
            f.write(b'//' + b' ' * (remain-3) + b'\n')
            f.write(b'}\n')
        assert path.stat().st_size == target
        print(json.dumps({'file': str(path), 'bytes': target, 'html_labels': count, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}))
    print('Prepared', ROOT)


def prepare_compact(wasm):
    """Seed only isolated runtime profiles; not a release manifest generator."""
    wasm = Path(wasm).resolve()
    if wasm.read_bytes()[:4] != b'\0asm':
        raise SystemExit('Expected a compiled WebAssembly grammar')
    for base in ['dot', 'full']:
        profile = ROOT / f'compact-{base}'
        for folder in ['extensions', 'config']:
            source = ROOT / base / folder
            if not source.is_dir():
                raise SystemExit('Run prepare first')
            shutil.copytree(source, profile / folder, dirs_exist_ok=True)
        adapter = profile / 'extensions/installed/dotls'
        shutil.copy2(wasm, adapter / 'grammars/dot_ls.wasm')
        config = adapter / 'languages/dot/config.toml'
        config.write_text(config.read_text().replace('grammar = "dot"', 'grammar = "dot_ls"'))
        manifest = adapter / 'extension.toml'
        manifest.write_text(manifest.read_text().replace('[grammars.dot]', '[grammars.dot_ls]'))
        # Runtime uses the prebuilt WASM. This source pin is unchanged metadata
        # in a private benchmark profile, and must not be used for release builds.
        path = profile / 'extensions/index.json'
        index = json.loads(path.read_text())
        grammars = index['extensions']['dotls']['manifest']['grammars']
        grammars['dot_ls'] = grammars.pop('dot')
        index['languages']['DOT (dot-ls)']['grammar'] = 'dot_ls'
        path.write_text(json.dumps(index))
        provenance = {'wasm_sha256': hashlib.sha256(wasm.read_bytes()).hexdigest(),
                      'grammar': 'dot_ls', 'abi': 14, 'runtime_override_only': True}
        (profile / 'grammar-provenance.json').write_text(json.dumps(provenance, indent=2))
        print(json.dumps({'profile': str(profile), **provenance}))


class Usage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in [
        'user_ticks', 'system_ticks', 'idle_wakeups', 'interrupt_wakeups', 'pageins', 'wired', 'rss', 'footprint', 'start', 'exit']]


def sample(pid):
    lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    r = Usage()
    if lib.proc_pid_rusage(pid, 0, ctypes.byref(r)):
        raise OSError(ctypes.get_errno(), 'proc_pid_rusage failed')
    return {'t': time.monotonic(), 'rss': r.rss, 'footprint': r.footprint,
            'cpu_ticks': r.user_ticks + r.system_ticks, 'process_start_ticks': r.start}


def launch(variant, mb, mode="normal"):
    if mode not in ['normal', 'study', 'stacks']:
        raise SystemExit('Use normal/study/stacks mode')
    if variant not in VARIANTS or mb not in [5, 20, 40]:
        raise SystemExit('Use dot/colors/pairs/full and 5/20/40 MB')
    profile = ROOT / variant
    # Reset only our temporary session database, keeping adapter and settings.
    if (profile / 'db').exists():
        shutil.rmtree(profile / 'db')
    log = (ROOT / f'{variant}-{mb}-stdout.log').open('w')
    p = subprocess.Popen([str(ROOT / 'Zed Bench.app/Contents/MacOS/zed'), '--user-data-dir', str(profile)], stdout=log, stderr=log, start_new_session=True, env={**os.environ, 'ZED_STATELESS': '1', **({'MallocStackLogging': '1'} if mode == 'stacks' or os.environ.get('DOTLS_ZED_STACK_LOGGING') else {})})
    numer, denom = timebase()
    state = {'variant': variant, 'mb': mb, 'pid': p.pid, 'started': time.time(),
             'process_start_ticks': sample(p.pid)['process_start_ticks'],
             'output_dir': os.environ.get('DOTLS_ZED_OUTPUT', str(PROJECT / ('bench/results/zed-editor-isolated' if mode == 'normal' else 'bench/results/zed-grammar-study'))),
             'phases': [], 'samples': [],
             'grammar_provenance': json.loads((profile / 'grammar-provenance.json').read_text()) if (profile / 'grammar-provenance.json').exists() else None,
             'cpu_timebase_numer': numer, 'cpu_timebase_denom': denom}
    (ROOT / 'active.json').write_text(json.dumps(state))
    print(json.dumps({'pid': p.pid, 'profile': str(profile), 'fixture': str(ROOT / f'fixtures/html-{mb}mb.dot')}))


def monitor():
    state = json.loads((ROOT / 'active.json').read_text())
    path = ROOT / f"{state['variant']}-{state['mb']}-samples.jsonl"
    with path.open('w') as f:
        for _ in range(18000):
            try:
                row = sample(state['pid'])
                if state.get('process_start_ticks', row['process_start_ticks']) != row['process_start_ticks']:
                    break
            except OSError:
                break
            f.write(json.dumps(row)+'\n')
            f.flush()
            time.sleep(.05)


def mark(label):
    p = ROOT / 'active.json'
    state = json.loads(p.read_text())
    row = sample(state['pid'])
    row['label'] = label
    state['phases'].append(row)
    p.write_text(json.dumps(state, indent=2))
    print(json.dumps(row))


def settle():
    state = json.loads((ROOT / 'active.json').read_text())
    start = time.monotonic()
    previous = sample(state['pid'])
    quiet = 0
    for _ in range(30):
        time.sleep(1)
        current = sample(state['pid'])
        numer, denom = timebase()
        cpu_s = (current['cpu_ticks'] - previous['cpu_ticks']) * numer / denom / 1e9
        quiet = quiet + 1 if cpu_s < .10 else 0
        previous = current
        if quiet >= 2:
            break
    print(json.dumps({'settle_wait_s': time.monotonic()-start, 'quiet_intervals': quiet}))
    mark('settled')


def finish():
    p = ROOT / 'active.json'
    state = json.loads(p.read_text())
    samples = [json.loads(l) for l in (ROOT / f"{state['variant']}-{state['mb']}-samples.jsonl").read_text().splitlines()]
    state['samples'] = samples
    out = Path(state.get('output_dir', str(PROJECT / 'bench/results/zed-editor-isolated')))
    out.mkdir(parents=True,exist_ok=True)
    (out / f"{state['variant']}-{state['mb']}.json").write_text(json.dumps(state, indent=2))
    print(json.dumps({'phases': state['phases'], 'sampled_peak_rss': max(s['rss'] for s in samples), 'sampled_peak_footprint': max(s['footprint'] for s in samples)}, indent=2))
    # This PID was created by launch; never locate or terminate a user's Zed.
    current = sample(state['pid'])
    if state.get('process_start_ticks') != current['process_start_ticks']:
        raise SystemExit('Process identity changed or is missing; will not send a signal')
    os.kill(state['pid'], signal.SIGTERM)


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('command', choices=['prepare','prepare-app','prepare-compact','launch','monitor','mark','finish','snapshot','settle'])
    p.add_argument('args', nargs='*')
    a = p.parse_args()
    if a.command == 'prepare': prepare()
    elif a.command == 'prepare-app': prepare_app()
    elif a.command == 'prepare-compact': prepare_compact(a.args[0])
    elif a.command == 'launch': launch(a.args[0], int(a.args[1]), a.args[2] if len(a.args)>2 else 'normal')
    elif a.command == 'monitor': monitor()
    elif a.command == 'mark': mark(a.args[0])
    elif a.command == 'finish': finish()
    elif a.command == 'settle': settle()
    elif a.command == 'snapshot': print(json.dumps(sample(int(a.args[0]))))
