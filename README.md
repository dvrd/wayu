# wayu

A shell configuration management CLI written in [Odin](https://odin-lang.org/) with zero external dependencies. Manages PATH entries, aliases, environment variables, completions, and backups across Bash and Zsh.

## Features

- **Multi-shell** -- Automatic Bash/Zsh detection with shell-specific config files
- **Dual mode** -- Non-interactive CLI for scripting + interactive TUI for humans
- **PATH management** -- Centralized array-based system with deduplication and validation
- **Alias & constants** -- Add, remove, list with input validation and reserved word checking
- **Fuzzy matching** -- Smart search with acronym support (e.g., `frwrks` → `FIREWORKS_AI_API_KEY`)
- **Completions** -- Manage Zsh completion scripts
- **Plugin management** -- Install, enable/disable, and prioritize shell plugins with dependency resolution
- **Backup & restore** -- Automatic timestamped backups before every modification
- **Shell migration** -- Migrate configs between Bash and Zsh
- **Dry-run mode** -- Preview any change before applying it
- **Scriptable** -- BSD sysexits.h exit codes, no interactive prompts in CLI mode
- **Zero dependencies** -- Pure Odin, ~38K lines, compiles in seconds

## Installation

### Homebrew (recommended)

```bash
brew tap dvrd/wayu
brew install wayu
wayu init
```

### From source

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

# Fuzzy matching - smart search with acronym support
wayu search api                # search across all configs
wayu find frwrks               # finds FIREWORKS_AI_API_KEY by acronym
wayu f git                     # short alias for search

# Fuzzy GET - get values even with partial matches
wayu const get frwrks          # gets FIREWORKS_AI_API_KEY (fuzzy match)
wayu const get ai_key          # gets any constant containing "ai_key"
wayu alias get gcm             # gets "git commit -m" (fuzzy match)

# Completions (Zsh)
wayu completions add jj /path/to/_jj
wayu completions list

# Backups
wayu backup list
wayu backup restore path

# Plugins
wayu plugin search                          # browse popular plugins
wayu plugin search syntax                   # filter by keyword
wayu plugin add zsh-autosuggestions         # install popular plugin
wayu plugin add https://github.com/user/plugin.git  # install from URL
wayu plugin list                            # list installed plugins
wayu plugin enable zsh-autosuggestions
wayu plugin disable zsh-autosuggestions
wayu plugin priority zsh-autosuggestions 50 # lower = loads earlier
wayu plugin update --all
wayu plugin remove zsh-autosuggestions --yes

# Extra configuration (scripts that run at shell startup end)
wayu config edit                 # Edit wayu.toml (declarative config)
wayu config extend               # Edit extra.zsh (custom scripts)
wayu config scan                 # Detect scripts in .zshrc to migrate

# Turbo export (fast shell startup)
wayu export                      # Generate turbo.zsh
# Then in .zshrc: source "$HOME/.config/wayu/turbo.zsh"

# Diagnostics
wayu doctor                      # Health check all configs
wayu doctor --fix                # Auto-fix issues

# TOML configuration (declarative mode)
wayu toml validate               # Check wayu.toml syntax

# Shell migration
wayu migrate --from zsh --to bash

# Hot reload (auto-regenerate static output on save)
wayu reload start                # alias: wayu watch
wayu reload status
wayu reload stop

# Pre/post hooks (run custom commands around wayu operations)
wayu hooks                       # show configured hooks
wayu hooks edit                  # edit ~/.config/wayu/hooks.conf

# Templates (config presets)
wayu init --template developer   # bootstrap with a preset
wayu template list               # available: developer, minimal, data-science, full
wayu template apply minimal      # apply preset to existing config

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
| `constants`, `const` | Manage environment variables |
| `search`, `find`, `f` | Fuzzy search across all configurations |
| `completions` | Manage Zsh completion scripts |
| `plugin` | Install and manage shell plugins |
| `config` | Manage extra config and TOML files |
| `export` | Generate turbo export for fast startup |
| `doctor` | Health check and diagnostics |
| `toml` | TOML configuration management |
| `template` | Apply config presets (developer / minimal / data-science / full) |
| `hooks` | Pre/post operation hooks |
| `reload`, `watch`, `hot-reload` | Watch config files and regenerate on change |
| `backup` | Manage configuration backups |
| `init` | Initialize config directory (`--template <preset>` to bootstrap) |
| `migrate` | Migrate config between shells |
| `version` | Show version |
| `help` | Show help |

### Actions

| Action | Description |
|--------|-------------|
| `add` | Add a new entry |
| `remove`, `rm` | Remove an entry |
| `list`, `ls` | List all entries |
| `get` | Get value by name (with fuzzy fallback) |
| `restore` | Restore from backup |
| `clean` | Remove PATH entries pointing to missing directories |
| `dedup` | Remove duplicate PATH entries |
| `edit` | Edit config file in `$EDITOR` (`config`, `hooks`) |
| `extend`, `scan` | Manage `extra.zsh` (`config extend`, `config scan`) |
| `apply` | Apply preset (`template apply <name>`) |
| `validate` | Schema-check `wayu.toml` (`toml validate`) |
| `start`, `stop`, `status` | Manage the file watcher (`reload`) |
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

## Fuzzy Matching

wayu includes intelligent fuzzy matching that makes finding configurations effortless:

### Search Command

Search across all your configurations simultaneously:

```bash
# Search by partial name
wayu search api
# Constants (2 found)
# ────────────────────────────────────
#   OPENAI_API_KEY [substring] ◆
#   FIREWORKS_AI_API_KEY [acronym] ★

# Search by acronym (each uppercase letter)
wayu find frwrks          # matches FIREWORKS_AI_API_KEY
wayu f oapi               # matches OPENAI_API_KEY
wayu f gcm                # matches git commit aliases

# Search all configs at once
wayu search git
# Shows aliases, constants, and paths related to "git"
```

### Fuzzy GET Fallback

When using `get` with an inexact name, wayu automatically tries fuzzy matching:

```bash
# Exact match works as expected
wayu const get FIREWORKS_AI_API_KEY
# sk-abc123...

# Fuzzy match finds it by acronym
wayu const get frwrks
# Note: Using acronym match 'FIREWORKS_AI_API_KEY' for 'frwrks'
# sk-abc123...

# Partial matches work too
wayu const get fireworks          # prefix match
wayu const get api_key            # substring match
wayu const get fwks               # fuzzy/acronym match
```

### Match Types

| Type | Description | Example |
|------|-------------|---------|
| `exact` | Exact match | `get API_KEY` → `API_KEY` |
| `prefix` | Starts with query | `get FIRE` → `FIREWORKS...` |
| `substring` | Contains query | `get WORKS` → `FIREWORKS...` |
| `acronym` | Matches uppercase letters | `get frwrks` → `FIREWORKS...` |
| `fuzzy` | General fuzzy match | `get frwrx` → `FIREWORKS...` |

### Score Indicators

- `★` - High confidence match (score > 1000)
- `◆` - Medium confidence match (score > 500)

### Environment Variables

Control fuzzy matching behavior:

```bash
export WAYU_FFF_ENABLED=0        # Disable fuzzy features
export WAYU_FFF_AUTO_FALLBACK=0  # Disable auto fuzzy fallback on GET
export WAYU_FFF_INTERACTIVE=0    # Disable interactive selector
```

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

**Plugin view keybindings** (navigate to Plugins from the main menu):

| Key | Action |
|-----|--------|
| `j` / `k` | Move selection up/down |
| `e` | Enable selected plugin |
| `d` | Disable selected plugin |
| `q` / `Esc` | Return to main menu |

Built from scratch with raw termios control, alternate screen buffer, differential rendering, and signal handling. No external TUI libraries.

## Configuration

wayu stores shell-specific config files in `~/.config/wayu/`:

```
~/.config/wayu/
  init.{zsh,bash}           # main orchestrator
  path.{zsh,bash}           # PATH entries
  aliases.{zsh,bash}        # alias definitions
  constants.{zsh,bash}      # environment variable exports
  tools.{zsh,bash}          # external tool initialization
  alias-sources.conf        # external alias sources (shell-agnostic, read-only)
  completions/              # Zsh completion scripts
  backup/                   # timestamped backups
```

Shell is detected automatically from `$SHELL`. Override with `--shell bash` or `--shell zsh`.

### External Alias Sources

`alias-sources.conf` lets you surface aliases from external tools (e.g. [fabric](https://github.com/danielmiessler/fabric) patterns) in `wayu alias list` as read-only sections.

```
# Format: dir <path> <command_template>
# {name} is replaced with each directory entry name
dir ~/.config/fabric/patterns fabric --pattern {name}
```

- Lines starting with `#` are comments
- Only `dir` type is supported — one alias per subdirectory (or per file if no subdirectories exist)
- Sources appear as labelled read-only tables after your managed aliases
- Missing directories are silently skipped

## Development

Uses [bld](https://github.com/dvrd/bld), an Odin build system library. No external tools required.

```bash
# Bootstrap (once)
odin build build -out:build_it

# Build & test
./build_it build          # optimized release build
./build_it debug          # debug build with symbols
./build_it test           # unit tests (557 tests)
./build_it check          # type-check only
./build_it dev path list  # debug build + run
./build_it clean          # remove build artifacts
./build_it install        # build + install to /usr/local/bin
./build_it help           # show all targets

# Integration Tests
./build_it test:all           # unit + integration
cd tests/integration && odin run integration_tests.odin
```

## License

MIT
