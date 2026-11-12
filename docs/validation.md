# Validation before a release

Wayu uses several kinds of evidence: tests of the command contract, memory
checks, real shell sessions, filesystem/process failures, upgrades and
measured startup budgets. A passing run establishes those tested behaviors;
it does not prove that every possible input or system failure is safe.

## Automated gates

Every push to `develop` runs the [CI workflow](https://github.com/dvrd/wayu/actions/workflows/ci.yml).
The release workflow calls that same CI and the startup-budget workflow before
bumping a version or creating a tag. The gates include:

- Odin unit tests with leak and invalid-free tracking, strict compiler checks,
  CLI/integration and golden tests, and TUI behavior tests.
- Linux AddressSanitizer integration tests and native smoke tests of all four
  prebuilt targets.
- A verified previous published binary upgraded to the candidate in Zsh,
  Bash and Fish on macOS and Linux, including the first shell opened after
  replacing the executable.
- Pinned real-upstream compatibility checks and the
  [startup regression budget](benchmarks.md). Comparative benchmark runs are
  separate, dated experiments with their own source and machine metadata.
- A [failure campaign](https://github.com/dvrd/wayu/blob/main/tests/scenarios/campaign.md)
  covering partial writes, permission denial, interrupted lock waits, hard
  termination and a genuinely full filesystem on an isolated Linux tmpfs.
- Twenty repeated fresh sessions for each of Zsh, Bash and Fish on each
  platform: portable PATH, aliases, Unicode/quoted values, documented variable
  expansion, file-backend secrets, run-only non-export, periodic rekey/build,
  turbo export consistency, doctor and private store modes. Homes contain
  spaces. Fresh source installs and available Bash versions are also tried.

The failure tests check persisted state and a subsequent healthy write, rather
than only an exit code. An ordinary write failure must leave the old store
intact. Hard termination may leave the old or new committed entry, but never a
partial entry or invalid JSON. Its twenty seeded kill delays do not guarantee
interruption at a particular syscall.

The risk register has 24 scenarios across 12 dimensions. All 16 high/critical
cases map to runnable checks; low/medium gaps are explicit. The portable
file-size limit produces **EFBIG**; the Linux full-filesystem case produces
**ENOSPC**. Those are different tests, not interchangeable evidence.

## Reproduce and inspect evidence

After building a candidate:

```sh
WAYU_BIN="$PWD/bin/wayu" ruby tests/scenarios/failure_campaign.scenario.test.rb
WAYU_BIN="$PWD/bin/wayu" WAYU_TRIAL_ROUNDS=20 \
WAYU_TRIAL_REPORT=evidence/candidate-trial.json ruby tests/release/candidate_trial.rb
```

The portable campaign also runs in the normal and sanitizer integration suites.
Real ENOSPC requires the isolated mount prepared by
`failure-campaign.yml`; never point its `WAYU_FULL_DISK_ROOT` at a normal disk.

Actions retain unit/integration/TUI logs, source metadata and
`candidate-campaign-<runner>` artifacts. The candidate trial JSON records the
binary SHA-256, version, shell executables and round count; it verifies that
the original candidate and its trial copy remain unchanged. Artifacts are
evidence for their named commit and runner, not a claim about untested builds.

## Observation that automation cannot replace

Repeated automated sessions do not constitute multi-day human use. Before a
public release, retain a dated daily-driver record with:

- Candidate commit and binary hash, OS and shell versions.
- Start/end dates, actual workflows used and any interruptions or recoveries.
- Problems found, reproductions, fixes and the checks rerun afterward.
- The maintainer's acceptance decision and any remaining limitations.

A short automated run cannot honestly fill in elapsed use or human acceptance.
Nothing in this campaign publishes a release or promotes the experimental
multi-machine secrets protocol. Its [independent review](security-review.md)
remains a separate requirement for removing that experimental status.

Power-loss/reboot durability, OOM exhaustion, filesystems beyond the tested
runners, OS argument-size extremes and ciphertext syncs that preserve an older
mtime are not proven by this campaign. The cache and protocol limits are
documented in the [configuration reference](config-reference.md#secrets).
