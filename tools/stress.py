#!/usr/bin/env python3
"""macOS stdio stress: sustained edits, cancellation, cleanup and active shutdown.

Uses isolated owned children. RSS excludes the editor and Python client.
All input writes and response waits have deadlines. A failed size stops the run.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import statistics
import time
import server_compare as b


class Client(b.Client):
    def raw(self, data):
        fd = self.p.stdin.fileno()
        os.set_blocking(fd, False)
        view = memoryview(data)
        deadline = time.monotonic() + 15
        while view:
            left = deadline - time.monotonic()
            assert left > 0 and select.select([], [fd], [], left)[1], 'input deadline'
            try:
                view = view[os.write(fd, view):]
            except BlockingIOError:
                pass


class Session:
    def __init__(self):
        self.client = Client('dot-ls')
        self.pending = set()
        self.replies = {}
        self.last = {}
        self.closed = set()
        self.cancel_ms = []
        self.cancel_sent = {}
        self.cancelled = 0
        self.diagnostics = 0
        self.findings = {}

    def send(self, method, params=None, ident=None):
        if ident is not None:
            assert ident not in self.pending and ident not in self.replies
            self.pending.add(ident)
        self.client.raw(b.packet(method, params, ident))

    def read(self, deadline):
        arrived, message, _ = self.client.receive(max(.001, deadline - time.perf_counter()))
        assert arrived <= deadline, 'response deadline'
        if 'id' in message:
            ident = message['id']
            assert ident in self.pending, ('duplicate/unexpected reply', ident)
            self.pending.remove(ident)
            self.replies[ident] = message
            if ident in self.cancel_sent:
                self.cancel_ms.append((arrived - self.cancel_sent[ident]) * 1000)
                if 'error' in message:
                    assert message['error']['code'] in (-32800, -32801), message
                    self.cancelled += message['error']['code'] == -32800
        else:
            assert message.get('method') == 'textDocument/publishDiagnostics', message
            p = message['params']; uri = p['uri']
            if p.get('version') is not None:
                assert uri not in self.closed, ('publication after acknowledged close', p)
                assert p['version'] >= self.last.get(uri, -1), ('regressed version', p)
                self.last[uri] = p['version']
                self.findings[uri] = p['diagnostics']
            self.diagnostics += 1
        return arrived, message

    def until(self, predicate, seconds=15):
        deadline = time.perf_counter() + seconds
        while True:
            value = self.read(deadline)
            if predicate(*value):
                return value

    def reply(self, ident):
        if ident not in self.replies:
            self.until(lambda _, m: m.get('id') == ident)
        return self.replies[ident]

    def ready(self, uri, ident):
        self.send('textDocument/completion', {'textDocument': {'uri': uri},
                  'position': {'line': 0, 'character': 0}}, ident)
        assert 'result' in self.reply(ident), self.replies[ident]

    def close_doc(self, uri):
        self.send('textDocument/didClose', {'textDocument': {'uri': uri}})
        self.until(lambda _, m: m.get('method') == 'textDocument/publishDiagnostics'
                   and m['params']['uri'] == uri and m['params'].get('version') is None)
        self.closed.add(uri)


def workload(mb, kind, cycles, edits, debug):
    source, positions, fixture = b.fixture(kind, mb)
    broken = b.damage(source, positions, 1000)
    uri = 'untitled:stress'
    s = Session(); c = s.client; ok = False
    row = {'mb': mb, 'kind': kind, 'fixture': fixture, 'cycles': [], 'startup_ms': c.startup_ms}
    try:
        row['idle'] = c.quiet()
        version = 0
        for cycle in range(cycles):
            s.closed.discard(uri)
            version += 1
            s.send('textDocument/didOpen', {'textDocument': {'uri': uri, 'languageId': 'dot',
                   'version': version, 'text': source.decode()}})
            s.ready(uri, f'ready-{cycle}')
            settled = c.quiet()
            start = time.perf_counter()
            ids = []
            for edit in range(edits):
                version += 1
                s.send('textDocument/didChange', {'textDocument': {'uri': uri, 'version': version},
                       'contentChanges': [{'text': broken if edit % 2 == 0 else source.decode()}]})
                ident = f'cancel-{cycle}-{edit}'; ids.append(ident)
                s.send('textDocument/references', {'textDocument': {'uri': uri},
                       'position': {'line': 1, 'character': 5},
                       'context': {'includeDeclaration': True}}, ident)
                s.cancel_sent[ident] = time.perf_counter()
                s.send('$/cancelRequest', {'id': ident})
                # Pace toward 20 full-text edits/s; intake may impose backpressure.
                time.sleep(max(0, start + (edit + 1) * .05 - time.perf_counter()))
            burst_seconds = time.perf_counter() - start
            # Small-file diagnostics must progress during a large-file rebuild.
            version += 1
            s.send('textDocument/didChange', {'textDocument': {'uri': uri, 'version': version},
                   'contentChanges': [{'text': source.decode()}]})
            small = f'untitled:priority-{cycle}'; t = time.perf_counter()
            s.send('textDocument/didOpen', {'textDocument': {'uri': small, 'version': 1,
                   'languageId': 'dot', 'text': 'digraph { broken -> }'}})
            arrived, msg = s.until(lambda _, m: m.get('method') == 'textDocument/publishDiagnostics'
                                   and m['params']['uri'] == small)
            assert msg['params']['diagnostics']
            priority_ms = (arrived - t) * 1000
            s.ready(uri, f'final-{cycle}')
            assert s.last[uri] == version
            for ident in ids:
                s.reply(ident)
            final_rss = c.quiet()
            s.close_doc(small); s.close_doc(uri)
            post = c.quiet()
            row['cycles'].append({'edits': edits, 'burst_seconds': burst_seconds,
                                  'settled_rss_bytes': settled['rss_bytes'],
                                  'final_rss_bytes': final_rss['rss_bytes'],
                                  'post_close_rss_bytes': post['rss_bytes'],
                                  'priority_diagnostics_ms': priority_ms})
            print(mb, kind, cycle, 'close MB', round(post['rss_bytes']/1e6, 2),
                  'small-file ms', round(priority_ms, 1), flush=True)
            if not debug:
                assert post['rss_bytes'] < row['idle']['rss_bytes'] + 8_000_000, 'post-close RSS did not recover'
        assert not s.pending, s.pending
        assert s.cancelled > 0, 'no queued request cancellation exercised'
        row.update(cancelled=s.cancelled, cancellation_reply_ms_max=max(s.cancel_ms),
                   cancellation_reply_ms_median=statistics.median(s.cancel_ms),
                   diagnostics=s.diagnostics)
        ok = True
    finally:
        row['resources'] = c.close(ok)
    assert row['resources']['exit_code'] == 0 and not row['resources']['stderr'], row['resources']
    assert row['resources']['actual_peak_rss_bytes'] < 1_000_000_000
    return row


def shutdown_stress(count):
    rows = []
    source = 'digraph {\n' + 'a -> b;\n' * 5_000_000 + '}\n'
    for i in range(count):
        s = Session(); ok = False
        try:
            s.send('textDocument/didOpen', {'textDocument': {'uri': 'untitled:exit',
                   'version': 1, 'text': source}})
            start = time.perf_counter(); ok = True
        finally:
            result = s.client.close(ok)
        result['shutdown_ms'] = (time.perf_counter() - start) * 1000
        assert result['exit_code'] == 0 and not result['stderr'], result
        assert result['shutdown_ms'] < 3000, result
        rows.append(result)
    return rows


def multi_document():
    """Complete error-heavy work, eight live files, close/reopen version reuse."""
    source, positions, _ = b.fixture('html', 5)
    broken = b.damage(source, positions, 1000)
    s = Session(); c = s.client; ok = False
    row = {'documents': 8, 'source_bytes_each': len(source), 'cycles': []}
    try:
        row['idle'] = c.quiet()
        for cycle in range(3):
            for n in range(8):
                uri = f'untitled:multi-{n}'
                s.closed.discard(uri); s.last.pop(uri, None)
                s.send('textDocument/didOpen', {'textDocument': {'uri': uri, 'version': 1,
                       'text': broken if n % 2 else source.decode()}})
            for n in range(8):
                uri = f'untitled:multi-{n}'
                s.ready(uri, f'multi-{cycle}-{n}')
                ds = s.findings[uri]
                if n % 2:
                    assert len(ds) == 1001 and any(d['code'] == 'dot-ls:incomplete' for d in ds), len(ds)
                else:
                    assert ds == [], ds[:1]
            live = c.quiet()
            for n in range(8):
                s.close_doc(f'untitled:multi-{n}')
            post = c.quiet()
            row['cycles'].append({'live_rss_bytes': live['rss_bytes'],
                                  'post_close_rss_bytes': post['rss_bytes']})
        # Reuse version 1, but replace the error-heavy incarnation with a tiny clean file.
        uri = 'untitled:multi-1'; s.closed.discard(uri); s.last.pop(uri, None)
        s.send('textDocument/didOpen', {'textDocument': {'uri': uri, 'version': 1,
               'text': 'digraph { replacement; }'}})
        s.ready(uri, 'reopened'); assert s.findings[uri] == []
        s.send('textDocument/references', {'textDocument': {'uri': uri},
               'position': {'line': 0, 'character': 12},
               'context': {'includeDeclaration': True}}, 'reopened-refs')
        assert len(s.reply('reopened-refs')['result']) == 1
        s.close_doc(uri)
        assert not s.pending
        ok = True
    finally:
        row['resources'] = c.close(ok)
    assert row['resources']['exit_code'] == 0 and not row['resources']['stderr'], row['resources']
    return row


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('binary', type=Path)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--sizes', nargs='+', type=int, default=[5, 20, 40])
    p.add_argument('--cycles', type=int, default=3)
    p.add_argument('--edits', type=int, default=30)
    p.add_argument('--shutdowns', type=int, default=10)
    p.add_argument('--debug-allocator', action='store_true')
    p.add_argument('--extras-only', action='store_true', help='Only multi-document/error/reopen checks')
    a = p.parse_args()
    assert min(a.sizes) > 0 and a.cycles > 0 and a.edits > 0 and a.shutdowns > 0
    a.output.mkdir(parents=True, exist_ok=True)
    b.SERVERS['dot-ls'] = [str(a.binary.resolve()), 'lsp']
    b.FIXTURES = Path('/private/tmp/dot-ls-stress-fixtures')
    result = {'binary': str(a.binary.resolve()), 'sha256': hashlib.sha256(a.binary.read_bytes()).hexdigest(),
              'debug_allocator': a.debug_allocator, 'runs': [], 'passed': False}
    def save():
        (a.output/'stress.json').write_text(json.dumps(result, indent=2)+'\n')
    save()
    try:
        if not a.extras_only:
            for mb in sorted(a.sizes):
                for kind in ['plain', 'html']:
                    result['runs'].append(workload(mb, kind, a.cycles, a.edits, a.debug_allocator)); save()
            result['active_shutdowns'] = shutdown_stress(a.shutdowns)
        result['multi_document'] = multi_document()
        result['passed'] = True
    except Exception as error:
        result['failure'] = repr(error)
        raise
    finally:
        save()


if __name__ == '__main__':
    main()
