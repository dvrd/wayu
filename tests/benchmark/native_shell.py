#!/usr/bin/env python3
"""Measure native Wayu workloads in isolated homes. Times are milliseconds."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import pty
import re
import select
import signal
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
READY = b'\x1b[?2004h'
REDRAW = b'\x1b[0m\r'
MIB = 1024 * 1024
CASES = {'first_prompt_empty', 'first_prompt_history', 'redraw', 'paste_undo', 'live_command'}
CASES.update(f'{mode}_{size}' for mode in ('stream', 'capture') for size in (0, 1, 4))


def environment(home):
    return {'PATH': '/usr/bin:/bin', 'HOME': str(home), 'WAYU_CONFIG_DIR': str(home / 'config'),
            'WAYU_DATA_DIR': str(home / 'data'), 'XDG_DATA_HOME': str(home / 'share'),
            'HISTFILE': str(home / 'foreign'), 'SHELL': '/bin/bash', 'NO_COLOR': '1',
            'TERM': 'xterm', 'LC_ALL': 'C'}


def until(fd, marker, after=None):
    data = bytearray()
    deadline = time.monotonic() + 10
    while (after is not None and after not in data) or marker not in (data.partition(after)[2] if after else data):
        if not select.select([fd], [], [], max(0, deadline - time.monotonic()))[0]:
            raise RuntimeError(f'PTY timeout awaiting {marker!r}: {data[-180:]!r}')
        chunk = os.read(fd, 65536)
        if not chunk:
            raise RuntimeError('early PTY EOF')
        data.extend(chunk)
    return bytes(data)


def rss(usage):
    return usage.ru_maxrss * (1 if sys.platform == 'darwin' else 1024)


def elapsed(start):
    return (time.perf_counter_ns() - start) / 1e6


def interactive(binary, home, history):
    data = home / 'data'
    data.mkdir()
    if history:
        (data / 'history.jsonl').write_text(''.join(json.dumps(f'echo previous {i}') + '\n'
                                                   for i in range(4096)))
    env = environment(home)
    start = time.perf_counter_ns()
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(home)
        os.execve(str(binary), [str(binary)], env)
    try:
        until(fd, REDRAW)
        samples = {'first_prompt_history' if history else 'first_prompt_empty': elapsed(start)}
        start = time.perf_counter_ns()
        os.write(fd, b'e')
        until(fd, REDRAW, after=b'wayu> e')
        samples['redraw'] = elapsed(start)
        start = time.perf_counter_ns()
        os.write(fd, b'\x1b[200~BAD\x1b[201~\x1f')
        os.write(fd, b'cho pasted\r')
        output = until(fd, READY)
        if b'\x1b[?2004lpasted\r\n' not in output:
            raise RuntimeError(f'paste/undo changed the submitted command: {output[-250:]!r}')
        samples['paste_undo'] = elapsed(start)
        start = time.perf_counter_ns()
        for i in range(3):
            os.write(fd, f'echo live{i}\r'.encode())
            if f'\x1b[?2004llive{i}\r\n'.encode() not in until(fd, READY):
                raise RuntimeError('live command output mismatch')
        samples['live_command'] = elapsed(start) / 3
        os.write(fd, b'\x04')
        until(fd, b'\x1b[?2004l')
        _, status, usage = os.wait4(pid, 0)
        pid = None
        if status:
            raise RuntimeError(f'Wayu PTY exited {status}')
        return {key: {'ms': value, 'rss_bytes': rss(usage)} for key, value in samples.items()}
    finally:
        if pid is not None:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)
        os.close(fd)


def batch(binary, home, mode, size):
    fixture = home / 'input'
    fixture.write_bytes(b'x' * (size * MIB))
    cmd = ('/bin/cat "$FILE" | wc -c' if mode == 'stream' else
           'v=$(/bin/cat "$FILE"); unset v; echo captured')
    with tempfile.TemporaryFile() as output:
        start = time.perf_counter_ns()
        pid = os.posix_spawn(str(binary), [str(binary), '-c', cmd], {**environment(home), 'FILE': str(fixture)},
                             file_actions=[(os.POSIX_SPAWN_DUP2, output.fileno(), 1)])
        _, status, usage = os.wait4(pid, 0)
        ms = elapsed(start)
        output.seek(0)
        result = output.read().strip()
        if status or result != (b'captured' if mode == 'capture' else str(size * MIB).encode()):
            raise RuntimeError(f'{mode}: status {status}, output {result!r}')
        return {'ms': ms, 'rss_bytes': rss(usage)}


def validate(run, minimum):
    if set(run['samples']) != CASES:
        raise ValueError('missing native workload')
    for key, rows in run['samples'].items():
        if len(rows) < minimum or any(not math.isfinite(r['ms']) or r['ms'] <= 0 or r['rss_bytes'] <= 0 for r in rows):
            raise ValueError(f'invalid samples for {key}')


def capture_accounting():
    with tempfile.TemporaryDirectory() as d:
        home = Path(d)
        exe = home / 'wayu'
        subprocess.run(['odin', 'build', 'src', '-o:speed', '-define:WAYU_NATIVE_METRICS=true',
                        f'-out:{exe}'], cwd=ROOT, check=True)
        fixture = home / 'fixture'
        fixture.write_bytes(b'x' * (4 * MIB))
        env = {**environment(home), 'FILE': str(fixture)}
        def fnv64a(value):
            digest = 0xcbf29ce484222325
            for byte in value:
                digest = ((digest ^ byte) * 0x100000001b3) & 0xffffffffffffffff
            return format(digest, '016x')

        for source in ['v=$(/bin/cat "$FILE")', 'v="$(/bin/cat "$FILE")"', 'v="a$(/bin/cat "$FILE")b"',
                       'v=$(printf %s "$(printf ok)")']:
            p = subprocess.run([exe, '-c', source + '; unset v'], env=env, capture_output=True, text=True, check=True)
            print(p.stderr, end='')
            expected = 2 if 'printf' in source else len(fixture.read_bytes())
            assert f'wayu-capture raw={expected} ' in p.stderr
            extra = 2 if source.startswith('v="a') else 0
            assert f'wayu-assignment bytes={expected + extra}' in p.stderr
            value = b'ok' if 'printf' in source else b'x' * expected
            if extra:
                value = b'a' + value + b'b'
            assert f'fnv64a={fnv64a(value)}' in p.stderr
            assert f'wayu-local-release bytes={len(value)}' in p.stderr
            assert 'wayu-expansion bytes=' in p.stderr
        repeated = subprocess.run([exe, '-c', 'v=$(printf first); unset v; v=$(printf next); unset v'],
                                  env=env, capture_output=True, text=True, check=True)
        assert repeated.stderr.count('wayu-local-release bytes=') == 2
        check = subprocess.check_output([exe, '-c', 'printf "%s" "left$(printf right)"'], env=env)
        assert check == b'leftright'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--revision', help='Source revision of the binary being measured')
    p.add_argument('--capture-accounting', action='store_true')
    p.add_argument('--binary', type=Path, default=ROOT / 'bin/wayu')
    p.add_argument('--smoke', action='store_true')
    p.add_argument('--iterations', type=int, default=32)
    p.add_argument('--output', type=Path)
    p.add_argument('--check-report', type=Path)
    args = p.parse_args()
    if args.capture_accounting:
        capture_accounting()
        return
    if args.check_report:
        runs = json.loads(args.check_report.read_text())['runs']
        for run in runs:
            validate(run, 32)
            if not re.fullmatch('[0-9a-f]{64}', run['binary_sha256']) or not all(
                    run[k] for k in ('revision', 'runner', 'machine', 'platform', 'compiler', 'features')):
                raise ValueError('incomplete native benchmark provenance')
        for system in ('Linux', 'Darwin'):
            for stage in ('baseline', 'candidate'):
                group = [r for r in runs if r['os'] == system and r['stage'] == stage]
                if len(group) < 2 or len({r['binary_sha256'] for r in group}) != 1:
                    raise ValueError(f'missing comparable repeated {system} {stage} measurements')
        return
    binary = args.binary.resolve()
    n = 1 if args.smoke else args.iterations
    run = {'os': platform.system(), 'platform': platform.platform(), 'machine': platform.machine(),
           'runner': os.environ.get('RUNNER_NAME', 'local'), 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
           'revision': args.revision or subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
           'compiler': subprocess.check_output(['odin', 'version'], text=True).strip(),
           'features': {'history_records': 4096, 'live_commands': 3, 'pty': True},
           'samples': {key: [] for key in sorted(CASES)}}
    for i in range(n):
        for history in (False, True):
            with tempfile.TemporaryDirectory() as d:
                for k, obs in interactive(binary, Path(d), history).items():
                    if not history or k == 'first_prompt_history':
                        run['samples'][k].append(obs)
        for size in (0, 1, 4):
            for mode in (('stream', 'capture') if i % 2 == 0 else ('capture', 'stream')):
                with tempfile.TemporaryDirectory() as d:
                    run['samples'][f'{mode}_{size}'].append(batch(binary, Path(d), mode, size))
    validate(run, n)
    for key, rows in run['samples'].items():
        times = sorted(row['ms'] for row in rows)
        print(f'{key:20} p50 {statistics.median(times):8.3f} ms  p95 {times[math.ceil(.95*n)-1]:8.3f} ms')
    if args.output:
        args.output.write_text(json.dumps(run, indent=2) + '\n')


if __name__ == '__main__':
    main()
