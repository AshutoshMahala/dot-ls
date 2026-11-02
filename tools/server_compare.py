#!/usr/bin/env python3
"""Controlled stdio comparison; no editor, third-party Python modules or settings changes.
Run startup, then size 5, 20 and 40 in that order. Later sizes require a passed gate.
macOS uses proc_pid_rusage for samples and wait4 for the child's actual peak RSS.
"""
import argparse
import ctypes as c
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import signal
import statistics
import subprocess
import threading
import time

PROJECT = Path(__file__).resolve().parents[1]
OUT = PROJECT / 'bench/results/server-comparison-2026-10-15'
FIXTURES = Path('/private/tmp/dot-ls-server-comparison')
SERVERS = {'dot-ls': [str(PROJECT / 'zig-out/bin/dot-ls'), 'lsp'],
           'dot-language-server': ['/opt/homebrew/bin/dot-language-server', '--stdio']}
URI = 'file:///controlled-server-comparison.dot'
class Usage(c.Structure):
    _fields_ = [('uuid', c.c_uint8 * 16)] + [(key, c.c_uint64) for key in ['user', 'system', 'idle', 'interrupts', 'pageins', 'wired', 'rss', 'footprint', 'start', 'exit']]
LIB = c.CDLL('/usr/lib/libproc.dylib', use_errno=True)
class Timebase(c.Structure):
    _fields_ = [('numer', c.c_uint32), ('denom', c.c_uint32)]
TB = Timebase()
assert c.CDLL('/usr/lib/libSystem.B.dylib').mach_timebase_info(c.byref(TB)) == 0

def sample(pid):
    value = Usage()
    if LIB.proc_pid_rusage(pid, 0, c.byref(value)):
        raise OSError(c.get_errno(), 'proc_pid_rusage failed')
    return {'t': time.perf_counter(), 'rss_bytes': value.rss, 'footprint_bytes': value.footprint,
            'cpu_seconds': (value.user + value.system) * TB.numer / TB.denom / 1e9, 'start_ticks': value.start}

def packet(method, params=None, ident=None):
    value = {'jsonrpc': '2.0', 'method': method}
    if params is not None: value['params'] = params
    if ident is not None: value['id'] = ident
    data = json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()
    return b'Content-Length: ' + str(len(data)).encode() + b'\r\n\r\n' + data

INIT = packet('initialize', {'processId': None, 'rootUri': None, 'capabilities': {
    'general': {'positionEncodings': ['utf-16']},
    'textDocument': {'publishDiagnostics': {'relatedInformation': True, 'versionSupport': True}}}}, 1)

