# agents.md

Agent instructions for AI coding assistants working in this repository.

## Project Overview

wayu is a shell configuration management CLI written in Odin. It manages PATH entries, aliases, environment constants, and completions. All wayu files live under `~/.config/wayu/` — user-edited files (wayu.toml, hooks, extra.zsh) alongside generated runtime files (init.zsh, core.zsh, plugins, completions, backups).

**Current version**: see `VERSION` constant in `src/main.odin` (single source of truth) — run `./wayu --version` to print.
**Supported shells**: Zsh (primary), Bash (full support) — Fish declared in code but not yet wired

## Build & Development Commands

> Build system is `./build_it` (an Odin binary at repo root, source in `build/build.odin`). There is no Taskfile.
> Odin version is pinned in `.github/odin-release` (used by CI/releases); `./build_it` warns on a mismatch. Bump it there + README when upgrading.

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
./build_it && ./wayu path list
```

**Integration tests** (Ruby, requires `ruby` + bundler):
```bash
ruby tests/integration/test_path.rb
ruby tests/integration/test_alias.rb
ruby tests/integration/test_constants.rb
ruby tests/integration/test_backup.rb
ruby tests/integration/test_validation.rb
ruby tests/integration/test_errors.rb
ruby tests/integration/test_dry_run.rb
ruby tests/integration/test_init.rb
ruby tests/integration/test_completions.rb
ruby tests/integration/test_plugin.rb
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

1. `src/main.odin` — entry point; parses args into `Command/Action/Args` with shell detection
2. Command handlers (`path.odin`, `alias.odin`, etc.) — process `ADD/REMOVE/LIST/HELP` actions
3. All handlers manipulate plain text shell config files via string operations
4. Backup is created automatically before any write

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
| `src/init_generator.odin` | Generates core, lazy, login, helpers shell scripts |
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
| `src/hot_reload.odin` | `wayu reload`/`watch`: file watcher, debounced core regeneration |
| `src/tui_core.odin` | TUI main loop, state machine, data loading, render orchestrator |
| `src/tui_views.odin` | TUI view renderers (list, overlays, cache, handlers, hooks, plugins, settings) |
| `src/tui_io.odin` | TUI terminal I/O: raw mode, input, screen buffer, events, colors, layout, components |
| `src/prompt.odin` | Native zsh prompt (opt-in: `[prompt] enabled = true`) + vi-mode; values escaped |
| `src/fuzzy.odin` | Fuzzy matching, interactive terminal selection, completions extraction |
| `src/interfaces.odin` | Shared types (LockFile, TomlConfig, etc.), exit codes, debug |
| `src/colors.odin` | ANSI color profiles + output helpers |
| `src/style.odin` | TUI styling: render pipeline, text styling, unicode width utilities |

### Config File Format

Config files are plain shell scripts parsed line-by-line:
1. `os.read_entire_file_from_filename()` reads the whole file
2. Split by newline, filter/modify lines by string prefix matching
3. Join and write back with `os.write_entire_file()`

**PATH format**: `WAYU_PATHS=("dir1" "dir2")` array with a single for-loop export.

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
| EXIT_CANTCREAT | 73 | Cannot create output file |
| EXIT_IOERR | 74 | I/O error |
| EXIT_NOPERM | 77 | Permission denied |
| EXIT_CONFIG | 78 | Config error |

## Code Patterns

```odin
// Always defer cleanup
config_file := fmt.aprintf("%s/%s", WAYU_CONFIG, PATH_FILE)
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
if !global_yes_flag {
    fmt.printf("This will delete X. Pass --yes to confirm.\n")
    os.exit(EXIT_USAGE)
}
```

## Testing Structure

```
tests/
├── unit/          # Odin unit tests, one file per module
├── golden/        # Component goldens + cases.txt (checked by integration/test_golden.rb)
├── integration/   # Integration tests (Ruby) — test end-to-end CLI behavior
└── tui/           # TUI responsive tests (Python/pyte)
```

Unit tests: `tests/unit/test_<module>.odin`. Scratch files/dirs go under `test_tmp(name)` (`tests/unit/test_tmp.odin`, per-process root) — never a fixed `/tmp/...` path: other worktrees run the suite concurrently. Process-lifetime caches in `src/` allocate from `runtime.heap_allocator()`, or the first test to fill them reports a leak. Integration tests spawn the compiled binary and check stdout/stderr/exit codes.

## Shell-Specific Notes

- Config files use `.zsh` or `.bash` extensions determined by `src/shell.odin` at runtime
- wayu's own completions (zsh/bash/fish) are generated from `WAYU_COMMAND_SPECS` in `src/wayu_completions.odin` — add new commands/actions there (a unit test checks every `Command` has a row)
- `src/preload.odin` has separate templates for each shell with shell-specific syntax
- Both Zsh and Bash PATH templates include a dedup pass after exporting `WAYU_PATHS`

## CLI Interface Contract

- `--help` / `-h`: works globally and per-command
- `--version` / `-v`: prints `wayu vX.Y.Z`
- `--no-color`: disables ANSI colors (equivalent to `NO_COLOR=1`)
- `--yes` / `-y`: skip confirmation on destructive operations (required by: `path clean`, `path dedup`, `backup rm`, `plugin remove`, `doctor --fix`)
- `--json`: machine-readable output (currently only `doctor` — expand to list commands)
- `wayu doctor` exits `EXIT_CONFIG` (78) when any check reports an error, so it can gate CI
- `--dry-run`: show what would happen without writing

## Known Stubs / In-Progress Areas

These are acknowledged incomplete features — do not add workarounds, implement them properly:

- `wayu build profile`: profiling not yet implemented
- `src/fuzzy.odin`: interactive_select is alive; FuzzyView-based full-screen finder removed as dead code
- Fish shell: completions and templates wired; `--shell fish` flag fixed in init command
- `src/tui_views.odin`: hooks and settings views render minimal placeholder content
