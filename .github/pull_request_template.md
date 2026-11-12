<!-- Pull requests target `develop`. See CONTRIBUTING.md. -->

## What changes

<!-- What changes for users, and why. Link the issue if there is one. -->

## User-visible behavior change?

<!--
Output, exit codes, flags, generated shell code or config semantics count.
If yes: the commit is `type(scope)!:` with a `BREAKING CHANGE:` footer, and
docs/UPGRADING.md "## Unreleased" has an entry.
-->

- [ ] No
- [ ] Yes — marked breaking and added to `docs/UPGRADING.md`

## Checks

- [ ] `./build_it check` and `./build_it test`
- [ ] `ruby tests/integration/run_all.rb`
- [ ] `odin build src -out:bin/lint -vet -warnings-as-errors`
- [ ] `odinfmt -w` on every touched `.odin` file
- [ ] `tests/benchmark/budget.sh` (if generated shell code changed)
- [ ] `python3 tests/tui/test_responsive.py` (if the TUI changed)
- [ ] `docs/cli.md` updated (if a command, flag, `--json` shape or exit code changed)
- [ ] README / help text updated (if a command or its output changed)
- [ ] No secrets, tokens or personal paths in the diff, fixtures or description