class Client:
    def __init__(self, name):
        self.name = name; self.events = queue.Queue(); self.samples = []; self.stderr = bytearray()
        self.done = threading.Event(); self.reason = None; self.reaped = False
        self.start = time.perf_counter()
        self.p = subprocess.Popen(SERVERS[name], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, start_new_session=True)
        self.identity = sample(self.p.pid)['start_ticks']
        threading.Thread(target=self.read, daemon=True).start()
        self.stderr_thread = threading.Thread(target=self.read_stderr, daemon=True)
        self.stderr_thread.start()
        threading.Thread(target=self.monitor, daemon=True).start()
        self.raw(INIT)
        _, reply, _ = self.receive(45)
        if reply.get('id') != 1 or 'result' not in reply: raise RuntimeError(('initialize', reply))
        self.startup_ms = (time.perf_counter() - self.start) * 1000
        self.capabilities = reply['result']
        self.raw(packet('initialized', {}))

    def raw(self, data):
        self.p.stdin.write(data); self.p.stdin.flush()

    def read(self):
        try:
            while True:
                headers = {}
                while True:
                    line = self.p.stdout.readline()
                    if not line: raise EOFError('server stdout closed')
                    if line == b'\r\n': break
                    key, value = line.decode().split(':', 1); headers[key.lower()] = value.strip()
                size = int(headers['content-length']); data = bytearray()
                while len(data) < size:
                    part = self.p.stdout.read(size - len(data))
                    if not part: raise EOFError('truncated server frame')
                    data.extend(part)
                arrived = time.perf_counter() # Complete wire message, before client JSON decoding.
                self.events.put((arrived, json.loads(data), size))
        except Exception as error:
            self.events.put(error)

    def read_stderr(self):
        while True:
            part = self.p.stderr.read(4096)
            if not part: return
            self.stderr.extend(part); del self.stderr[:-65536]

    def monitor(self):
        while not self.done.wait(.02):
            try:
                row = sample(self.p.pid)
                if row['start_ticks'] != self.identity: return
                self.samples.append(row)
                if row['rss_bytes'] > 6_000_000_000:
                    self.reason = '6 GB server RSS safety limit'
                    os.killpg(self.p.pid, signal.SIGTERM); return
            except OSError: return

    def receive(self, seconds=45):
        try: result = self.events.get(timeout=seconds)
        except queue.Empty: raise TimeoutError('45 s LSP response deadline')
        if isinstance(result, Exception): raise result
        arrived, message, size = result
        # No workspace configuration capability is advertised. Still answer generic requests.
        if 'method' in message and 'id' in message:
            data = json.dumps({'jsonrpc': '2.0', 'id': message['id'], 'result': None}).encode()
            self.raw(b'Content-Length: '+str(len(data)).encode()+b'\r\n\r\n'+data)
        return arrived, message, size

    def quiet(self):
        previous = sample(self.p.pid); quiet = 0
        for _ in range(50):
            time.sleep(.1); current = sample(self.p.pid)
            quiet = quiet + 1 if current['cpu_seconds'] - previous['cpu_seconds'] < .02 else 0
            previous = current
            if quiet >= 3: return current
        raise TimeoutError('server did not settle within 5 s after diagnostics')

    def measure(self, data, version, kind, phase, errors):
        start_sample = sample(self.p.pid); start = time.perf_counter()
        self.raw(data); sent = time.perf_counter()
        notifications = []
        expected = 2 if self.name == 'dot-ls' and kind == 'html' else 1
        for _ in range(expected):
            while True:
                arrived, message, size = self.receive()
                if message.get('method') == 'textDocument/publishDiagnostics':
                    params = message['params']
                    assert params['uri'] == URI
                    assert params.get('version', version) == version, params.get('version')
                    ds = params['diagnostics']
                    notifications.append({'ms': (arrived-start)*1000, 'wire_bytes': size,
                        'diagnostics': len(ds), 'errors': sum(d.get('severity', 1) == 1 for d in ds),
                        'incomplete': any('incomplete' in str(d.get('code', '')) or d.get('code') == 'dot-ls:limits' for d in ds),
                        'codes': dict((str(code), sum(str(d.get('code')) == str(code) for d in ds)) for code in set(str(d.get('code')) for d in ds)),
                        'examples': ds[:1] + (ds[-1:] if len(ds)>1 else [])})
                    break
        settled = self.quiet()
        # No changes are sent until all expected diagnostics and background work settle.
        assert self.events.empty(), 'unexpected extra message after diagnostic phase'
        row = {'phase': phase, 'inserted_errors': errors, 'version': version,
            'first_diagnostics_ms': notifications[0]['ms'], 'final_diagnostics_ms': notifications[-1]['ms'],
            'write_ms': (sent-start)*1000, 'notifications': notifications,
            'settled_rss_bytes': settled['rss_bytes'], 'settled_footprint_bytes': settled['footprint_bytes'],
            'cpu_through_settle_seconds': settled['cpu_seconds']-start_sample['cpu_seconds'],
            'reported_incomplete': notifications[-1]['incomplete']}
        if errors < 1000:
            assert notifications[-1]['errors'] == errors, (self.name, kind, errors, notifications[-1])
        return row

    def close(self, success):
        try:
            if success:
                self.raw(packet('shutdown', ident=99))
                while self.receive(10)[1].get('id') != 99: pass
                self.raw(packet('exit')); self.p.stdin.close()
        except (OSError, EOFError, TimeoutError): success = False
        if not success:
            try: os.killpg(self.p.pid, signal.SIGTERM)
            except ProcessLookupError: pass
        deadline = time.monotonic()+10
        while True:
            pid, status, usage = os.wait4(self.p.pid, os.WNOHANG)
            if pid: break
            if time.monotonic() > deadline:
                os.killpg(self.p.pid, signal.SIGKILL)
            time.sleep(.01)
        self.p.returncode = os.waitstatus_to_exitcode(status)
        self.done.set(); self.reaped = True
        if hasattr(self, 'stderr_thread'): self.stderr_thread.join(timeout=1)
        return {'exit_code': self.p.returncode, 'actual_peak_rss_bytes': usage.ru_maxrss,
                'sampled_peak_rss_bytes': max((s['rss_bytes'] for s in self.samples), default=0),
                'sampled_peak_footprint_bytes': max((s['footprint_bytes'] for s in self.samples), default=0),
                'cpu_user_seconds': usage.ru_utime, 'cpu_system_seconds': usage.ru_stime,
                'safety_stop': self.reason, 'stderr': self.stderr.decode(errors='replace')}

