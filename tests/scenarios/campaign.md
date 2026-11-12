# Failure campaign and candidate acceptance

This is a risk register and executable acceptance campaign for the current CLI, not a proof that every failure is covered. Scores are prioritization judgments: likelihood 1–5 × impact 1–5; critical ≥20, high 12–19, medium 6–11, low 1–5. All 12 dimensions have two concrete cases. Remote-account authentication does not apply to a local shell manager; the Auth dimension covers local cache permissions and run-only boundaries. Network tests use local/fake transports, never third-party targets.

The data flow is CLI/TOML/JSON input → validation/parsing → locked mutation →
backed-up atomic replacement → generated runtimes and cache invalidation →
exit status or JSON. Filesystem writes, Git children and real shell startup
are the external interfaces. Config/data files, child output and the running
environment are separate input boundaries. The tests assert persisted state
and subsequent recovery, not only a command's exit code.

24 scenarios: {'CRITICAL': 1, 'HIGH': 15, 'MEDIUM': 7, 'LOW': 1}. Every high/critical case maps to a runnable test or an existing CI suite on the same candidate commit.

| ID | Dimension | Scenario | L×I | Priority | Production path | Test/evidence |
|---|---|---|---|---|---|---|
| CO1 | Concurrency | Concurrent first writers must preserve every committed entry | 4×5=20 | CRITICAL | `src/atomic_io.odin:234` | `ruby tests/integration/test_write_integrity.rb`; ordinary + ASan integration |
| IN1 | Invalid Input | Malformed entries must not be overwritten | 3×5=15 | HIGH | `src/entries.odin:128` | `ruby tests/integration/test_write_integrity.rb`; ordinary + ASan integration |
| DI1 | Data Integrity | Restoring entries must keep paired encrypted values consistent | 3×5=15 | HIGH | `src/backup.odin:505` | `ruby tests/integration/test_secrets_store.rb`; ordinary + ASan integration |
| DI2 | Data Integrity | Hard termination must expose a valid old or new store | 3×5=15 | HIGH | `src/atomic_io.odin:38` | `ruby tests/scenarios/failure_campaign.scenario.test.rb`; portable campaign + ASan; 20 seeded kill delays, exact phase uncontrolled |
| FA1 | Failure | Real ENOSPC must fail without replacing the live store and permit recovery | 3×5=15 | HIGH | `src/entries.odin:829` | `ruby tests/scenarios/failure_campaign.scenario.test.rb --require-enospc`; Linux failure-campaign job; actual ENOSPC, not EFBIG |
| FA2 | Failure | An error during a partial atomic write must preserve the prior store | 3×5=15 | HIGH | `src/atomic_io.odin:38` | `ruby tests/scenarios/failure_campaign.scenario.test.rb`; portable campaign + ASan; kernel RLIMIT_FSIZE/EFBIG |
| MI1 | Migration | A published binary upgrade must preserve the first new shell and encrypted values | 3×5=15 | HIGH | `src/main.odin:188` | `ruby tests/release/upgrade.rb`; previous-release upgrade job; zsh/bash/fish on both OSes |
| BO1 | Boundary | Missing arguments and empty names must fail before mutation | 4×3=12 | HIGH | `src/cli_parser.odin:441` | `ruby tests/integration/test_exit_codes.rb`; ordinary + ASan integration |
| CO2 | Concurrency | Terminating a lock waiter must preserve state and permit later writes | 3×4=12 | HIGH | `src/atomic_io.odin:234` | `ruby tests/scenarios/failure_campaign.scenario.test.rb`; portable campaign + ASan |
| NE1 | Network | A stalled Git helper must time out and leave no partial installed plugin | 3×4=12 | HIGH | `src/plugin_ops.odin:141` | `ruby tests/integration/test_plugin.rb`; ordinary + ASan integration; offline fake transport |
| AU1 | Auth | Private secret-cache paths must reject unsafe permissions | 3×4=12 | HIGH | `src/secrets_store.odin:892` | `./build_it test test_wayu.test_secrets_cache_dir_check`; unit; local filesystem access boundary, no remote auth service |
| AU2 | Auth | Run-only secrets must stay out of fresh shell exports | 3×4=12 | HIGH | `src/secrets_store.odin:912` | `ruby tests/release/candidate_trial.rb`; candidate trial; fixture secrets/file backend |
| SC2 | Scale | Large stdin with simultaneous stderr output must not deadlock or exceed capture bounds | 3×4=12 | HIGH | `src/subprocess.odin:475` | `./build_it test test_wayu.test_clipboard_stdin_early_close_and_large_transfer`; unit; 1 MiB input and 100 KiB output |
| US1 | User Error | Dry-run and missing confirmation must not mutate stores or run hooks | 4×3=12 | HIGH | `src/cli_parser.odin:441` | `ruby tests/integration/test_dry_run.rb`; ordinary + ASan integration |
| CF1 | Config | Relative config/data overrides must be rejected before writing | 4×3=12 | HIGH | `src/main.odin:188` | `ruby tests/integration/test_write_integrity.rb`; ordinary + ASan integration |
| CF2 | Config | A read-only data directory must fail without corruption and recover after permissions return | 3×4=12 | HIGH | `src/entries.odin:829` | `ruby tests/scenarios/failure_campaign.scenario.test.rb`; portable campaign + ASan; refuses to misreport a root run as a permission test |
| MI2 | Migration | Opt-in v1-to-v2 migration must retain values and restore rewrapping | 2×5=10 | MEDIUM | `src/secrets_recipients.odin:2718` | `ruby tests/integration/test_secrets_multi.rb`; ordinary + ASan integration; v2 stays experimental |
| NE2 | Network | An unreachable restore remote must roll back newly created checkouts | 3×3=9 | MEDIUM | `src/plugin_restore.odin:6` | `ruby tests/integration/test_plugin_restore.rb`; ordinary + ASan integration; local Git fixtures |
| TI2 | Time | Watched files appearing and disappearing must trigger changes | 3×3=9 | MEDIUM | `src/hot_reload.odin:427` | `./build_it test test_wayu.test_watch_detects_created_and_deleted_files`; unit; no calendar/DST dependence in monotonic subprocess deadlines |
| US2 | User Error | Pasted text, Unicode and quoted values must survive input and fresh sessions | 3×3=9 | MEDIUM | `src/tui_io.odin:944` | `python3 tests/tui/test_responsive.py`; TUI job; candidate trial additionally checks Unicode/quoted values |
| IN2 | Invalid Input | Deeply nested TOML must stop at its parser cap | 2×4=8 | MEDIUM | `src/toml_parse.odin:562` | `./build_it test test_wayu.test_toml_parser_nesting_cap`; unit |
| TI1 | Time | Synced ciphertext with preserved older mtime can leave a stale session cache | 2×3=6 | MEDIUM | `src/secrets_store.odin:864` | `NO_TEST`; Documented limit in docs/security-review.md and config reference; no stronger invalidation guarantee claimed. |
| SC1 | Scale | Large TOML documents must parse without a fixed arena overflow | 2×3=6 | MEDIUM | `src/toml.odin:159` | `./build_it test test_wayu.test_toml_parse_large_config`; unit; bounded correctness test, not load benchmarking |
| BO2 | Boundary | An argument beyond the OS exec size limit must not be mistaken for success | 1×3=3 | LOW | `src/subprocess.odin:475` | `NO_TEST`; Not directly tested; OS ARG_MAX differs. Large valid inputs are covered by SC2/FA2. |

