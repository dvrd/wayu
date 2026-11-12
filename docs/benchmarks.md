# Reproducing performance evidence

## Recorded comparison

The landing page displays the dated **2026-11-12 macOS arm64** experiment at
source `67a4d1a`, with 32 raw samples per metric. Retained reports:
[macOS JSON](evidence/benchmark-2026-11-12-macos.json) and
[Linux JSON](evidence/benchmark-2026-11-12-linux.json). Each records its own
commit, binary hash, machine and tool pins. The Linux and macOS results are
separate experiments; the landing does not combine their numbers.

These are recorded measurements, not a claim that every later commit was
remeasured. Current candidates are gated by startup budgets and the
[validation campaign](validation.md). Native/deferred configurations and
simulated completion-generator workloads remain separate in the reports.

## Reproduce

`tests/benchmark/budget.sh` gates CI and releases: a fixed representative
configuration is timed against an empty shell on macOS and Linux. It tests
loaded state before timing, uses interleaved runs, and reports the difference
of medians. This is a regression budget, not a competitor ranking.

`tests/benchmark/compare.sh` compares actual pinned managers using zsh-bench.
Each setup has the same 20 aliases, 10 PATH entries, 5 constants, completion
system and two pinned plugins, with the same minimal prompt. Wayu's built-in
suggestions/highlighting and deferred modes are separate configurations.

Run after building wayu and downloading the pinned Sheldon binary through
the ecosystem fetcher (or supply an installed executable):

```sh
SHELDON_BIN=/tmp/wayu-upstreams/bin/sheldon \
ONLY="floor plain wayu oh-my-zsh antidote sheldon sheldon-static" \
ITERS=32 JSON=/tmp/wayu-comparison.json tests/benchmark/compare.sh
```

Sheldon is measured both with its normal `eval "$(sheldon source)"` startup and
with a pre-generated static loader. The latter must be regenerated when its
configuration changes. These are separate rows, not interchangeable results.
The optional `optimize` scenario uses simulated slow completion generators;
it is not a measurement of real kubectl, gh or helm startup.

## What the report records

- Warmed PTY measurements: first prompt, first command, command/input lag and
  process exit; every raw sample and the median of each metric.
- Detected completion/suggestion/highlighting flags, so missing or deferred
  work is visible. Do not compare a deferred first prompt with fully loaded
  startup as if the same work had finished.
  The upstream detector may not recognize wayu's native features; inspect the
  named configuration as well as the detector flags for those rows.
- One first-process-exit observation for each fresh HOME after setup. Generated
  artifacts may already exist; this diagnostic is neither a cold first-prompt
  latency nor a statistically reliable median.
- UTC date, platform/architecture, shell version, wayu version and binary hash,
  source commit/dirty state, tool/source pins and cache state.

The JSON writer rejects incomplete or non-finite timing samples. The scheduled
and manually triggered ecosystem workflow retains JSON, human-readable output
and the checksum manifest for macOS and Linux. Reports from different machines
should be compared as separate experiments; cloud-runner noise and hardware
differences do not support a universal speed claim.

Each contender has a bounded execution time (`BENCHMARK_TIMEOUT`, default
300 seconds). `RAW_DIR` retains raw output, stderr, startup state and compaudit
diagnostics even on failure. The workflow's quick mode runs floor/plain with
one iteration to diagnose setup problems; it is not performance evidence.
The preflight refuses insecure completion directories so a `compinit`
confirmation cannot consume the PTY handshake. The Linux workflow removes
group/other write permission from the runner's system completion directories;
it keeps the security audit enabled for all contenders.

Use at least 32 iterations for a report you publish, repeat the experiment,
and report distributions and feature flags. Shorter runs are tooling smoke
checks. zsh-bench requires PTY support; a machine unable to allocate a PTY
cannot supply this evidence. Keep failed runs as failures rather than replacing
them with plain `zsh -c exit` results.

The upstream measurement tool is [zsh-bench](https://github.com/romkatv/zsh-bench).
See the pinned revisions and workload in the script. Performance evidence is
separate from [compatibility checks](compatibility.md) and from an independent
security review.
