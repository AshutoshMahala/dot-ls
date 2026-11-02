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
        # `zig build test` can report only "failed without output". Run a failed
        # test binary again without the build protocol to get the error name.
        for line in list(tail):
            if line.startswith('failed command: ') and line.endswith(' --listen=-'):
                rerun = subprocess.run(line[len('failed command: '):-len(' --listen=-')].split(), stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True, errors='replace', timeout=600)
                print(rerun.stdout, flush=True)
                tail = (tail + ['--- direct run of the test binary ---'] + rerun.stdout.splitlines())[-40:]
        title = escape(' '.join(command) + ' failed', ':,')
        print(f'::error title={title}::{escape(chr(10).join(tail))}', flush=True)
    sys.exit(code)


if __name__ == '__main__':
    main()