def fixture(kind, mb):
    header = b'digraph controlled {\n'
    if kind == 'plain': block = b'    n00000000 -> n00000001 [label="edge 00000000"];\n'
    else: block = (b'    n00000000 [label=<\n'
                   b'        <TABLE BORDER="0"><TR><TD>\n'
                   b'            <B>alpha</B><BR/>beta\n'
                   b'        </TD></TR></TABLE>\n'
                   b'    >];\n'
                   b'    n00000000 -> n00000001 [color="blue"];\n')
    size = mb * 1_000_000; count = (size-len(header)-4)//len(block)
    data = bytearray(header)
    for i in range(count):
        data.extend(block.replace(b'n00000000', f'n{i:08d}'.encode()).replace(b'n00000001', f'n{i+1:08d}'.encode()))
    remain = size-len(data)-2; data.extend(b'//'+b' '*(remain-3)+b'\n}\n')
    assert len(data) == size
    FIXTURES.mkdir(parents=True,exist_ok=True); path = FIXTURES/f'{kind}-{mb}mb.dot'; path.write_bytes(data)
    positions = [m.start()+4 for m in re.finditer(rb'(?m)^    n[0-9]+ ->', data)]
    return bytes(data), positions, {'kind':kind, 'mb':mb, 'source_bytes':size, 'records':count,
        'html_labels':count if kind=='html' else 0, 'sha256':hashlib.sha256(data).hexdigest()}

