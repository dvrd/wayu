# agents.md

Agent instructions for AI coding assistants working in this repository.

## Project Overview

wayu is a shell configuration management CLI written in Odin. It manages PATH entries, aliases, environment constants, `[tools]` loaders, a native zsh prompt, plugins, functions and completions. All wayu files live under `~/.config/wayu/` (`WAYU_CONFIG_DIR` / `WAYU_DATA_DIR` move them) — user-edited files (wayu.toml, hooks.conf, extra.<ext>, tools.<ext>, functions/) alongside generated runtime files (init.<ext>, core.<ext>, path_sync.<ext>, plugins, completions, backups).

User docs: [README.md](README.md) (install, shell setup, upgrade), [docs/cli.md](docs/cli.md) (every command/flag, `--json` shapes, exit codes), [docs/config-reference.md](docs/config-reference.md) (wayu.toml and the other config files), [docs/UPGRADING.md](docs/UPGRADING.md) (behavior changes per release).

**Current version**: see `VERSION` constant in `src/main.odin` (single source of truth) — run `./bin/wayu --version` to print.
**Supported shells**: Zsh (primary), Bash, Fish (core.fish: [tools], functions/, live PATH sync; no native prompt)

## Build & Development Commands

> Build system is `./build_it` (an Odin binary at repo root, source in `build/build.odin`). There is no Taskfile.
> Odin version is pinned in `.github/odin-release` (used by CI/releases); `./build_it` warns on a mismatch. Bump it there when upgrading.

```bash
# Build
./build_it              # Production build (default)
./build_it debug        # Development build (debug symbols + ODIN_DEBUG)
./build_it check        # Type-check only — fastest way to verify compilation
./build_it install      # Install to ~/.local/bin ($PREFIX/bin); refuses if Homebrew manages wayu (--force)

# Test
./build_it test         # Unit tests (runs tests/unit/; leaks/bad frees fail; output + failed names shown)
./build_it test test_wayu.test_x,test_wayu.test_y   # run only these tests

# Run with args during dev
./build_it && ./bin/wayu path list
./build_it dev path list   # debug build + run
```

**Integration tests** (Ruby, stdlib only; each suite builds `bin/wayu` first unless `WAYU_BIN` is set, and runs in a temp HOME):
```bash
ruby tests/integration/run_all.rb          # every tests/integration/test_*.rb
ruby tests/integration/test_path.rb        # one suite
WAYU_BIN=$PWD/bin/wayu ruby tests/integration/test_exit_codes.rb   # skip the rebuild
```

**TUI layout tests** (Python, needs `pip install pyte`; uses `bin/wayu`, override with `WAYU_BIN`; runs in a temp HOME with a fixed config; also run by CI):
```bash
./build_it && python3 tests/tui/test_responsive.py
```

**Visual regression (golden files)**:
```bash
ruby tests/integration/test_golden.rb             # compare every golden (also run by run_all.rb)
./bin/wayu -c=header --test width=40 height=3 title=PATH count=10      # check one component
./bin/wayu -c=header --snapshot width=40 height=3 title=PATH count=10  # regenerate one golden
```

Each `tests/golden/<component>_<W>x<H>.txt` needs a matching line (component + args) in `tests/golden/cases.txt`; the test fails if a golden has no case.

## Branching & releases

- **`develop` is the integration branch.** All work (features, fixes, review
  follow-ups, whole roadmap phases) merges into `develop`; pushes there run CI
  but never release.
- **`main` is release-only.** Every push to `main` triggers
  `.github/workflows/bump.yml` → version bump, GitHub release, Homebrew update.
  Merge `develop` → `main` only when the maintainer explicitly says to ship;
  never push or merge to `main` on your own. A batch of phases ships as one
  version.
- PRs into `main` must come from `develop` (or `hotfix/*` for an urgent,
  maintainer-approved fix); `.github/workflows/main-guard.yml` fails any other
  source. A `hotfix/*` merged to `main` is merged back into `develop` right
  after.
- A phase/ticket is "done" when it is merged and CI-green on `develop`.
- Keep `docs/UPGRADING.md` "## Unreleased" up to date on `develop`; rename it to
  the version when shipping.

## Commit convention (drives versioning)

