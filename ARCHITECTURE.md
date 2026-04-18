# Architecture

> Shell configuration management CLI written in [Odin](https://odin-lang.org/) that manages PATH entries, aliases, environment constants, completions, and backups for Zsh and Bash.

**Version**: 3.10.1 | **Language**: Odin | **Shells**: Zsh (primary), Bash, Fish

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Language | Odin (compiled, manual memory management) |
| Build | Custom Odin build tool (`./build_it`, sources in `bld/`) |
| Unit Tests | Odin `core:testing` framework |
| Integration Tests | Ruby scripts invoking compiled binary + Odin standalone programs |
| Visual Regression | Golden file comparison (`tests/golden/`) |
| CI/CD | GitHub Actions (`.github/workflows/ci.yml`, `release.yml`) |
| VCS | Git + [Jujutsu](https://github.com/martinvonz/jj) (`.jj/`) |

**Zero external dependencies** - everything uses Odin's `core:` standard library.

## Directory Structure

```
wayu/
├── src/                          # Main package (package wayu) - ~57 .odin files
│   ├── main.odin                 # Entry point, arg parsing, command dispatch
│   ├── exit_codes.odin           # BSD sysexits.h exit code constants
│   ├── shell.odin                # Shell detection ($SHELL env), file extensions
│   ├── shell_fish.odin           # Fish-shell-specific handling
│   ├── types.odin                # Shared type definitions (Style, enums)
│   ├── interfaces.odin           # Shared interfaces across workstreams
│   │
│   ├── path.odin / alias.odin / constants.odin / completions.odin
│   ├── backup.odin               # Timestamped backup/restore
│   ├── plugin*.odin              # Plugin: registry, operations, config, help
│   ├── hooks.odin                # Pre/post action hooks
│   ├── doctor.odin               # Health checks & auto-fix
│   ├── migrate.odin              # Shell-to-shell migration
│   ├── search.odin               # Global fuzzy search across configs
│   ├── alias_sources.odin        # Per-source alias classification
│   │
│   ├── config_entry.odin         # Generic config entry CRUD (Strategy pattern)
│   ├── config_specs.odin         # ConfigEntrySpec instances (PATH, ALIAS, CONSTANTS)
│   ├── config_toml.odin          # TOML config read/write
│   ├── config_toml_reader.odin   # Low-level TOML parsing
│   ├── preload.odin              # Embedded shell-script templates (incl. fish)
│   ├── init_generator.odin       # Generates optimized init files from wayu.toml
│   ├── static_gen.odin           # Ahead-of-time config compilation
│   ├── turbo_export.odin         # Fastest-path unified export (turbo.{zsh,bash})
│   ├── adaptive_optimizer.odin   # Picks build strategy by entry count
│   ├── env_snapshot.odin         # Snapshot/restore of env state
│   ├── hot_reload.odin           # File-watching hot reload (`wayu reload`/`watch`)
│   ├── lock.odin                 # File locking for concurrent safety
│   ├── output.odin               # JSON / structured output helpers
│   ├── template.odin             # Configuration presets
│   ├── prompt*.odin              # Interactive prompt helpers
│   ├── theme_starship.odin       # Starship theme integration
│   ├── fff_integration.odin      # Fuzzy finder integration
│   ├── integration_*.odin        # Integration-test shims
│   ├── wayu_completions.odin     # Emitted shell completion scripts
│   │
│   ├── validation.odin / input.odin / special_chars.odin
│   ├── style.odin / theme.odin / colors.odin / layout.odin
│   ├── table.odin / progress.odin / spinner.odin / form.odin
│   ├── fuzzy.odin / comp_testing.odin / errors.odin / debug.odin
│   ├── tui_bridge_impl.odin      # Bridge: connects TUI to main pkg via fn pointers
│   │
│   └── tui/                      # TUI subpackage (package wayu_tui) - 14 files
│       ├── main.odin / state.odin / events.odin / input.odin
│       ├── rawmode.odin / terminal.odin / screen.odin / render.odin
│       ├── layout.odin / panel.odin / colors.odin
│       ├── components.odin / views.odin / views_handlers.odin
│       └── bridge.odin           # Bridge interface (function pointer types)
│
├── bld/                          # `./build_it` build tool source (Odin)
├── build/                        # Secondary build-tooling source
├── bin/                          # Compiled binary (`bin/wayu`)
│
├── tests/
│   ├── unit/                     # Odin unit tests
│   ├── integration/              # Standalone Odin + shell integration tests
│   ├── ui/                       # Visual rendering tests
│   ├── tui/                      # TUI-specific tests
│   ├── benchmark/                # Micro-benchmarks
│   ├── benchmark_static_gen.sh   # Static-generation benchmarks
│   └── golden/                   # Golden files for visual regression
│
├── docs/                         # Design docs and plans
├── thoughts/                     # Working notes / RFC drafts
├── build_it                      # Bootstraps the Odin build tool in `bld/`
├── CLAUDE.md / AGENTS.md         # AI assistant guidance
├── CHANGELOG.md                  # Version history
└── README.md                     # User documentation
```

## Core Components

### Command Flow

```
CLI Input → parse_args() → Command/Action/Args → Command Handler → Config File Manipulation
                ↓
            --tui flag → Bridge Setup → TUI Event Loop
```

1. **`main.odin`** — Parses `os.args` into `ParsedArgs{command, action, args, shell, tui}`. Dispatches to command handlers or TUI.
2. **Command handlers** (`path.odin`, `alias.odin`, etc.) — Delegate to `handle_config_command()` in `config_entry.odin` via the Strategy pattern.
3. **`config_entry.odin`** — Generic CRUD for all config types. Uses `ConfigEntrySpec` to customize behavior per type.
4. **Config file manipulation** — Read entire file → split lines → filter/modify → join → write back. Always creates backup before write.

### Strategy Pattern (ConfigEntrySpec)

The `ConfigEntrySpec` struct in `config_specs.odin` defines how each config type (PATH, Alias, Constants) is validated, formatted, parsed, and displayed. Three global instances:

| Spec | File | Line Format | Fields |
|------|------|-------------|--------|
| `PATH_SPEC` | `path.{zsh,bash}` | `  "/usr/local/bin"` (array element) | 1 (path) |
| `ALIAS_SPEC` | `aliases.{zsh,bash}` | `alias name="command"` | 2 (name, command) |
| `CONSTANTS_SPEC` | `constants.{zsh,bash}` | `export NAME="value"` | 2 (name, value) |

Each spec provides: `validator`, `format_line`, `parse_line` function pointers + metadata (field labels, placeholders, icons).

### Dual-Mode Architecture (CLI / TUI)

```
wayu path add /usr/local/bin     ← CLI mode (default): non-interactive, scriptable
wayu --tui                       ← TUI mode: interactive terminal UI
```

- **CLI** — Fully non-interactive. All operations require explicit arguments. `--yes` flag for destructive ops. BSD sysexits.h exit codes (0, 1, 64-78).
- **TUI** — Full-screen terminal UI with Elm Architecture (TEA). 8 views, vim-style navigation (j/k), alt screen buffer.

### TUI Architecture

```
main.odin sets bridge functions → tui_run() → TEA Loop:
  ┌─────────────────────────────────────────────┐
  │  for state.running:                         │
  │    1. Check resize signal                   │
  │    2. Lazy-load data (via bridge)           │
  │    3. Render if needs_refresh               │
  │    4. Poll keyboard event (non-blocking)    │
  │    5. Handle event → update state           │
  └─────────────────────────────────────────────┘
```

**Bridge Pattern** — Avoids circular dependencies between `package wayu` and `package wayu_tui`:
- `src/tui/bridge.odin` — Declares 9 global function pointers (nil-initialized)
- `src/tui_bridge_impl.odin` — In main package, implements bridge functions that call wayu's config management
- `src/main.odin:147-157` — Sets bridge functions before launching TUI

**Data cache** — `TUIState.data_cache: map[TUIView]rawptr` stores `^[dynamic]string` per view. Loaded lazily, cleared after mutations to force reload.

### Style System

Three-tier adaptive color system:

```
Terminal Detection → ColorProfile (ASCII/ANSI/ANSI256/TrueColor)
                          ↓
                   adaptive_color() selects appropriate color string
                          ↓
                   Style struct → render() → ANSI-escaped string
```

- **`colors.odin`** — ANSI constants + vibrant TrueColor palette + terminal capability detection
- **`theme.odin`** — Dual light/dark themes with auto-detection via `COLORFGBG` env var
- **`style.odin`** — Value-copy builder pattern (not fluent chaining). `render()` applies borders, padding, margins, alignment, text formatting.
- **`table.odin`** — Auto-sizing columns constrained to terminal width. Hot pink rounded borders.

### Backup System

```
Any modification → create_backup() → timestamped copy in ~/.config/wayu/backup/
                                    → cleanup_old_backups(file, keep=5)
```

- CLI: `create_backup_cli()` — fails immediately on error
- TUI: `create_backup_tui()` — prompts user on failure

### Validation Pipeline

```
User Input → validate_identifier() → ValidationResult{valid, error_message}
           → Reserved word check (if, then, export, etc.)
           → Dangerous character escaping
           → Path validation and sanitization
```

## Data Flow

### Adding a PATH entry (CLI)

```
wayu path add /usr/local/bin
  → parse_args() → {command: PATH, action: ADD, args: ["/usr/local/bin"]}
  → handle_path_command() → handle_config_command(&PATH_SPEC, .ADD, args)
  → parse_args_to_entry() → ConfigEntry{type: PATH, name: "/usr/local/bin"}
  → validate_path_entry() → ValidationResult{valid: true}
  → safe_read_file("~/.config/wayu/path.zsh")
  → Find WAYU_PATHS=() array closing paren
  → Insert `  "/usr/local/bin"` before closing paren
  → create_backup_cli() → timestamped backup
  → safe_write_file() → write modified content
  → cleanup_old_backups() → keep last 5
  → print_success("PATH added successfully: /usr/local/bin")
```

### Config file format (v3.0.0 array-based PATH)

```bash
# ~/.config/wayu/path.zsh
WAYU_PATHS=(
  "/usr/local/bin"
  "/opt/homebrew/bin"
  "$HOME/.cargo/bin"
)

# Build PATH from registry with deduplication
for dir in "${WAYU_PATHS[@]}"; do
    if [ ! -d "$dir" ]; then
        continue
    fi
    if [[ ":$PATH:" == *":$dir:"* ]]; then
        continue
    fi
    export PATH="$dir:$PATH"
done

# Final deduplication pass
export PATH=$(echo "$PATH" | awk -v RS=':' -v ORS=':' '!seen[$0]++' | sed 's/:$//')
```

## External Integrations

- **File system** — `~/.config/wayu/` directory for all config files
- **Shell RC files** — `~/.zshrc` or `~/.bashrc` (modified during `wayu init`)
- **Terminal** — Raw mode via `termios` (TUI), `ioctl` for terminal size
- **Environment** — `$SHELL`, `$HOME`, `$COLORTERM`, `$TERM`, `$NO_COLOR`, `$COLORFGBG`

## Configuration

### Generated files in `~/.config/wayu/`

| File | Purpose |
|------|---------|
| `init.{zsh,bash}` | Main orchestrator, sources all other files |
| `path.{zsh,bash}` | PATH management with `WAYU_PATHS` array |
| `aliases.{zsh,bash}` | Alias definitions |
| `constants.{zsh,bash}` | Environment variable exports |
| `tools.{zsh,bash}` | External tool initialization (NVM, Starship, etc.) |
| `completions/` | Zsh completion scripts |
| `functions/` | Custom shell functions |
| `plugins/` | Shell plugins |
| `backup/` | Timestamped backups |

### Build-time flags

| Flag | Effect |
|------|--------|
| `-define:DEBUG=true` | Enable debug logging |
| `ODIN_DEBUG=true` env | Same as above |

## Build & Deploy

```bash
./build_it              # Production build (optimized, -o:speed)
./build_it debug        # Debug build with logging
./build_it test         # Run test suite
./build_it install      # Install to /usr/local/bin
```

**Underlying command**: `odin build src -out:bin/wayu -o:speed`

## Memory Model

- **No garbage collector** — all memory manually managed
- **2MB temp arena** — set up in `main()`, used for transient allocations
- **`defer delete()`** — every `fmt.aprintf()` and `safe_read_file()` result
- **`strings.clone()`** — ownership transfer when data outlives its source
- **`context.temp_allocator`** — for short-lived splits/joins within a function scope
