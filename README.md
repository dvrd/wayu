# wayu

A shell configuration management CLI written in [Odin](https://odin-lang.org/) with zero external dependencies. Manages PATH entries, aliases, environment variables, completions, and backups across Bash and Zsh.

## Features

- **Multi-shell** -- Automatic Bash/Zsh detection with shell-specific config files
- **Dual mode** -- Non-interactive CLI for scripting + interactive TUI for humans
- **PATH management** -- Centralized array-based system with deduplication and validation
- **Alias & constants** -- Add, remove, list with input validation and reserved word checking
- **Completions** -- Manage Zsh completion scripts
- **Backup & restore** -- Automatic timestamped backups before every modification
- **Shell migration** -- Migrate configs between Bash and Zsh
- **Dry-run mode** -- Preview any change before applying it
- **Scriptable** -- BSD sysexits.h exit codes, no interactive prompts in CLI mode
- **Zero dependencies** -- Pure Odin, ~17K lines, compiles in seconds

## Installation

Requires the [Odin compiler](https://odin-lang.org/docs/install/).

```bash
# Bootstrap the build system, then build + install
odin build build -out:build_it && ./build_it install

# Or manually:
odin build src -out:bin/wayu -o:speed && cp bin/wayu /usr/local/bin/
wayu init       # creates ~/.config/wayu/ with shell-appropriate config files
```

## Quick Start

```bash
# PATH
wayu path add /usr/local/bin
wayu path add ~/.cargo/bin
wayu path list
wayu path rm /usr/local/bin
wayu path clean --yes          # remove entries pointing to missing directories
wayu path dedup --yes          # remove duplicate entries

# Aliases
wayu alias add ll 'ls -la'
wayu alias add gs 'git status'
wayu alias list
wayu alias rm ll

# Environment variables
wayu constants add EDITOR nvim
wayu constants list
wayu constants rm EDITOR

# Completions (Zsh)
wayu completions add jj /path/to/_jj
wayu completions list

# Backups
wayu backup list
wayu backup restore path

# Shell migration
wayu migrate --from zsh --to bash

# Interactive mode
wayu --tui
```

## CLI Reference

```
wayu <command> <action> [arguments] [flags]
```

### Commands

| Command | Description |
|---------|-------------|
| `path` | Manage PATH entries |
| `alias` | Manage shell aliases |
| `constants` | Manage environment variables |
| `completions` | Manage Zsh completion scripts |
| `backup` | Manage configuration backups |
| `init` | Initialize config directory |
| `migrate` | Migrate config between shells |
| `version` | Show version |
| `help` | Show help |

### Actions

| Action | Description |
|--------|-------------|
| `add` | Add a new entry |
| `remove`, `rm` | Remove an entry |
| `list`, `ls` | List all entries |
| `restore` | Restore from backup |
| `clean` | Remove PATH entries pointing to missing directories |
| `dedup` | Remove duplicate PATH entries |
| `help` | Show command-specific help |

### Flags

| Flag | Description |
|------|-------------|
| `--shell <bash\|zsh>` | Override shell detection |
| `--dry-run`, `-n` | Preview changes without applying |
| `--yes`, `-y` | Skip confirmation prompts |
| `--tui` | Launch interactive TUI |
| `--from <shell>` | Source shell for migration |
| `--to <shell>` | Target shell for migration |
| `-v`, `--version` | Show version |

## Exit Codes

BSD sysexits.h compatible for scripting:

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 64 | Usage error (bad arguments) |
| 65 | Data format error |
| 66 | Input file not found |
| 73 | Cannot create output file |
| 74 | I/O error |
| 77 | Permission denied |
| 78 | Configuration error |

## TUI Mode

Launch with `wayu --tui` for an interactive terminal interface.

- Vim-style navigation (`j`/`k`, arrow keys)
- Add and delete entries with confirmation modals
- Fuzzy search and inline filtering
- Tab-navigable forms with focus indicators
- Automatic backups before modifications
- Dashboard-style main menu

Built from scratch with raw termios control, alternate screen buffer, differential rendering, and signal handling. No external TUI libraries.

## Configuration

wayu stores shell-specific config files in `~/.config/wayu/`:

```
~/.config/wayu/
  init.{zsh,bash}        # main orchestrator (source this in your RC file)
  path.{zsh,bash}        # PATH entries
  aliases.{zsh,bash}     # alias definitions
  constants.{zsh,bash}   # environment variable exports
  tools.{zsh,bash}       # external tool initialization
  completions/            # Zsh completion scripts
  backup/                 # timestamped backups
```

Shell is detected automatically from `$SHELL`. Override with `--shell bash` or `--shell zsh`.

## Development

Uses [bld](https://github.com/kakurega/bld), an Odin build system library. No external tools required.

```bash
# Bootstrap (once)
odin build build -out:build_it

# Build & test
./build_it build          # optimized release build
./build_it debug          # debug build with symbols
./build_it test           # unit tests (434 tests)
./build_it check          # type-check only
./build_it dev path list  # debug build + run
./build_it clean          # remove build artifacts
./build_it install        # build + install to /usr/local/bin
./build_it help           # show all targets
```

## Architecture

- **~17K lines of Odin**, zero external dependencies
- **Dual-mode architecture**: CLI (non-interactive, scriptable) and TUI (interactive, Elm Architecture)
- **Array-based PATH**: centralized `WAYU_PATHS=()` array with single export loop
- **Input validation**: shell identifier validation, reserved word checking, injection hardening
- **Memory management**: arena-first allocation, explicit `defer delete()` cleanup, zero leaks under tracking allocator
- **434 tests**: unit, integration, and golden-file visual regression

## License

MIT