Conventional Commits; `git-cliff` derives the next version from them (`cliff.toml` `[bump]`):

| Commit | Bump |
|---|---|
| `type!: …` or a `BREAKING CHANGE: <what users must know>` footer | major |
| `feat: …` | minor |
| anything else (`fix:`, `refactor:`, …) | patch |

Any **user-visible behavior change** (output, exit codes, flags, generated shell code, config semantics) is breaking even when it is a fix: mark it `fix(scope)!:` and write the footer — it becomes the release's "⚠ Upgrade notes". Batching on `develop` (above) keeps majors infrequent; don't drop the `!` to avoid one. No AI attribution in commits/PRs (no `Co-Authored-By`, no "Generated with").

## Architecture

### Command Flow

1. `src/main.odin` — entry point; `parse_args` (`src/cli_parser.odin`) resolves `Command/Action/Args` from `WAYU_COMMAND_SPECS` (`src/wayu_completions.odin`) and validates flags
2. Command handlers (`path.odin`, `alias.odin`, `constants.odin`, …) process the action
3. Entry commands edit `wayu.toml` in place (line-level table editor in `toml.odin`, under the config lock, atomic write), then regenerate `core.<ext>` / `path_sync.<ext>` (`init_generator.odin`)
4. Each file is backed up before its first write in a run

### Dual-Mode Architecture

- **CLI mode (default)**: Fully non-interactive, all operations require explicit arguments, BSD sysexits.h exit codes, `--yes` flag for destructive operations
- **TUI mode** (`wayu --tui`): Full-screen interactive UI using The Elm Architecture (TEA)

### Key Source Files

| File | Purpose |
|------|---------|
| `src/main.odin` | Entry point, argument parsing, init command, CLI dispatch |
| `src/cli_parser.odin` | CLI argument parsing: global flags, command + action resolution |
| `src/shell.odin` | Shell detection, extension mapping, Fish init generation |
| `src/path.odin` | PATH management — TOML-native via handle_toml_entry_command |
| `src/alias.odin` | Alias management + alias sources |
| `src/constants.odin` | Environment constant management |
| `src/config_entry.odin` | Generic config entry system: read/write, specs, entry types, path keys, schema check |
| `src/config_specs.odin` | ConfigEntrySpec per type (PATH, ALIAS, CONSTANTS) |
| `src/toml.odin` | TOML config mapping, line-level table editor, `wayu toml` commands |
| `src/toml_parse.odin` | The one TOML parser (error recovery, file order, line spans) — every wayu.toml reader uses it |
| `src/preload.odin` | Shell script templates for init (zsh/bash/fish) |
| `src/init_generator.odin` | Generates core.<ext> (the one file init.<ext> loads) + path_sync.<ext> |
| `src/plugin.odin` | Plugin command dispatch + builtin plugin catalog |
| `src/plugin_json.odin` | Plugin JSON config read/write + migration |
| `src/plugin_ops.odin` | Git ops, dependency resolution, conflict detection |
| `src/plugin_storage.odin` | Plugin command handlers (add, remove, list, update, etc.) |
| `src/plugin_loader.odin` | Generates runtime plugin loader shell scripts |
| `src/backup.odin` | Timestamped backups (once per CLI run, pruned to 5 on every write), restore by index/file |
| `src/doctor.odin` | Health check orchestrator + individual checks |
| `src/migrate.odin` | Legacy shell config → wayu.toml migration (all-or-nothing) + schema migration + `--from/--to` |
| `src/migrate_parse.odin` | Legacy file parser: each line → entry or listed `file:line` + reason |
| `src/shell_words.odin` | Exact POSIX/fish shell-word tokenizer (quotes, escapes, expandability) |
| `src/validation.odin` | Input validation + error handling |
| `src/hooks.odin` | hooks.conf loading + execution; live pre/post hook procs (ConfigEntrySpec, path, plugin add, export) |
| `src/function.odin` | `wayu function` (functions/ files, editor skeletons) |
| `src/config_command.odin` | `wayu config edit/extend/scan [--fix]` |
| `src/search.odin` | `wayu search` / `find` / `f` |
| `src/templates.odin` | `wayu template` presets + `init --template` |
| `src/turbo_export.odin` | `wayu export` (turbo copy of core, `--eval`, `--check`) |
| `src/secrets.odin` | Secret heuristic + masking; file modes for files holding [env] values |
| `src/env_snapshot.odin` | Snapshot of the running env (PATH, aliases, env) for the list views' `source` column |
| `src/atomic_io.odin` | Atomic file replacement + inter-process config lock |
| `src/lock.odin` | wayu.lock reader (hot reload) |
| `src/subprocess.odin` | `run_command`: subprocess without a shell, with timeouts (plugin clones, shells) |
| `src/wayu_completions.odin` | `WAYU_COMMAND_SPECS` (commands/actions/flags/--json; drives parser, help, completions) + wayu's own completions |
| `src/table.odin`, `src/spinner.odin` | CLI table and spinner components |
| `src/rune_width_table.odin` | Generated by `tests/tui/gen_rune_width.py` (Unicode widths) — do not edit |
| `src/hot_reload.odin` | `wayu reload`/`watch`: file watcher, debounced core regeneration |
| `src/profile.odin` | `wayu build profile`: startup timing + per-section/tool/plugin breakdown (zsh, bash 5+) |
| `src/tui_core.odin` | TUI main loop, state machine, data loading, render orchestrator |
| `src/tui_views.odin` | TUI view renderers (list, overlays, cache, handlers, hooks, plugins, settings) |
| `src/tui_io.odin` | TUI terminal I/O: raw mode, input, screen buffer, events, colors, layout, components |
| `src/prompt.odin` | Native zsh prompt (opt-in: `[prompt] enabled = true`) + vi-mode; values escaped |
| `src/fuzzy.odin` | Fuzzy matching, interactive terminal selection, completions extraction |
| `src/interfaces.odin` | Shared types (LockFile, TomlConfig, etc.), exit codes, debug |
| `src/colors.odin` | ANSI color profiles + output helpers |
| `src/style.odin` | TUI styling: render pipeline, text styling, unicode width utilities |

