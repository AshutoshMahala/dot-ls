#!/usr/bin/env python3
"""Stage prebuilt packages in a NEW isolated Zed profile for offline testing.

This is a local test harness, not a marketplace installer. Never touches the
user's normal Zed installation, extension cache or project settings.
"""
import argparse
import json
from pathlib import Path
from check_release import contents, extract, native_header
import package_release as package


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--extension', type=Path, required=True)
    p.add_argument('--server', type=Path, required=True)
    p.add_argument('--profile', type=Path, required=True)
    a = p.parse_args()
    assert not a.profile.exists(), 'Use a new profile path; existing data is never replaced'
    ext = contents(a.extension); server = contents(a.server)
    meta = json.loads(server['RELEASE.json'][0]); version = meta['version']; target = meta['target']
    assert json.loads(ext['RELEASE.json'][0])['version'] == version
    native_header(server['dot-ls'][0], target)
    assert package.digest(server['dot-ls'][0]) == meta['binary_sha256']
    # Zed scans installed extension payloads when a fresh profile starts. Seed
    # the exact versioned managed cache to exercise offline resolution in WASM.
    extract(ext, a.profile/'extensions/installed/dotls')
    extract(server, a.profile/f'extensions/work/dotls/dot-ls-{version}-{target}')
    project = a.profile/'sample'; project.mkdir()
    (project/'sample.dot').write_text('digraph {\n  start [shape=box];\n  start -> finish;\n  broken [color=red\n}\n')
    settings = project/'.zed'; settings.mkdir()
    (settings/'settings.json').write_text(json.dumps({'file_types': {'DOT (dot-ls)': ['*.dot']},
        'languages': {'DOT (dot-ls)': {'language_servers': ['dotls'], 'document_symbols': 'on'}}}, indent=2)+'\n')
    # No absolute server path is configured. The prebuilt extension must locate
    # the seeded managed binary, with no toolchain, checkout or network access.
    print(json.dumps({'profile': str(a.profile.resolve()), 'project': str(project.resolve()),
                      'server': str((a.profile/f'extensions/work/dotls/dot-ls-{version}-{target}/dot-ls').resolve())}, indent=2))


if __name__ == '__main__':
    main()
