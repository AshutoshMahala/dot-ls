#!/usr/bin/env python3
"""Presentation contracts: negotiated hover, examples, plain diagnostics and fixes."""
from lsp import Client
def request(c, method, point):
    c.send('textDocument/' + method, {'textDocument': {'uri': 'untitled:test'},
           'position': point}, 60)
    while True:
        reply = c.get()
        if reply.get('id') == 60:
            return reply
        assert reply.get('method') == 'textDocument/publishDiagnostics', reply


for formats, expected in [(None, 'plaintext'), (['markdown', 'plaintext'], 'markdown'),
                          (['plaintext', 'markdown'], 'plaintext'), ([], 'plaintext'),
                          (['unsupported'], 'plaintext'), ([None, {}, 'markdown'], 'markdown'),
                          ('markdown', 'plaintext')]:
    c = Client()
    hover = {} if formats is None else {'contentFormat': formats}
    c.send('initialize', {'capabilities': {'textDocument': {'hover': hover}}}, 1)
    assert 'result' in c.get()
    c.send('initialized', {})
    c.open('digraph { start [shape=box]; }')
    reply = request(c, 'hover', {'line': 0, 'character': 18})['result']
    assert reply['contents']['kind'] == expected, reply
    value = reply['contents']['value']
    assert 'start [shape=box];' in value and 'https://graphviz.org/docs/attrs/shape/' in value
    assert 'ellipse' in value and 'node' in value
    if expected == 'markdown':
        assert value.startswith('**`shape`**\n\n')
        assert '- **Default:** `ellipse`' in value and '```dot\n' in value
    else:
        assert value.startswith('shape\n\n') and '**' not in value and '```' not in value
    # Endpoints use readable source-independent text, not Markdown/ANSI styling.
    c.change('digraph { start -> }', 2)
    diagnostics = c.diag(2)
    text = diagnostics[0]['message']
    assert text.startswith("Expected a node name or subgraph; found '}'.\n"), text
    assert len(text.splitlines()[0]) < 80 and '\x1b' not in text and '**' not in text
    c.change('digraph { start [color=red }', 3)
    text = c.diag(3)[0]['message']
    assert text == "Missing closing ']' before '}'.\nClose the attribute list with ']'.", text
    c.change('digraph { start;', 4)
    text = c.diag(4)[0]['message']
    assert text == "Missing closing '}' at end of input.\nClose the graph or subgraph with '}'.", text
    c.stop()

print('Templates: Markdown/plaintext preference, malformed capabilities, example, link and plain diagnostic passed.')