def damage(source, positions, count):
    data = bytearray(source)
    chosen = [positions[-1]] if count == 1 else [positions[(i+1)*len(positions)//(count+1)] for i in range(count)]
    assert len(set(chosen)) == count
    for at in chosen: assert data[at] == ord('n'); data[at] = ord('@')
    return bytes(data).decode()

def message(source, version):
    doc = {'uri':URI,'version':version}
    if version == 1:
        doc.update(languageId='dot', text=source)
        return packet('textDocument/didOpen', {'textDocument':doc})
    return packet('textDocument/didChange', {'textDocument':doc,'contentChanges':[{'text':source}]})

def run(name, kind, mb, case, trial, payloads):
    row = {'server':name,'kind':kind,'mb':mb,'case':case,'trial':trial,'phases':[]}
    client = None; ok = False
    try:
        client = Client.__new__(Client); client.__init__(name); row['startup_ms'] = client.startup_ms
        row['initialized_idle'] = client.quiet()
        for version, (phase, errors, data) in enumerate(payloads, 1):
            row['phases'].append(client.measure(data, version, kind, phase, errors))
        ok = True
    except Exception as error:
        row['failure'] = f'{type(error).__name__}: {error}'
    finally:
        if client is not None and hasattr(client, 'p'): row['resources'] = client.close(ok)
    row['passed'] = ok and row.get('resources',{}).get('exit_code') == 0
    with (OUT/'runs.jsonl').open('a') as f: f.write(json.dumps(row)+'\n')
    print(json.dumps({'server':name,'kind':kind,'mb':mb,'case':case,'trial':trial,'passed':row['passed'],
          'final_ms':[round(r['final_diagnostics_ms'],2) for r in row['phases']],
          'peak_mb':round(row.get('resources',{}).get('actual_peak_rss_bytes',0)/1e6,2), 'failure':row.get('failure')}), flush=True)
    return row

def startup():
    rows = []
    for i in range(15):
        for name in (list(SERVERS) if i%2==0 else list(reversed(SERVERS))):
            client = Client(name)
            idle = client.quiet()
            resources = client.close(True)
            rows.append({'server':name,'trial':i+1,'startup_ms':client.startup_ms,'idle':idle,'resources':resources,
                         'initialize_result':client.capabilities if i==0 else None})
            print(name, i+1, round(client.startup_ms,2), flush=True)
    (OUT/'startup.json').write_text(json.dumps(rows,indent=2)+'\n')

def stage(mb, trials, errors_only=False, counts=(0,1,10,100,1000,1200), names=None, kinds=None):
    if mb != 5:
        previous = json.loads((OUT/f'gate-{5 if mb==20 else 20}.json').read_text())
        if not previous['passed']: raise SystemExit('Previous size did not pass the response/resource gate')
    rows = []; blocked = set()
    def perform(name, kind, case, trial, payloads):
        key = (name, kind)
        if key in blocked:
            row = {'server':name,'kind':kind,'mb':mb,'case':case,'trial':trial,'passed':False,'skipped':True,'phases':[], 'failure':'Earlier case for this server/workload did not pass the responsiveness gate'}
            with (OUT/'runs.jsonl').open('a') as f: f.write(json.dumps(row)+'\n')
            print(json.dumps(row),flush=True)
        else:
            row = run(name,kind,mb,case,trial,payloads)
            if not row['passed'] or row['resources']['actual_peak_rss_bytes'] >= 6_000_000_000 or any(p['final_diagnostics_ms'] >= 10_000 for p in row['phases']): blocked.add(key)
        return row
    names = names or list(SERVERS)
    for kind in kinds or ['plain','html']:
        source, positions, meta = fixture(kind, mb)
        (OUT/f'fixture-{kind}-{mb}.json').write_text(json.dumps(meta,indent=2)+'\n')
        clean = source.decode()
        # Main sequence: fresh open, then three full-sync single-error/repair pairs.
        seq = [('open',0,clean)] + [(phase,errors,damage(source,positions,1) if errors else clean)
            for _ in range(3) for phase,errors in [('error',1),('repair',0)]]
        payloads = [(phase,n,message(text,i)) for i,(phase,n,text) in enumerate(seq,1)]
        for trial in range(1,0 if errors_only else trials+1):
            for name in (names if trial%2 else list(reversed(names))):
                rows.append(perform(name,kind,'single-error',trial,payloads))
        # Fresh process per error count avoids carrying high-error allocations into another count.
        for count in counts:
            text = damage(source,positions,count)
            payloads = [('open',count,message(text,1))]+[('repeat',count,message(text,i)) for i in [2,3]]
            for name in names:
                rows.append(perform(name,kind,f'errors-{count}',1,payloads))
        del source,clean,payloads
    # A rerun supersedes the same case/trial without deleting the original audit record.
    effective = {}
    for line in (OUT/'runs.jsonl').read_text().splitlines():
        row = json.loads(line)
        if row['mb'] == mb: effective[(row['server'],row['kind'],row['case'],row['trial'])] = row
    passed = all(r['passed'] and r['resources']['actual_peak_rss_bytes'] < 6_000_000_000 and
                 all(p['final_diagnostics_ms'] < 10_000 for p in r['phases']) for r in effective.values())
    gate = {'mb':mb,'passed':passed,'rule':'Every tested case responds in <10 s, exits cleanly and peaks below 6 GB RSS. Incomplete analysis is recorded separately; a quick partial result is not full validation.', 'effective_runs':len(effective)}
    (OUT/f'gate-{mb}.json').write_text(json.dumps(gate,indent=2)+'\n'); print(json.dumps(gate),flush=True)

def coverage_probes():
    sources = [
        ('mismatched-html', b'digraph { a [label=<<B>x</I>>]; }', 'html'),
        ('quoted-html-text', b'digraph { a [label="<B>x</I>"]; }', 'plain')]
    source = (FIXTURES/'html-20mb.dot').read_bytes()
    for placement in ['first','last']:
        at = source.find(b'</B>') if placement == 'first' else source.rfind(b'</B>')
        changed = source[:at] + b'</I>' + source[at+4:]
        sources.append((f'html-20mb-mismatch-{placement}', changed, 'html'))
    rows = []
    for label, source, kind in sources:
        data = message(source.decode(), 1)
        for name in SERVERS:
            client = Client.__new__(Client); ok = False
            row = {'probe':label,'server':name,'source_bytes':len(source),'notifications':[]}
            try:
                client.__init__(name); client.quiet()
                start = time.perf_counter(); client.raw(data)
                for _ in range(2 if name == 'dot-ls' and kind == 'html' else 1):
                    while True:
                        arrived, reply, size = client.receive()
                        if reply.get('method') == 'textDocument/publishDiagnostics':
                            ds = reply['params']['diagnostics']
                            row['notifications'].append({'ms':(arrived-start)*1000,'diagnostics':ds,'wire_bytes':size}); break
                client.quiet();ok = True
            except Exception as error: row['failure'] = repr(error)
            finally:
                if hasattr(client,'p'): row['resources'] = client.close(ok)
            rows.append(row)
            print(label,name,[len(n['diagnostics']) for n in row['notifications']],flush=True)
    (OUT/'coverage-probes.json').write_text(json.dumps(rows,indent=2)+'\n')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['startup','stage','coverage'])
    parser.add_argument('--mb',type=int,choices=[5,20,40],default=5)
    parser.add_argument('--trials',type=int,default=3)
    parser.add_argument('--errors-only',action='store_true')
    parser.add_argument('--counts',default='0,1,10,100,1000,1200')
    parser.add_argument('--servers',default='dot-ls,dot-language-server')
    parser.add_argument('--kinds',default='plain,html')
    args = parser.parse_args(); OUT.mkdir(parents=True,exist_ok=True)
    if args.command == 'startup': startup()
    elif args.command == 'coverage': coverage_probes()
    else: stage(args.mb,args.trials,args.errors_only,tuple(int(n) for n in args.counts.split(',')),args.servers.split(','),args.kinds.split(','))