## Run

Build once, then run the portable failure cases and the automated candidate trial:

```sh
./build_it build
WAYU_BIN="$PWD/bin/wayu" ruby tests/scenarios/failure_campaign.scenario.test.rb
WAYU_BIN="$PWD/bin/wayu" WAYU_TRIAL_ROUNDS=20 \
WAYU_TRIAL_REPORT=evidence/candidate-trial.json ruby tests/release/candidate_trial.rb
```

The portable cases also run through `tests/integration/test_failure_campaign.rb`, including under AddressSanitizer. Full unit, integration and TUI suites supply the existing mapped cases; `.github/workflows/ci.yml` runs all of them. The reusable `failure-campaign.yml` adds the actual-full-filesystem case on an isolated 8 MiB Linux tmpfs, repeated sessions on both OSes, Bash-version trials, and retained evidence. It runs in release CI before a version/tag is created.

The ENOSPC root is supplied only by that CI mount. The script fills it deliberately; do not point `WAYU_FULL_DISK_ROOT` at a normal disk. The portable per-file limit generates EFBIG and is explicitly not a substitute for ENOSPC. Permission-denial testing refuses to run as root rather than falsely pass.

## Candidate gates

- Exact candidate commit/binary identified in CI; trial JSON retains the binary SHA-256, version, shell executables and round counts. The trial checks that the copied binary and original remain unchanged.
- Unit/memory tracking, integration, TUI, strict compiler, four-target build/smoke, upgrade, ecosystem and startup-budget jobs must pass on develop.
- All high/critical rows above must have passing evidence. New process/filesystem failures preserve readable committed state and allow a subsequent healthy mutation.
- The automated trial completes 20 fresh sessions per shell per OS: PATH portability, alias replacement, Unicode/quoted constants and documented variable expansion, file-backend secrets, lock/reload, run-only non-export, periodic rekey/build, turbo export consistency, doctor and private store modes. HOME includes spaces.
- A failed trial exits nonzero. The legacy Bash/fresh-shell trial scripts now do too; the Bash script previously printed failures but returned success, reproduced with `/usr/bin/false` as its candidate.

## Limits and next observation

Automated repeated sessions are not multi-day human use. Before a public release, retain a maintainer's dated daily-driver record (candidate hash, OS/shell, elapsed use, observed problems and recovery); that observation cannot be manufactured by a short automated run. No public release or main-branch push is implied by this campaign.

Real power-loss/reboot durability, resource-exhaustion OOM, platform filesystems beyond the runners, OS ARG_MAX extremes and preserved-mtime cache invalidation are not proven here. Hard-kill delays are seeded but do not deterministically interrupt a particular write syscall; readers are checked after every interruption. The mtime cache limit remains documented. Experimental secrets v2 stays experimental pending independent review (`docs/security-review.md`); these tests do not promote it.