### Config File Format

`wayu.toml` is the source of truth (reference: `docs/config-reference.md`):
`[shell]`, `[paths]` (`key = "dir"`, file order = PATH priority), `[aliases]`,
`[env]`, `[settings]`, `[tools]`, `[prompt]` / `[prompt.*]`.
- Reading: always through `src/toml_parse.odin` (strict for validate/doctor/backup/migrate, lenient elsewhere).
- Writing: the line-level editor in `src/toml.odin` (`toml_kv_upsert` / `toml_kv_delete`) keeps comments and order; writes go through `write_file_atomic` under the config lock.
- Generated shell code: `src/init_generator.odin` compiles wayu.toml into `core.<ext>` (the one file `init.<ext>` sources) and `path_sync.<ext>`; never edit those by hand.
- Legacy `path/aliases/constants.<ext>` files (pre-3.10 layout) are only read by `wayu migrate` and by `init.<ext>`'s fallback when `core.<ext>` is missing; an obsolete `[[paths]]` wayu.toml makes most commands exit 78 until `wayu migrate --schema`.

### TUI Architecture (src/tui_core.odin, tui_views.odin, tui_io.odin)

The Elm Architecture: centralized state → events → update → render.
All TUI code lives in 3 consolidated files (down from 18). No separate `tui/` package — everything is in the `wayu` package to avoid circular imports. Data loads lazily per view (`tui_views_cache`); cache clears after mutations.

### Exit Codes

Always use the `EXIT_*` constants from `src/interfaces.odin`. **Never use bare `os.exit(1)`**.

| Constant | Value | When to use |
|---|---|---|
| EXIT_SUCCESS | 0 | Success |
| EXIT_FAILURE | 1 | General error |
| EXIT_USAGE | 64 | Bad CLI arguments |
| EXIT_DATAERR | 65 | Input data error |
| EXIT_NOINPUT | 66 | File not found / unreadable |
| EXIT_OSERR | 71 | TUI could not set up the terminal |
| EXIT_CANTCREAT | 73 | Cannot create output file |
| EXIT_IOERR | 74 | I/O error |
| EXIT_NOPERM | 77 | Permission denied |
| EXIT_CONFIG | 78 | Config error |

## Code Patterns

