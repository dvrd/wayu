# Contributing to wayu

For candidate acceptance, see [Validation](docs/validation.md) and
[the failure campaign](tests/scenarios/campaign.md).
It maps 24 scenarios across 12 risk dimensions to executable checks, including
an isolated full-filesystem test in Linux CI and repeated fresh-shell trials
on macOS and Linux. Run the portable campaign with
`WAYU_BIN="$PWD/bin/wayu" ruby tests/scenarios/failure_campaign.scenario.test.rb`
and the automated session trial with
`WAYU_BIN="$PWD/bin/wayu" ruby tests/release/candidate_trial.rb` after building.
The trial is automated evidence; a dated daily-driver observation and the
experimental secrets-v2 independent review remain separate acceptance records.

Thanks for helping. This page covers building, testing, the branch flow and
the commit rules that drive releases. Code conventions are in
[`CODE_STYLE.md`](CODE_STYLE.md); the source map is in
[`AGENTS.md`](AGENTS.md) ("Key Source Files").

Questions and ideas go to [Discussions](https://github.com/dvrd/wayu/discussions);
bugs and feature requests to [issues](https://github.com/dvrd/wayu/issues/new/choose).
Security problems: [report them privately](https://github.com/dvrd/wayu/security/advisories/new)
(see [`SECURITY.md`](SECURITY.md)), never in a public issue.

**No secrets in issues, pull requests or test fixtures.** `wayu doctor` never
prints secret values, but it prints paths (your home directory, user name),
and config files, `entries.json` or `env` output can hold API keys: replace
them with `<redacted>` before pasting.

## Prerequisites

- The [Odin compiler](https://odin-lang.org/docs/install/) at the release named
  in [`.github/odin-release`](.github/odin-release). CI and releases use exactly
  that release; `./build_it` warns when your `odin` differs.
- Ruby 3.x for the integration tests.
- zsh, bash and fish on `PATH` (the integration tests source the generated
  shell code with each).
- Python 3 with [`pyte`](https://pypi.org/project/pyte/) for the TUI tests
  (`pip install pyte`, a virtualenv is fine).

## Build

`./build_it` is the build tool (an Odin program, source in
`build/build.odin`). Bootstrap it once:

```bash
odin build build -out:build_it
```

```bash
./build_it            # optimized build → bin/wayu
./build_it debug      # debug symbols + ODIN_DEBUG → bin/wayu_debug
./build_it check      # type-check only (fastest compile check)
./build_it help       # all targets
```

## Test

Run these before opening a pull request; CI runs the same set.

```bash
./build_it test                                   # unit tests (tests/unit/); leaks and bad frees fail
./build_it test test_wayu.test_x,test_wayu.test_y # only these unit tests
ruby tests/integration/run_all.rb                 # every integration suite (incl. golden files)
python3 tests/tui/test_responsive.py              # TUI layout + behavior (uses bin/wayu, or $WAYU_BIN)
odin build src -out:bin/lint -vet -warnings-as-errors   # the CI lint
tests/benchmark/budget.sh                         # startup-time budget (uses bin/wayu)
```

`tests/benchmark/budget.sh` times `zsh -i -c exit` and `bash -i -c exit` with a
fixed config against an empty rc and fails when wayu adds more than
max(30 ms, 2x the empty shell); CI runs it on Linux and macOS. Run it when you
touch generated shell code (`src/init_generator.odin`, `src/preload.odin`, the
prompt, plugins, secrets loading).

The tests run in a temporary `HOME`. When you try wayu by hand, do the same so
your real `~/.config/wayu` and shell startup are untouched:

```bash
HOME=$(mktemp -d) ./bin/wayu init
```

Golden files for TUI components live in `tests/golden/`; each needs a line in
`tests/golden/cases.txt`. `ruby tests/integration/test_golden.rb` compares them
all (`run_all.rb` includes it). Regenerate one with
`./bin/wayu -c=<component> --snapshot <args>` and review the diff.

Release verification also upgrades a verified published binary to the current
candidate in temporary homes. To reproduce with a downloaded release:

```bash
WAYU_PREVIOUS_BIN=/path/to/released/wayu WAYU_BIN=$PWD/bin/wayu ruby tests/release/upgrade.rb
```

The pinned real-upstream suite and benchmark workflow are described in
[docs/compatibility.md](docs/compatibility.md) and
[docs/benchmarks.md](docs/benchmarks.md). They require network access and
temporary upstream binaries, separate from offline integration tests.
The release workflow depends explicitly on both CI and startup budgets;
CI includes previous-binary upgrades and upstream compatibility on macOS/Linux.
The pending independent secrets review has a [review brief](docs/security-review.md).

## Formatting

Format every Odin file you touch with `odinfmt` (from
[ols](https://github.com/DanielGavin/ols)); it picks up the repo's
`odinfmt.json`: `odinfmt -w src/foo.odin`. Skip `src/rune_width_table.odin`
(generated). Running it twice must change nothing.

## Branches

- **`develop`** is the integration branch. Branch from it and open pull
  requests against it. Pushes to `develop` run CI and never release.
- **`main`** is release-only: every push to `main` cuts a release (version
  bump, GitHub release, Homebrew formula). The maintainer merges `develop` into
  `main` when a batch is ready to ship. Pull requests into `main` are accepted
  only from `develop` or `hotfix/*`; pull requests from forks target `develop`.

## Commits

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/).
The release version is derived from them by
[`git-cliff`](https://git-cliff.org/) (`cliff.toml`):

| Commit | Release |
|---|---|
| `feat: …` | minor |
| `fix: …`, `refactor: …`, `docs: …`, anything else | patch |
| `type!: …` or a `BREAKING CHANGE: <what users must know>` footer | major |

**Any user-visible behavior change is breaking**, even when it is a bug fix:
output, exit codes, flags, generated shell code, or config semantics. Mark it
`fix(scope)!:` and write the `BREAKING CHANGE:` footer — `CHANGELOG.md` lists
it under "⚠ Upgrade notes". Also add an entry under `## Unreleased` in
[`docs/UPGRADING.md`](docs/UPGRADING.md): the release names that section after
the version and publishes it as the GitHub release's upgrade notes.

Commit messages should not include tool attribution trailers (for example
`Co-Authored-By:` lines or "Generated with …" notes added by coding tools).

Don't bump `VERSION` or edit `CHANGELOG.md` by hand; the release workflow does
both.

## Compatibility

- [`docs/cli.md`](docs/cli.md) is the CLI contract: every command, action,
  flag, `--json` shape and exit code. Change it in the same pull request as
  `WAYU_COMMAND_SPECS`; `tests/unit/test_cli_doc.odin` and
  `tests/integration/test_exit_codes.rb` fail when they disagree.
- [`docs/STABILITY.md`](docs/STABILITY.md) says what may change and when.
  A change to a data file format (`entries.json`, `plugins.json`,
  `secrets.json`) or to where wayu keeps a file, directory or keychain item
  ships with an automatic one-time migration in the same release (backup,
  verify, one-time notice, a test with an old-form fixture); never a manual
  step. Removing a command, flag or `wayu.toml` key needs a deprecation
  warning for at least one minor release first.

## Pull requests

- Keep a pull request to one change; say what changed for users and how you
  tested it (the template lists the checks).
- New commands, actions and flags go in `WAYU_COMMAND_SPECS`
  (`src/wayu_completions.odin`), which drives parsing and completions.
- Use the `EXIT_*` constants from `src/interfaces.odin`; never a bare exit code.
- Update `README.md` when a command or its output changes.
