# Reproducing performance evidence

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

Use at least 32 iterations for a report you publish, repeat the experiment,
and report distributions and feature flags. Shorter runs are tooling smoke
checks. zsh-bench requires PTY support; a machine unable to allocate a PTY
cannot supply this evidence. Keep failed runs as failures rather than replacing
them with plain `zsh -c exit` results.

The upstream measurement tool is [zsh-bench](https://github.com/romkatv/zsh-bench).
See the pinned revisions and workload in the script. Performance evidence is
separate from [compatibility checks](compatibility.md) and from an independent
security review.