```odin
// Always defer cleanup
config_file := toml_get_config_path() // <wayu.config>/wayu.toml
defer delete(config_file)

// Validate inputs before use — format only, do NOT check path existence on disk
result := validate_path(path)
if !result.valid {
    print_error(result.error_message)
    os.exit(EXIT_DATAERR)
}

// Backup before any write
backup_path, ok := create_backup(config_file)
defer if ok do delete(backup_path)

// Guard destructive operations with --yes
if !wayu.yes_flag {
    print_error("This operation requires confirmation.")
    os.exit(EXIT_USAGE)
}
```

Code the TUI can reach (config readers, locks) exits with `wayu_exit(code)`, which restores the terminal first, instead of `os.exit`.

## Testing Structure

```
tests/
├── unit/          # Odin unit tests, one file per module (test_cli_doc.odin checks docs/cli.md against WAYU_COMMAND_SPECS)
├── golden/        # Component goldens + cases.txt (checked by integration/test_golden.rb)
├── integration/   # Ruby, end-to-end CLI behavior (run_all.rb; fixtures/upgrade = old releases' config dirs; test_exit_codes.rb runs docs/cli.md's exit code table)
├── tui/           # TUI tests (Python/pyte: test_responsive.py) + gen_rune_width.py
└── benchmark/     # startup.sh: shell startup timing (hyperfine)
```

Unit tests: `tests/unit/test_<module>.odin`. Scratch files/dirs go under `test_tmp(name)` (`tests/unit/test_tmp.odin`, per-process root) — never a fixed `/tmp/...` path: other worktrees run the suite concurrently. Process-lifetime caches in `src/` allocate from `runtime.heap_allocator()`, or the first test to fill them reports a leak. Integration tests spawn the compiled binary and check stdout/stderr/exit codes.

## Shell-Specific Notes

- Shell files use `.zsh`, `.bash` or `.fish` extensions, chosen by `src/shell.odin` from `$SHELL` / `--shell`
- wayu's own completions (zsh/bash/fish) are generated from `WAYU_COMMAND_SPECS` in `src/wayu_completions.odin` — add new commands/actions there (a unit test checks every `Command` has a row); `arg_names`/`arg_name_actions` make an action's first argument complete existing entries via the hidden `wayu completions names <kind>`
- `src/preload.odin` has separate templates for each shell with shell-specific syntax
- The PATH apply in `core.<ext>` prepends `[paths]` dirs in order without duplicates; open shells re-apply `path_sync.<ext>` from a prompt hook (`_wayu_paths_sync`) when `[paths]` changed

## CLI Interface Contract

- `--help` / `-h`: works globally and per-command
- `--version` / `-v`: prints `wayu vX.Y.Z`
- `--no-color`: disables ANSI colors (equivalent to `NO_COLOR=1`)
- `--yes` / `-y`: confirm destructive operations (required by: `path clean`, `path dedup`, `backup restore`, `backup rm`, `plugin remove`, `function remove`, `config scan --fix`, `doctor --fix`); without it they exit 64
- `--`: ends flag parsing; in `alias add` / `const add` the rest of the line after the first value word is the value (see `docs/cli.md`). Unknown options exit 64
- `--json`: machine-readable output for `path|alias|const|plugin|backup list`, `search`, `doctor` (the `json` bit_set in `WAYU_COMMAND_SPECS`; elsewhere exit 64). Schemas are documented in `docs/cli.md` "JSON output" and pinned by `test_json_schema` in `tests/integration/test_cli_output.rb` — update both when a shape changes
- `docs/cli.md` is the CLI contract: when you add/rename a command, action or flag in `WAYU_COMMAND_SPECS`, or change an exit code, update it (`tests/unit/test_cli_doc.odin` and `tests/integration/test_exit_codes.rb` fail otherwise)
- `wayu doctor` exits `EXIT_CONFIG` (78) when any check reports an error, so it can gate CI
- `--dry-run`: show what would happen without writing

## Known Stubs / In-Progress Areas

These are acknowledged incomplete features — do not add workarounds, implement them properly:

- Fish: no native prompt (`[prompt]` is zsh-only); `wayu export` turbo is zsh/bash only
- TUI plugins view: remove/update not available (CLI handlers exit the process; needs a non-exiting core)
