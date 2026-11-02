#!/usr/bin/env python3
"""Run one check command in GitHub Actions and pass on its exit code.

On failure, repeat the last 40 output lines as an error annotation. The run page
shows annotations to everyone; GitHub shows full job logs only after sign-in.
"""
import subprocess
import sys


def escape(text, extra=''):
    text = text.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
    for char in extra:
        text = text.replace(char, f'%{ord(char):02X}')
    return text


def main():
    command = sys.argv[1:]
    assert command, 'usage: ci_report.py COMMAND [ARGS...]'
    tail = []
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors='replace')
    for line in process.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        tail = (tail + [line.rstrip('\n')])[-40:]
    code = process.wait()
    if code:
        title = escape(' '.join(command) + ' failed', ':,')
        print(f'::error title={title}::{escape(chr(10).join(tail))}', flush=True)
    sys.exit(code)


if __name__ == '__main__':
    main()
