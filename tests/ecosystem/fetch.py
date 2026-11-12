#!/usr/bin/env python3
"""Fetch selected public upstream releases into an isolated test directory."""
import argparse
import hashlib
import io
import json
import os
import pathlib
import platform
import subprocess
import tarfile
import urllib.request

p = argparse.ArgumentParser()
p.add_argument('destination', type=pathlib.Path)
a = p.parse_args()
manifest = json.loads(pathlib.Path(__file__).with_name('tools.json').read_text())
system = {'Darwin': 'darwin', 'Linux': 'linux'}[platform.system()]
arch = {'arm64': 'arm64', 'aarch64': 'arm64', 'x86_64': 'amd64'}[platform.machine()]
target = f'{system}-{arch}'
root = a.destination.resolve()
(root / 'bin').mkdir(parents=True, exist_ok=True)
for tool, targets in manifest['tools'].items():
    if target not in targets:
        raise SystemExit(f'No verified {tool} asset for {target}')
    entry = targets[target]
    with urllib.request.urlopen(entry['url'], timeout=120) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != entry['sha256']:
        raise SystemExit(f'{tool}: checksum mismatch')
    if entry['format'] == 'tar.gz':
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
            members = [m for m in archive if m.isfile() and pathlib.PurePosixPath(m.name).name == entry['executable']]
            if len(members) != 1:
                raise SystemExit(f'{tool}: expected exactly one executable')
            data = archive.extractfile(members[0]).read()
    binary = root / 'bin' / entry['executable']
    binary.write_bytes(data)
    binary.chmod(0o755)
    print(f'{tool}: {entry["tag"]}, SHA-256 verified', flush=True)
env = {**os.environ, 'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_TERMINAL_PROMPT': '0'}
for name, entry in manifest['sources'].items():
    dest = root / 'src' / name
    dest.mkdir(parents=True, exist_ok=True)
    def git(*args):
        return subprocess.check_output(['git', '-c', 'core.hooksPath=/dev/null', '-C', str(dest), *args], env=env, text=True).strip()
    git('init', '-q')
    git('fetch', '-q', '--depth=1', entry['url'], entry['commit'])
    git('checkout', '-q', '--detach', 'FETCH_HEAD')
    if git('rev-parse', 'HEAD') != entry['commit']:
        raise SystemExit(f'{name}: unexpected commit')
    print(f'{name}: {entry["commit"]}', flush=True)
(root / 'tools.json').write_text(json.dumps(manifest, indent=2) + '\n')
