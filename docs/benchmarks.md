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

## Native shell resources

Run `python3 tests/benchmark/native_shell.py --binary ./bin/wayu --smoke` to exercise the workloads. Omit `--smoke` and pass `--output run.json` for 32 samples per workload. Keep the pinned Odin compiler on PATH to record its version. The harness opens a real PTY in a fresh home, waits for the first completed redraw, types a key, pastes and undoes text, and checks the actual output of three commands in the same session. The history case starts with 4,096 JSONL records. Separate processes stream or capture 0, 1 and 4 MiB. The stream checks the byte count. The capture assigns the value, releases it and checks successful completion. The accounting build also verifies the assigned value's length and digest.

The raw report includes two baseline and two candidate runs per platform, all on ARM64. Darwin ran on a Mac and Linux in a Podman VM on that Mac. Each sample records milliseconds and maximum RSS from `wait4`. PTY observations within a session share its process RSS. On Darwin, descendant activity can influence the reported maximum. RSS includes allocator and process overhead. Use the test-build byte counters to attribute allocations. The Linux baseline needed one correction to decode a normal child exit. The unmodified baseline returned 128 for a successful command and failed the benchmark's status check. [Raw distributions](evidence/native-resources.json)

Each pair below gives the median for the first and second run. The JSON includes every sample for computing percentiles.

| Platform | Build | First prompt with history (ms) | Key to redraw (ms) | 4 MiB capture RSS (MiB) | 4 MiB stream RSS (MiB) |
|---|---|---:|---:|---:|---:|
| Darwin | baseline | 9.4 / 8.5 | 8.2 / 7.3 | 25.0 / 25.0 | 5.4 / 5.4 |
| Darwin | candidate | 9.1 / 8.7 | 7.9 / 8.0 | 21.1 / 21.1 | 5.4 / 5.4 |
| Linux | baseline | 5.7 / 5.9 | 3.8 / 3.8 | 22.9 / 22.9 | 22.5 / 22.6 |
| Linux | candidate | 5.6 / 5.1 | 3.7 / 3.5 | 22.5 / 22.5 | 22.5 / 22.5 |

The Linux samples show a process RSS floor near 22.5 MiB even for streaming. The 0.4 MiB baseline-to-candidate difference there is close to that floor. On this Mac, the 4 MiB capture used about 4 MiB less peak RSS in both candidate runs.

The native budgets are opt-in: the proposed default for `capture_bytes`, `undo_bytes`, `history_bytes` and `history_entries` is `0`, unlimited. Four MiB exercises a large substitution, but a shell script can legitimately require more, and no measured value is one that every existing command and edit stays under. Peak RSS and latency in a VM also depend on other work on the host. The fixed CI gates check bytes, contents, statuses and editor behavior. Timing distributions are available on manual runs. The host Bash and Zsh startup thresholds still run on each change.

| Owner | What counts | When storage is released |
|---|---|---|
| Command substitution | Raw stdout before trailing newline removal, per substitution and evaluator. Nested substitutions each have a limit. The expansion builder can reserve more than the raw payload. | Assignment and quoted words receive bytes directly in their expansion buffer. A local owns one copy until replacement or `unset`. Expansion scratch belongs to the current submission. Overflow discards the expansion and cancels its process group. |
| Undo and redo | Each retained edit's record and the inserted and removed bytes. A 4,096-key line retains four times the edit bytes of a 1,024-key line. Cursor movement reuses the same record. | A new edit releases redo. The byte limit evicts the oldest edits. An edit larger than the limit clears the ledger and still changes the line. Submission releases the ledger. Redraw scratch lasts for one frame. |
| History | Each source has its own byte and entry window. The byte count covers decoded text. A partial JSON record can require up to six encoded bytes per source byte plus quotes. | Eviction releases the resident command. Native history stays on disk. Recall can temporarily allocate one larger record and the selected editable line. Foreign history supplies suggestions only. |

`python3 tests/benchmark/native_shell.py --capture-accounting` builds a separate instrumented executable and checks plain, quoted, nested and repeated substitutions. It reports raw bytes, final buffer capacity, the largest sum of old and new capacities during a moving resize, assignment copies and releases. `--check-report docs/evidence/native-resources.json` validates the sample counts and run metadata.
