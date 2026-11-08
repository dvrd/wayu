# Contributing to wayu

Thanks for helping. This page covers building, testing, the branch flow and
the commit rules that drive releases. Code conventions are in
[`CODE_STYLE.md`](CODE_STYLE.md); the source map is in
[`AGENTS.md`](AGENTS.md) ("Key Source Files").

Security problems: please follow [`SECURITY.md`](SECURITY.md) instead of
opening an issue.

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
```

The tests run in a temporary `HOME`. When you try wayu by hand, do the same so
your real `~/.config/wayu` and shell startup are untouched:

```bash
HOME=$(mktemp -d) ./bin/wayu init
```

Golden files for TUI components live in `tests/golden/`; each needs a line in
`tests/golden/cases.txt`. Regenerate one with
`./bin/wayu -c=<component> --snapshot <args>` and review the diff.

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
`fix(scope)!:` and write the `BREAKING CHANGE:` footer — it becomes the
release's "⚠ Upgrade notes". Also add an entry under `## Unreleased` in
[`docs/UPGRADING.md`](docs/UPGRADING.md).

Commit messages should not include tool attribution trailers (for example
`Co-Authored-By:` lines or "Generated with …" notes added by coding tools).

Don't bump `VERSION` or edit `CHANGELOG.md` by hand; the release workflow does
both.

## Pull requests

- Keep a pull request to one change; say what changed for users and how you
  tested it (the template lists the checks).
- New commands, actions and flags go in `WAYU_COMMAND_SPECS`
  (`src/wayu_completions.odin`), which drives parsing and completions.
- Use the `EXIT_*` constants from `src/interfaces.odin`; never a bare exit code.
- Update `README.md` when a command or its output changes.
