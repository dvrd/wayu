#!/usr/bin/env python3
"""Archive raw zsh-bench samples alongside reproducibility metadata."""
import argparse
import datetime
import hashlib
import json
import math
import pathlib
import platform
import re
import statistics
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--results', type=pathlib.Path, required=True)
p.add_argument('--output', type=pathlib.Path, required=True)
p.add_argument('--binary', type=pathlib.Path, required=True)
p.add_argument('--zsh', required=True)
p.add_argument('--iters', type=int, required=True)
p.add_argument('--pin', action='append', default=[])
a = p.parse_args()
metrics = ['first_prompt_lag_ms', 'first_command_lag_ms', 'command_lag_ms', 'input_lag_ms', 'exit_time_ms']
results = {}
for path in sorted(a.results.glob('*.raw')):
    raw = path.read_text()
    samples = {}
    for metric in metrics:
        match = re.search(r'^' + metric + r'=\(\s*(.*?)\s*\)$', raw, re.M)
        if not match:
            raise SystemExit(f'{path}: missing {metric}')
        values = [float(v) for v in match.group(1).split()]
        if len(values) != a.iters or not all(math.isfinite(v) and v >= 0 for v in values):
            raise SystemExit(f'{path}: invalid/incomplete {metric} samples')
        samples[metric] = values
    flags = {}
    for flag in ['has_compsys', 'has_autosuggestions', 'has_syntax_highlighting']:
        match = re.search(r'^' + flag + r'=\(\s*(.*?)\s*\)$', raw, re.M)
        if not match:
            raise SystemExit(f'{path}: missing {flag}')
        flags[flag] = [int(v) for v in match.group(1).split()]
        if len(flags[flag]) != a.iters or any(v not in (0, 1) for v in flags[flag]):
            raise SystemExit(f'{path}: invalid/incomplete {flag} samples')
    results[path.stem] = {
        'median_ms': {k: statistics.median(v) for k, v in samples.items()},
        'samples_ms': samples, 'detected_features': flags,
        'cold_first_process_exit_ms': float(path.with_suffix('.cold').read_text()),
    }
if not results:
    raise SystemExit('No benchmark results')
def output(*cmd):
    return subprocess.check_output(cmd, text=True).strip()
report = {
    'schema_version': 1,
    'recorded_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'platform': platform.platform(), 'machine': platform.machine(),
    'zsh': output(a.zsh, '--version'),
    'wayu': output(str(a.binary.resolve()), '--version'),
    'binary_sha256': hashlib.sha256(a.binary.read_bytes()).hexdigest(),
    'source_commit': output('git', 'rev-parse', 'HEAD'),
    'source_dirty': bool(output('git', 'status', '--porcelain')),
    'pins': dict(item.split('=', 1) for item in a.pin),
    'iterations': a.iters, 'cache_state': 'warmed',
    'cold_note': 'One first process-exit observation per fresh HOME after setup; generated artifacts may already exist. Not first-prompt latency or a median.',
    'deferred_note': 'Deferred plugins may not be loaded at the first command. Compare detected feature flags before comparing timings.',
    'results': results,
}
a.output.parent.mkdir(parents=True, exist_ok=True)
a.output.write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')
print(f'wrote {a.output}')
