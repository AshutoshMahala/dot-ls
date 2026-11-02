#!/usr/bin/env python3
"""Protocol extraction checks: error order, borrowed inputs and wire parity."""
import argparse
import copy
import json
from pathlib import Path
import subprocess
import lsp


def checks(binary):
    lsp.BIN = str(Path(binary).resolve())
    transcript = []
    c = lsp.Client()

    def raw(value):
        c.raw(json.dumps(value, ensure_ascii=False).encode())
        reply = c.get()
        transcript.append(reply)
        return reply

    def request(method, params=None, identifier=10):
        value = {'jsonrpc': '2.0', 'method': method, 'id': identifier}
        if params is not None:
            value['params'] = params
        return raw(value)

    def error(reply, code, message):
        assert reply['error'] == {'code': code, 'message': message}, reply

    error(request('textDocument/hover', {}), -32002, 'Server not initialized')
    error(raw({'id': [], 'method': 'initialize', 'jsonrpc': '1.0'}), -32600, 'Invalid request ID')
    error(raw({'id': 'missing'}), -32600, 'Invalid request')
    reply = request('initialize', {'capabilities': {
        'general': {'positionEncodings': ['utf-32', 'utf-8']},
        'workspace': {'workspaceEdit': {'documentChanges': True}},
        'textDocument': {'documentSymbol': {'hierarchicalDocumentSymbolSupport': True}},
    }}, 'init')
    assert reply['result']['capabilities']['positionEncoding'] == 'utf-8'
    error(request('initialize', {}, None), -32600, 'Already initialized')
    error(request('unknown', {}, None), -32601, 'Method not found')
    escaped_id = 'quoted" id\n😀\x00'
    reply = request('unknown', {}, escaped_id)
    assert reply['id'] == escaped_id
    error(reply, -32601, 'Method not found')
    error(raw({'jsonrpc': '1.0', 'id': 'version', 'method': 'textDocument/hover'}), -32600, 'Invalid JSON-RPC version')
    error(request('textDocument/references', {}), -32602, 'References requires a document, position and includeDeclaration boolean.')
    error(request('textDocument/hover', {'textDocument': {'uri': 'untitled:missing'}, 'position': {'line': 0, 'character': 0}}), -32602, 'Completion requires an open document and a non-negative position.')
    base = {'textDocument': {'uri': 'untitled:missing'}, 'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 0}}, 'context': {'diagnostics': [], 'only': 9}}
    error(request('textDocument/codeAction', base), -32602, 'Code actions require an open document.')
    c.open('digraph G {a [label=x}', uri='untitled:test')
    diagnostics = c.diag(1)
    transcript.append(diagnostics)
    params = copy.deepcopy(base)
    params['textDocument']['uri'] = 'untitled:test'
    error(request('textDocument/codeAction', params), -32602, 'Code action kinds must be an array.')
    params['context']['only'] = [9]
    error(request('textDocument/codeAction', params), -32602, 'Code action kinds must be strings.')
    params['context'] = {'diagnostics': [{'data': {'dot_ls_generation': 1}}, {'data': {'dot_ls_generation': 2}}]}
    error(request('textDocument/codeAction', params), -32801, 'Document changed since these diagnostics were produced.')
    params['context']['only'] = []
    assert request('textDocument/codeAction', params)['result'] == []
    params['context'] = {'diagnostics': diagnostics}
    params['range']['end'] = {'line': 0, 'character': 100}
    assert isinstance(request('textDocument/codeAction', params)['result'], list)
    # Ignore an invalid ranged notification. It must not retire current fixes.
    c.send('textDocument/didChange', {'textDocument': {'uri': 'untitled:test', 'version': 9}, 'contentChanges': [{'range': {}, 'text': 'bad'}]})
    error(request('unknown', identifier='barrier'), -32601, 'Method not found')
    assert isinstance(request('textDocument/codeAction', params)['result'], list)
    source = 'digraph G {a [label=x];a -> b;}'
    c.change(source, 2)
    transcript.append(c.diag(2))
    document = {'textDocument': {'uri': 'untitled:test'}}
    assert request('textDocument/documentSymbol', document)['result']
    point = dict(document, position={'line': 0, 'character': source.index('{a') + 1})
    refs = dict(point, context={'includeDeclaration': True})
    assert len(request('textDocument/references', refs)['result']) == 2
    hover = dict(document, position={'line': 0, 'character': source.index('label') + 1})
    assert 'contents' in request('textDocument/hover', hover)['result']
    complete = dict(document, position={'line': 0, 'character': source.index('{a') + 1})
    assert request('textDocument/completion', complete)['result']['items']
    c.send('$/cancelRequest', {'id': None})
    assert request('shutdown')['result'] is None
    error(request('textDocument/hover', {}), -32600, 'Server has shut down')
    c.send('exit')
    c.p.stdin.close()
    assert c.p.wait(timeout=10) == 0
    assert not c.p.stderr.read()
    # Framing failures close the process, rather than generating malformed replies.
    cases = [b'\r\n', b'Content-Length: 1\r\nContent-Length: 1\r\n\r\nx',
             b'Content-Length: 268435457\r\n\r\n', b'invalid\r\n',
             b'Content-Length: 3\r\n\r\nab', b'X: ' + b'x' * 8190 + b'\n']
    for data in cases:
        p = subprocess.run([lsp.BIN, 'lsp'], input=data, capture_output=True, timeout=10)
        assert p.returncode != 0 and p.stdout == b'', (data[:80], p.returncode, p.stdout)
    p = subprocess.run([lsp.BIN, 'lsp'], input=b'', capture_output=True, timeout=10)
    assert p.returncode == 0 and p.stdout == p.stderr == b''
    return transcript


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', nargs='?', default='zig-out/bin/dot-ls')
    parser.add_argument('--compare', type=Path)
    args = parser.parse_args()
    actual = checks(args.binary)
    if args.compare:
        expected = checks(args.compare)
        assert actual == expected, (actual, expected)
    print(f'Protocol boundaries passed: framing, lifecycle/error order, IDs, source updates and {len(actual)} captured replies/findings' + ('; exact baseline parity.' if args.compare else '.'))
