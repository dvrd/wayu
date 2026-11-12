#!/usr/bin/env python3
"""Bound a benchmark process tree and optionally print process-exit timing."""
import argparse
import os
import signal
import subprocess
import sys
import time

p = argparse.ArgumentParser()
p.add_argument('--seconds', type=float, required=True)
p.add_argument('--elapsed', action='store_true')
p.add_argument('command', nargs=argparse.REMAINDER)
a = p.parse_args()
if not a.command or a.seconds <= 0:
    p.error('a positive deadline and command are required')
start = time.perf_counter()
child = subprocess.Popen(a.command, start_new_session=True,
                         stdout=subprocess.DEVNULL if a.elapsed else None)
try:
    code = child.wait(timeout=a.seconds)
except subprocess.TimeoutExpired:
    os.killpg(child.pid, signal.SIGTERM)
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait()
    print(f'Benchmark command exceeded {a.seconds:g}s: {a.command[0]}', file=sys.stderr)
    raise SystemExit(124)
if code:
    raise SystemExit(code if code > 0 else 128 - code)
if a.elapsed:
    print((time.perf_counter() - start) * 1000)
