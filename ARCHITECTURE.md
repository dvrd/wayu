# Architecture

> Shell configuration management CLI written in [Odin](https://odin-lang.org/) that manages PATH entries, aliases, environment constants, completions, and backups for Zsh and Bash.

**Version**: 3.0.0 | **Language**: Odin | **Shells**: Zsh (primary), Bash

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Language | Odin (compiled, manual memory management) |
| Build | [Taskfile](https://taskfile.dev/) (`Taskfile.yml`) |
| Unit Tests | Odin `core:testing` framework |
| Integration Tests | Ruby scripts invoking compiled binary + Odin standalone programs |
| Visual Regression | Golden file comparison (`tests/golden/`) |
| CI/CD | GitHub Actions (`.github/workflows/ci.yml`, `release.yml`) |
| VCS | Git + [Jujutsu](https://github.com/martinvonz/jj) (`.jj/`) |

**Zero external dependencies** - everything uses Odin's `core:` standard library.

## Directory Structure

```
wayu/
├── src/                          # Main package (package wayu) - 29 files
│   ├── main.odin                 # Entry point, arg parsing, command dispatch
│   ├── exit_codes.odin           # BSD sysexits.h exit code constants
│   ├── shell.odin                # Shell detection ($SHELL env), file extensions
│   ├── types.odin                # Shared type definitions (Style, enums)
│   │
│   ├── path.odin                 # PATH management (add/remove/list/clean/dedup)
│   ├── alias.odin                # Alias management (add/remove/list)
│   ├── constants.odin            # Environment variable management
│   ├── completions.odin          # Zsh completion script management
│   ├── backup.odin               # Timestamped backup/restore system
│   ├── plugin.odin               # Plugin management (basic, not fully integrated)
│   │
│   ├── config_entry.odin         # Generic config entry CRUD (Strategy pattern)
│   ├── config_specs.odin         # ConfigEntrySpec instances (PATH_SPEC, ALIAS_SPEC, etc.)
│   ├── preload.odin              # Embedded shell script templates for init
│   │
│   ├── validation.odin           # Input validation (identifiers, reserved words)
│   ├── input.odin                # Input handling utilities
│   ├── special_chars.odin        # Dangerous character escaping
│   │
│   ├── style.odin                # Core styling: ANSI colors, render pipeline
│   ├── theme.odin                # Dual light/dark theme with auto-detection
│   ├── colors.odin               # 3-tier adaptive color system (TrueColor/256/ANSI)
│   ├── layout.odin               # Layout utilities, visual_width, terminal size
│   ├── table.odin                # Table rendering with auto-sizing columns
│   ├── progress.odin             # Progress bar indicators
│   ├── spinner.odin              # Loading spinner animations
│   ├── form.odin                 # Form rendering utilities
│   │
│   ├── fuzzy.odin                # Fuzzy finder (raw terminal mode)
│   ├── comp_testing.odin         # Component testing CLI (-c= flag)
│   ├── errors.odin               # Enhanced errors with context/suggestions
│   ├── debug.odin                # Compile-time debug logging
│   ├── tui_bridge_impl.odin      # Bridge: connects TUI to main pkg via fn pointers
│   │
│   └── tui/                      # TUI subpackage (package wayu_tui) - 15 files
│       ├── main.odin             # TEA event loop and rendering dispatch
│       ├── state.odin            # State machine (8 views, transitions)
│       ├── events.odin           # Event parsing (keyboard → typed events)
│       ├── input.odin            # Non-blocking stdin read
│       ├── rawmode.odin          # Terminal raw mode via termios
│       ├── terminal.odin         # Terminal lifecycle (alt screen, signals)
│       ├── screen.odin           # Screen buffer with differential rendering
│       ├── render.odin           # Rendering utilities
│       ├── layout.odin           # TUI-specific layout constants
│       ├── panel.odin            # Panel rendering (bordered sections)
│       ├── colors.odin           # TUI color palette (Zellij-inspired)
│       ├── components.odin       # Component registry (box, header, footer, etc.)
│       ├── views.odin            # 8 view implementations
│       ├── views_handlers.odin   # Per-view event handlers
│       └── bridge.odin           # Bridge interface (function pointer types)
│
├── tests/
│   ├── unit/                     # 22 Odin test files (235+ tests)
│   ├── integration/              # 5 Odin standalone + 11 Ruby test files
│   ├── ui/                       # 3 Odin visual rendering tests
│   └── golden/                   # 9 golden files for visual regression
│
├── scripts/                      # Dev/CI scripts (Ruby, Bash, Python)
├── docs/                         # Documentation (currently empty)
├── Taskfile.yml                  # Build & test automation
├── CLAUDE.md                     # AI assistant guidance
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
task build              # Production build (optimized, -o:speed)
task debug              # Debug build (debug symbols + logging)
task test               # All tests with unified coverage report
task test:integration   # Standalone integration tests (Odin)
task install            # Install to /usr/local/bin
```

**Build command**: `odin build src -out:bin/wayu`

## Memory Model

- **No garbage collector** — all memory manually managed
- **2MB temp arena** — set up in `main()`, used for transient allocations
- **`defer delete()`** — every `fmt.aprintf()` and `safe_read_file()` result
- **`strings.clone()`** — ownership transfer when data outlives its source
- **`context.temp_allocator`** — for short-lived splits/joins within a function scope
