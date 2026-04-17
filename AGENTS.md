# agents.md

Agent instructions for AI coding assistants working in this repository.

## Project Overview

wayu is a shell configuration management CLI written in Odin. It manages PATH entries, aliases, environment constants, and completions by generating shell config files in `~/.config/wayu/` that users source via the main init file.

**Current version**: v3.10.0
**Supported shells**: Zsh (primary), Bash (full support) — Fish declared in code but not yet wired

## Build & Development Commands

> Build system is `./build_it` (an Odin binary at repo root, source in `build/build.odin`). There is no Taskfile.

```bash
# Build
./build_it              # Production build (default)
./build_it debug        # Development build (debug symbols + ODIN_DEBUG)
./build_it check        # Type-check only — fastest way to verify compilation
./build_it install      # Install to /usr/local/bin

# Test
./build_it test         # Unit tests (runs tests/unit/)

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

**Visual regression (golden files)**:
```bash
./build_it && ./unit --test-component-snapshot   # regenerate goldens
./build_it && ./unit --test-components            # compare against goldens
```

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
| `src/main.odin` | Entry point, argument parsing, init command |
| `src/shell.odin` | Shell detection (from `$SHELL`), file extension (.zsh/.bash) |
| `src/path.odin` | PATH management — array-based `WAYU_PATHS=()` format |
| `src/config_entry.odin` | Generic config entry read/write |
| `src/config_specs.odin` | Parser/formatter specs per config type |
| `src/preload.odin` | Embedded shell script templates for `init` command |
| `src/validation.odin` | Input validation (reserved words, dangerous chars, length) |
| `src/backup.odin` | Timestamped backups, restore, cleanup (keeps last 5) |
| `src/hooks.odin` | Pre/post operation hooks (subprocess execution) |
| `src/hot_reload.odin` | File watcher for live config reload |
| `src/config_toml.odin` | TOML-based config management (wayu.toml) |
| `src/tui/` | Complete TUI implementation |
| `src/tui_bridge_impl.odin` | Connects TUI to config system via function pointers (avoids circular deps) |
| `src/exit_codes.odin` | BSD sysexits.h constants — always use these, never bare `os.exit(1)` |

### Config File Format

Config files are plain shell scripts parsed line-by-line:
1. `os.read_entire_file_from_filename()` reads the whole file
2. Split by newline, filter/modify lines by string prefix matching
3. Join and write back with `os.write_entire_file()`

**PATH format**: `WAYU_PATHS=("dir1" "dir2")` array with a single for-loop export.

### TUI Architecture (src/tui/)

The Elm Architecture: centralized state → events → update → render.
Bridge pattern (`bridge.odin` + `src/tui_bridge_impl.odin`) avoids circular imports between the `tui` and main packages using function pointers set at runtime. Data loads lazily per view; cache clears after mutations.

### Exit Codes

Always use the constants from `src/exit_codes.odin`. **Never use bare `os.exit(1)`**.

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
├── ui/            # Visual/alignment component tests (Odin)
├── golden/        # Golden files for component visual regression
├── integration/   # Integration tests (Ruby) — test end-to-end CLI behavior
├── tui/           # TUI responsive tests (Python/pyte)
└── benchmark/     # Performance benchmarks
```

Unit tests: `tests/unit/test_<module>.odin`. Integration tests spawn the compiled binary and check stdout/stderr/exit codes.

## Shell-Specific Notes

- Config files use `.zsh` or `.bash` extensions determined by `src/shell.odin` at runtime
- Completions are Zsh-only (`_wayu` file) — Bash/Fish completion not yet implemented
- `src/preload.odin` has separate templates for each shell with shell-specific syntax
- Both Zsh and Bash PATH templates include a dedup pass after exporting `WAYU_PATHS`

## CLI Interface Contract

- `--help` / `-h`: works globally and per-command
- `--version` / `-v`: prints `wayu vX.Y.Z`
- `--no-color`: disables ANSI colors (equivalent to `NO_COLOR=1`)
- `--yes` / `-y`: skip confirmation on destructive operations (required by: `path clean`, `path dedup`, `backup rm`, `plugin remove`)
- `--json`: machine-readable output (currently only `doctor` — expand to list commands)
- `--dry-run`: show what would happen without writing

## Known Stubs / In-Progress Areas

These are acknowledged incomplete features — do not add workarounds, implement them properly:

- `src/hot_reload.odin`: complete implementation, needs CLI entry point wired in `main.odin`
- `src/config_toml.odin:~1615`: TOML migration from existing shell configs
- `wayu build profile`: profiling not yet implemented
- `src/fuzzy.odin:~1017`: real-time filtering (falls back to static list)
- Fish shell: declared in `parse_shell_type` but completion/plugin/template paths not wired
