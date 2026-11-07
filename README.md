# wayu

**v4.3.4** · A shell configuration management CLI written in [Odin](https://odin-lang.org/) with zero external dependencies. Manages PATH entries, aliases, environment variables, completions, and backups across Bash, Zsh, and Fish.

## Features

- **Multi-shell** -- Automatic Bash/Zsh/Fish detection with shell-specific config files
- **Dual mode** -- Non-interactive CLI for scripting + interactive TUI (default when run with no args)
- **PATH management** -- TOML-based keyed entries with deduplication and validation
- **Alias & constants** -- Add, remove, list with input validation and reserved word checking
- **Fuzzy matching** -- Smart search with acronym support (e.g., `frwrks` → `FIREWORKS_AI_API_KEY`)
- **Completions** -- Manage shell completion scripts (Zsh, Bash, Fish)
- **Plugin management** -- Install, enable/disable, and prioritize shell plugins with dependency resolution
- **Custom functions** -- `wayu function add` seeds a skeleton in `~/.config/wayu/functions/`, opens `$EDITOR`, and sources it on startup
- **Backup & restore** -- Automatic timestamped backups before every modification
- **Shell migration** -- Migrate configs between Bash, Zsh, and Fish
- **Dry-run mode** -- Preview any change before applying it
- **Scriptable** -- BSD sysexits.h exit codes, no interactive prompts in CLI mode
- **Zero dependencies** -- Pure Odin, ~31K lines, compiles in seconds

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

> **Tip:** Running `wayu` with no arguments opens the interactive TUI.

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

# GET is exact-match only (safe for X=$(wayu const get NAME))
wayu const get FIREWORKS_AI_API_KEY   # prints the value
wayu const get FIRE                   # exit 65, suggests names on stderr

# Completions
wayu completions add jj /path/to/_jj
wayu completions list
wayu completions generate          # generate wayu self-completions (zsh + bash + fish)

# Backups
wayu backup list
wayu backup restore path

# Plugins
wayu plugin search                          # browse popular plugins
wayu plugin search syntax                   # filter by keyword
wayu plugin add autosuggestions             # install popular plugin (registry key)
wayu plugin add https://github.com/user/plugin.git  # install from URL
wayu plugin list                            # list installed plugins
wayu plugin enable zsh-autosuggestions
wayu plugin disable zsh-autosuggestions
wayu plugin priority zsh-autosuggestions 50 # lower = loads earlier
wayu plugin update --all
wayu plugin remove zsh-autosuggestions --yes

# Extra configuration (scripts that run at shell startup end)
wayu config edit                 # Edit wayu.toml (declarative config)
wayu config extend               # Edit extra.<shell> (custom scripts)
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

# Custom shell functions (stored in ~/.config/wayu/functions/, sourced at startup)
wayu function add mkcd           # seed a skeleton and open it in $EDITOR
wayu function list               # list defined functions
wayu function remove mkcd --yes  # delete a function file

# Templates (config presets)
wayu template list               # available: developer, minimal, data-science, full
wayu template apply developer    # apply preset to existing config
wayu template apply minimal      # minimal preset

# Interactive mode
wayu                             # TUI opens by default with no args
wayu --tui                       # explicit flag
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
| `constants`, `const`, `env` | Manage environment variables |
| `search`, `find`, `f` | Fuzzy search across all configurations |
| `completions` | Manage shell completion scripts |
| `plugin` | Install and manage shell plugins |
| `config` | Manage extra config and TOML files |
| `export` | Generate turbo export for fast startup |
| `doctor` | Health check and diagnostics |
| `toml` | TOML configuration management |
| `template` | Apply config presets (developer / minimal / data-science / full) |
| `hooks` | Pre/post operation hooks |
| `function` | Manage custom shell functions in `~/.config/wayu/functions/` (opens `$EDITOR`) |
| `reload`, `watch`, `hot-reload` | Watch config files and regenerate on change |
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
| `get` | Get value by exact name (miss: exit 65 + name suggestions on stderr) |
| `restore` | Restore from backup |
| `clean` | Remove PATH entries pointing to missing directories |
| `dedup` | Remove duplicate PATH entries |
| `edit` | Edit config file in `$EDITOR` (`config`, `hooks`) |
| `extend`, `scan` | Manage extra config (`config extend`, `config scan`) |
| `apply` | Apply preset (`template apply <name>`) |
| `validate` | Schema-check `wayu.toml` (`toml validate`) |
| `start`, `stop`, `status` | Manage the file watcher (`reload`) |
| `help` | Show command-specific help |

### Flags

| Flag | Description |
|------|-------------|
| `--shell <bash\|zsh\|fish>` | Override shell detection |
| `--dry-run`, `-n` | Preview changes without applying |
| `--yes`, `-y` | Skip confirmation prompts |
| `--tui` | Launch interactive TUI |
| `--json` | Machine-readable output (doctor, list, plugin list) |
| `--source <filter>` | List filter: `all`, `wayu`, `external`, `inactive` |
| `--no-color` | Disable ANSI colors (equivalent to `NO_COLOR=1`) |
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

### GET is exact

`get` never guesses: it prints the value of the entry with exactly that name.
On a miss it exits 65 (`EXIT_DATAERR`) and lists similar **names** (never
values) on stderr, so `X=$(wayu const get NAME)` can't silently receive a
different secret.

```bash
wayu const get FIREWORKS_AI_API_KEY   # prints the value
wayu const get FIRE
# ERROR: Constant not found: FIRE
# Did you mean:
#   FIREWORKS_AI_API_KEY
```

### Match Types

| Type | Description | Example |
|------|-------------|---------|
| `exact` | Exact match | `search API_KEY` → `API_KEY` |
| `prefix` | Starts with query | `search FIRE` → `FIREWORKS...` |
| `substring` | Contains query | `search WORKS` → `FIREWORKS...` |
| `acronym` | Matches uppercase letters | `search frwrks` → `FIREWORKS...` |
| `fuzzy` | General fuzzy match | `search frwrx` → `FIREWORKS...` |

### Secret values

Constants whose name looks like a credential (contains `KEY`, `TOKEN`,
`SECRET`, `PASS`, `API`, `AUTH`, `CREDENTIAL`, `PRIVATE`, ...) or whose value
looks like one (`sk-...`, `ghp_...`, `scheme://user:pass@host`, ...) are shown
as `********` in `search` results and `--dry-run` previews. `search` matches
constant names only, never their values. `const get NAME` and `const list`
still print real values.

### Score Indicators

- `★` - High confidence match (score > 1000)
- `◆` - Medium confidence match (score > 500)

### Environment Variables

Control fuzzy matching behavior:

```bash
export WAYU_FFF_ENABLED=0        # Disable fuzzy features
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

Launch with `wayu` (no args) or `wayu --tui` for an interactive terminal interface.

- Vim-style navigation (`j`/`k`, `h`/`l`, arrow keys)
- Inline fuzzy filtering with `/`
- Source filter cycling with `s` (all → wayu → inactive → external)
- Add and delete entries with confirmation modals
- Tab-navigable forms with focus indicators
- Automatic backups before modifications
- Dashboard-style main menu with 8 views

**Keybindings:**

| Key | Context | Action |
|-----|---------|--------|
| `j` / `k` / ↑ / ↓ | All views | Move selection |
| `l` / Enter | All views | Select / enter |
| `h` / Esc | All views | Go back |
| `q` | Main menu | Quit |
| `/` | Data / plugin views | Start inline filter |
| `s` | PATH / Alias / Constants | Cycle source filter |
| `a` | PATH / Alias / Constants | Add entry (modal form) |
| `d` / `x` | PATH / Alias / Constants | Delete entry (with confirmation) |
| Tab / `t` | Plugins view | Switch Installed ↔ Registry tab |
| `e` | Plugins (Installed) | Enable selected plugin |
| `d` | Plugins (Installed) | Disable selected plugin |
| `i` / Enter | Plugins (Registry) | Install selected plugin |
| `c` | Backups view | Cleanup old backups |
| Ctrl+C | Anywhere | Quit |

Built from scratch with raw termios control, alternate screen buffer, differential rendering, and signal handling. No external TUI libraries.

## Configuration

wayu stores everything under `~/.config/wayu/` — the files you edit and the files it generates:

```
~/.config/wayu/
  # --- You edit these (version-control them) ---
  wayu.toml                 # declarative config (source of truth for path/alias/env)
  extra.{zsh,bash,fish}     # custom scripts (conda init, tool evals, etc.)
  alias-sources.conf        # external alias sources (shell-agnostic, read-only)
  hooks.conf                # pre/post operation hooks
  functions/                # custom shell functions

  # --- wayu generates these (safe to delete; regenerated on change) ---
  init.{zsh,bash,fish}      # entry point — source THIS in your RC file
  core.{zsh,bash}           # generated optimized init loaded by init.<shell>
  lazy.{zsh,bash}           # deferred plugin/tool loading (zsh/bash only)
  helpers.{zsh,bash}        # utility functions, evalcache, built-in zsh-defer (zsh/bash only)
  plugins.json              # installed plugin metadata (JSON5)
  plugins.{zsh,bash,fish}   # generated plugin loader
  plugins/                  # cloned plugin repos + runtime config
  turbo.{zsh,bash}          # pre-computed fast startup via `wayu export` (zsh/bash only)
  completions/              # shell completion scripts
  backup/                   # timestamped backups (last 5 per file)
  path.{zsh,bash}           # legacy PATH entries (bootstrap/back-compat)
  aliases.{zsh,bash}        # legacy alias definitions (bootstrap/back-compat)
  constants.{zsh,bash}      # legacy env exports (bootstrap/back-compat)
```

Shell is detected automatically from `$SHELL`. Override with `--shell bash`, `--shell zsh`, or `--shell fish`.

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
./build_it test           # unit tests (473 tests)
./build_it check          # type-check only
./build_it dev path list  # debug build + run
./build_it clean          # remove build artifacts
./build_it install        # build + install to /usr/local/bin + wayu init
./build_it release [vX.Y.Z] # manual release override (version optional; see Releasing)
./build_it help           # show all targets

# Integration Tests (Ruby)
ruby tests/integration/run_all.rb
```

## Releasing

Releases are **automatic**. Every push to `main` runs
[`.github/workflows/bump.yml`](.github/workflows/bump.yml), which:

1. Runs the full CI workflow (unit, integration, golden, lint); nothing is
   released unless it passes.
2. Derives the next version from [Conventional Commits](https://www.conventionalcommits.org/)
   since the last tag via [`git-cliff`](https://github.com/orhun/git-cliff)
   (`feat` → minor, `fix`/`refactor`/etc. → patch, `!`/`BREAKING CHANGE` → major).
3. Bumps `VERSION` in `src/main.odin`, regenerates `CHANGELOG.md`, commits
   `chore: release vX.Y.Z`, and tags it.
4. Builds the release binaries (macOS arm64, Linux x86_64), publishes the
   GitHub release, and regenerates the Homebrew tap formula
   (`dvrd/homebrew-wayu`). Other platforms (macOS Intel, Linux arm64) have no
   prebuilt binary; brew refuses them with an architecture error.

The workflow never deletes or moves an existing tag or release: if the target
version's tag already exists elsewhere it fails and prints the manual fix.
CI uses the Odin release pinned in `.github/odin-release`.

So you do **not** bump the version by hand — just land your Conventional Commits
on `main`. `./build_it release [vX.Y.Z]` exists as a manual override (it also
auto-detects the version when the argument is omitted); the version argument is
only needed when `git-cliff` is unavailable.

## License

MIT
