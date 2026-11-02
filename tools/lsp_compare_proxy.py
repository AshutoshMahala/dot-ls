#!/usr/bin/env python3
"""Development-only LSP relay. Log timing/RSS outside the server and editor."""
import json, os, pathlib, subprocess, sys, threading, time
label = sys.argv[1]
root = pathlib.Path(__file__).resolve().parent.parent
log_dir = root / 'bench/results' / 'zed-comparison'
log_dir.mkdir(parents=True,exist_ok=True)
log = (log_dir / f'{label}-{os.getpid()}.jsonl').open('a', buffering=1)
stderr = (log_dir / f'{label}-{os.getpid()}.stderr').open('wb')
child = subprocess.Popen(sys.argv[2:], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr)
lock = threading.Lock()
pending = {}
peak = 0
rss = 0
started = time.monotonic_ns()
def record(event, **fields):
    with lock:
        log.write(json.dumps({'event': event, 'time_ns': time.monotonic_ns(), **fields}) + '\n')
record('start', child_pid=child.pid, command=sys.argv[2:])
def read_frame(stream):
    headers = bytearray(); length = None
    while True:
        line = stream.readline()
        if not line: return None
        headers.extend(line)
        if line in (b'\r\n', b'\n'): break
        key, value = line.split(b':', 1)
        if key.lower() == b'content-length': length = int(value)
    if length is None: raise ValueError('Missing Content-Length')
    body = bytearray()
    while len(body) < length:
        part = stream.read(length - len(body))
        if not part: raise EOFError('Truncated LSP body')
        body.extend(part)
    return bytes(headers), bytes(body)
def sample():
    global rss, peak
    n = 0
    while child.poll() is None:
        try:
            values = subprocess.check_output(['ps', '-o', 'rss=,%cpu=', '-p', str(child.pid)]).split()
            rss = int(values[0]) * 1024; peak = max(peak, rss)
            if n % 10 == 0: record('memory', rss_bytes=rss, peak_rss_bytes=peak, cpu_percent=float(values[1]))
            n += 1
        except (ValueError, IndexError, subprocess.CalledProcessError): pass
        time.sleep(.02)
def receive():
    try:
        while True:
            frame = read_frame(child.stdout)
            if frame is None: break
            headers, body = frame
            now = time.monotonic_ns()
            value = json.loads(body)
            if value.get('method') == 'textDocument/publishDiagnostics':
                params = value['params']; item = pending.get(params['uri'])
                fields = {'uri': params['uri'], 'version': params.get('version'), 'count': len(params['diagnostics']), 'rss_bytes': rss, 'peak_rss_bytes': peak}
                if item:
                    fields.update(request_version=item[1], wire_bytes=item[2], diagnostic_ms=(now-item[0])/1e6)
                record('diagnostics', **fields)
            elif 'result' in value and isinstance(value['result'], dict) and 'capabilities' in value['result']:
                record('initialize', result=value['result'])
            sys.stdout.buffer.write(headers); sys.stdout.buffer.write(body); sys.stdout.buffer.flush()
    except (BrokenPipeError, OSError): pass
    finally: record('server_stdout_closed', returncode=child.poll(), peak_rss_bytes=peak)
threading.Thread(target=sample, daemon=True).start()
receiver = threading.Thread(target=receive, daemon=True); receiver.start()
try:
    while True:
        frame = read_frame(sys.stdin.buffer)
        if frame is None: break
        headers, body = frame
        value = json.loads(body)
        method = value.get('method')
        if method in ('textDocument/didOpen', 'textDocument/didChange'):
            doc = value['params']['textDocument']; begin = time.monotonic_ns()
            pending[doc['uri']] = (begin, doc.get('version'), len(body))
            record('request', method=method, uri=doc['uri'], version=doc.get('version'), wire_bytes=len(body))
        if method == 'textDocument/didClose':
            pending.pop(value['params']['textDocument']['uri'], None)
        child.stdin.write(headers); child.stdin.write(body); child.stdin.flush()
        del value, body, frame
except (BrokenPipeError, OSError): pass
finally:
    try: child.stdin.close()
    except OSError: pass
    try: child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        child.terminate()
        try: child.wait(timeout=3)
        except subprocess.TimeoutExpired: child.kill(); child.wait()
    receiver.join(timeout=2)
    record('exit', returncode=child.returncode, peak_rss_bytes=peak)
