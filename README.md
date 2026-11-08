# wayu

**v5.0.0** · A shell configuration management CLI written in [Odin](https://odin-lang.org/) with zero external dependencies. Manages PATH entries, aliases, environment variables, completions, and backups across Bash, Zsh, and Fish.

## Features

- **Multi-shell** -- Automatic Bash/Zsh/Fish detection with shell-specific config files
- **Dual mode** -- Non-interactive CLI for scripting + interactive TUI (default when run with no args)
- **PATH management** -- TOML-based keyed entries with deduplication and validation
- **Alias & constants** -- Add, remove, list with input validation and reserved word checking
- **Fuzzy matching** -- Smart search with acronym support (e.g., `faak` → `FIREWORKS_AI_API_KEY`)
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

Prebuilt for macOS arm64 and Linux x86_64; on other platforms build from
source.

### From source

Requires the [Odin compiler](https://odin-lang.org/docs/install/) at the
release named in [`.github/odin-release`](.github/odin-release) — the one CI
and releases are built with (download it from
[Odin releases](https://github.com/odin-lang/Odin/releases)); `./build_it`
warns when your `odin` is a different release.

```bash
# Bootstrap the build system, then build, install and run `wayu init`
odin build build -out:build_it && ./build_it install
```

`./build_it install` puts the binary in `$PREFIX/bin` (default
`~/.local/bin`, which must be on your `PATH`), replacing it atomically, and
warns when another `wayu` earlier on `PATH` shadows it.

**Use one install method.** While Homebrew manages wayu, `./build_it install`
refuses to run (`--force` overrides): two copies on `PATH` mean the shell
runs one version and you upgrade the other. To switch from Homebrew to a
source build, `brew uninstall wayu` first; to switch back, delete
`~/.local/bin/wayu`.

## Shell setup

`wayu init` creates `~/.config/wayu/` (a `wayu.toml` scaffold plus the
generated files) and offers to add one line to your rc file — or prints it
when stdin is not a terminal:

| Shell | rc file | Line |
|---|---|---|
| zsh | `${ZDOTDIR:-~}/.zshrc` | `source "$HOME/.config/wayu/init.zsh"` |
| bash | `~/.bash_profile` if it exists, else `~/.bashrc` | `source "$HOME/.config/wayu/init.bash"` |
| fish | `~/.config/fish/config.fish` | `source ~/.config/wayu/init.fish` |

The shell is detected from `$SHELL`; `wayu init --shell bash` (or `zsh`,
`fish`) picks another one. Run `wayu init` once per shell you use; they share
one `wayu.toml`.

`init.<ext>` sources one precomputed file, `core.<ext>`, which wayu rewrites
after every change (`wayu path|alias|const …`, the TUI, `wayu build`). That
is the recommended setup. The alternatives:

| rc line | When |
|---|---|
| `source "$HOME/.config/wayu/init.zsh"` | Default. Fast; picks up every wayu change. |
| `source "$HOME/.config/wayu/turbo.zsh"` | Only for rc files that already use it: `turbo.<ext>` (zsh/bash, written by `wayu export`) is a copy of `core.<ext>`, kept current by wayu. |
| `eval "$(wayu build eval)"` | Regenerates the init files from `wayu.toml` at every shell start, then sources `core.<ext>`. Use it when `wayu.toml` is edited outside wayu (e.g. synced dotfiles) and you never want to run `wayu build`; it costs one `wayu` run per shell. |
| `eval "$(wayu export --eval)"` | Only `[env]`, `[paths]` and `[aliases]`, as shell code, without plugins, `[tools]`, prompt or completions. For scripts, containers or CI that want the variables but none of the interactive setup. Writes nothing. |

After editing `wayu.toml` by hand, run `wayu build` (or `wayu toml validate`
first). `[paths]` changes reach shells that are already open at their next
prompt (see [PATH changes in open shells and
scripts](#path-changes-in-open-shells-and-scripts)); other changes apply to
new shells, or `source` the init file again.

Every key of `wayu.toml` and the other config files is described in
[docs/config-reference.md](docs/config-reference.md).

## Upgrading

```bash
brew upgrade wayu        # or, from source: git pull && ./build_it install
wayu init                # refresh init.<ext> and regenerate core.<ext>
wayu doctor              # check the result
```

`wayu init` keeps `wayu.toml`, `extra.<ext>` and your other files; an
unmodified `init.<ext>` from an older release is replaced (the old one is
backed up). Any ordinary write (`wayu alias add …`) regenerates too.

- `wayu.toml` from wayu 3.x (`[[paths]]` arrays of tables): every command
  exits `78` until you run `wayu migrate --schema`.
- wayu ≤ 3.9 (no `wayu.toml`, entries in `path.zsh` / `aliases.zsh` /
  `constants.zsh`): run `wayu migrate`, then `wayu init`.

What changed in each release, and what you may need to adapt, is in
[docs/UPGRADING.md](docs/UPGRADING.md).

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
wayu constants list            # secret-looking values shown as ********
wayu constants list --reveal   # show real values
wayu constants rm EDITOR

# Fuzzy matching - smart search with acronym support
wayu search api                # search across all configs
wayu find faak                 # finds FIREWORKS_AI_API_KEY by acronym
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
wayu backup restore path --yes   # restore the latest wayu.toml backup

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

# Startup time (init.<shell> is already a single precomputed file)
wayu build profile               # time each section of the generated init
wayu export                      # turbo.zsh: same content as core.zsh (kept for old rc files)

# Diagnostics
wayu doctor                      # Health check all configs
wayu doctor --fix --yes          # Auto-fix issues (--dry-run to preview)

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
wayu <command> [<action>] [arguments] [flags]
```

**[docs/cli.md](docs/cli.md)** documents every command, action and flag,
where flags are recognised (`--` and the `alias add` / `const add` value
rule), the `--json` document shapes and the exit codes.
`wayu help` and `wayu <command> help` print the same from the binary.

| Command | Description |
|---------|-------------|
| `path` | Manage `[paths]` (PATH entries) |
| `alias` | Manage `[aliases]` |
| `constants`, `const`, `env` | Manage `[env]` (environment variables) |
| `search`, `find`, `f` | Fuzzy search across all configurations |
| `completions` | Manage shell completion scripts |
| `backup` | List, restore and prune backups |
| `plugin` | Install and manage shell plugins |
| `init` | Create the config and wire up your shell |
| `migrate` | Import legacy files, upgrade an old wayu.toml, switch shells |
| `config` | Edit wayu.toml / extra.<shell>, scan your rc file |
| `build` | Regenerate the init files; `profile` startup; clear the evalcache |
| `export` | Write turbo.<shell> or print env/PATH/aliases for eval |
| `toml` | Validate / show wayu.toml |
| `doctor` | Health check and diagnostics (`--json`, `--fix`) |
| `template` | Apply config presets (developer / minimal / data-science / full) |
| `hooks` | Pre/post operation hooks |
| `function`, `functions`, `func`, `fn` | Manage custom shell functions in `~/.config/wayu/functions/` |
| `reload`, `watch`, `hot-reload` | Watch wayu.toml and regenerate on change |
| `version` | Show version |
| `help` | Show help |

## Fuzzy Matching

wayu includes intelligent fuzzy matching that makes finding configurations effortless:

### Search Command

Search across all your configurations simultaneously:

```bash
# Search by partial name
wayu search api
# Constants (2 found)
# ────────────────────────────────────
#   OPENAI_API_KEY [substring] ★
#   FIREWORKS_AI_API_KEY [substring] ★

# Search by acronym (first letter of each word)
wayu find faak            # matches FIREWORKS_AI_API_KEY
wayu f oak                # matches OPENAI_API_KEY
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
| `acronym` | First letters of the words | `search faak` → `FIREWORKS_AI_API_KEY` |
| `fuzzy` | General fuzzy match | `search frwrks` → `FIREWORKS...` |

### Secret values

Constants whose name looks like a credential (contains `KEY`, `TOKEN`,
`SECRET`, `PASS`, `API`, `AUTH`, `CREDENTIAL`, `PRIVATE`, ...) or whose value
looks like one (`sk-...`, `ghp_...`, `scheme://user:pass@host`, ...) are shown
as `********` in `const list` (text and `--json`, with or without `--full`;
external environment variables included), `toml show`, the TUI constants
view, `search` results and `--dry-run` previews. `search` matches constant
names only, never their values. Pass `--reveal` to `const list` / `toml show`
(or press `v` in the TUI constants view) to see real values; `const get NAME`
always prints the real value.

### Score Indicators

- `★` - High confidence match (score > 1000)
- `◆` - Medium confidence match (score > 500)

## Exit Codes

BSD `sysexits.h` values for scripting: `0` success, `64` usage error, `65`
bad input, `66` missing input file, `78` configuration error, … — the full
table, with examples checked by the test suite, is in
[docs/cli.md](docs/cli.md#exit-codes).

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
| `v` | Constants | Reveal / hide secret-looking values (masked by default) |
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
  tools.{zsh,bash,fish}     # one-off tool setup not expressible as [tools]
  alias-sources.conf        # external alias sources (shell-agnostic, read-only)
  hooks.conf                # pre/post operation hooks
  functions/                # custom shell functions

  # --- wayu generates these (safe to delete; regenerated on change) ---
  init.{zsh,bash,fish}      # entry point — source THIS in your RC file
  core.{zsh,bash,fish}      # the generated init loaded by init.<shell> (one precomputed file)
  path_sync.{zsh,bash,fish} # [paths] list re-read by the live PATH sync prompt hook
  plugins.json              # installed plugin metadata (JSON5)
  plugins.{zsh,bash,fish}   # generated plugin loader
  plugins/                  # cloned plugin repos + runtime config
  turbo.{zsh,bash}          # optional copy of core via `wayu export` (zsh/bash only)
  completions/              # shell completion scripts
  backup/                   # timestamped backups (last 5 per file)
  path.{zsh,bash}           # legacy PATH entries (bootstrap/back-compat)
  aliases.{zsh,bash}        # legacy alias definitions (bootstrap/back-compat)
  constants.{zsh,bash}      # legacy env exports (bootstrap/back-compat)
```

Shell is detected automatically from `$SHELL`. Override with `--shell bash`, `--shell zsh`, or `--shell fish`.

`WAYU_CONFIG_DIR` moves the files you edit and `WAYU_DATA_DIR` the
generated ones (default: the config dir). Every `wayu.toml` table and key
(`[paths]`, `[aliases]`, `[env]`, `[tools]`, `[prompt]`, …), `hooks.conf`,
`plugins.json` and the other files are described in
[docs/config-reference.md](docs/config-reference.md).

### PATH changes in open shells and scripts

`wayu path add/rm` (and edits to `[paths]` in `wayu.toml`) reach already-open
zsh/bash shells at their next prompt: `core.<ext>` installs a prompt hook,
`_wayu_paths_sync` (zsh `precmd`, bash `PROMPT_COMMAND`, fish `fish_prompt`
event), that re-reads `path_sync.<ext>` only when the `[paths]` list
changed.

**Scripts** never show a prompt, so the hook never runs. A script that sources
`init.<ext>` and changes `[paths]` applies the change itself:

```bash
source "$HOME/.config/wayu/init.bash"   # or init.zsh
wayu path add "$HOME/tools/bin"
_wayu_paths_sync                        # PATH now includes ~/tools/bin
```

A script that did not source `init.<ext>` has no `_wayu_paths_sync`; extend
`PATH` yourself (`PATH="$HOME/tools/bin:$PATH"`) — `wayu`, a child process,
cannot change its caller's environment.

**bash and `PROMPT_COMMAND`:** wayu prepends `_wayu_paths_sync` to
`PROMPT_COMMAND` when `init.bash` is sourced. A later line that *replaces*
it (`PROMPT_COMMAND='history -a'`) silently drops the hook. Append instead
(`PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND;}history -a"` or, in
bash ≥ 5.1, `PROMPT_COMMAND+=(...)`), or source `init.bash` after it.
`wayu doctor` warns about such lines in your bash startup files.

### Startup time

`init.<shell>` loads one generated file, `core.<shell>`: everything from
`wayu.toml` is precomputed into straight-line code (zcompiled for zsh), and
the dynamic parts — `[tools]` lazy loaders, the native prompt, live PATH
sync — are function definitions and hooks, not work done at startup. zsh
runs `compinit` (with a cached, zcompiled `.zcompdump`) and sets up the
prompt in interactive shells only.

Measured with `tests/benchmark/startup.sh` (20 `[paths]`, 60 `[aliases]`,
20 `[env]`; macOS, hyperfine, empty zsh ≈ 3.5 ms, empty bash ≈ 2–3 ms):

| | before (5.0) | now |
|---|---|---|
| `zsh -f -c 'source init.zsh'` | 22.8 ms | 9.3 ms |
| `zsh -f -i -c 'source init.zsh'` (compinit) | 22.3 ms | 16.0 ms |
| same + `[tools]` + native prompt, `zsh -f -c` / `-i` | 23.4 / 23.4 ms | 8.8 / 14.9 ms |
| `bash --norc -c 'source init.bash'` | 9.3 ms | ≈ 5 ms |

Where the old time went (zsh): `compinit` ~14 ms (8 ms of it remains in
interactive shells, with the zcompiled dump), the `[tools]` evalcache lookup
`${commands[...]}` hashing every PATH dir ~2 ms, the PATH apply ~0.8 ms,
four extra files sourced (path_sync, helpers, lazy, login) ~0.3 ms. bash:
the PATH apply ~2 ms (here-strings write a temp file each in bash 3.2;
multibyte pattern matching). `wayu build profile` times each `# === ... ===`
section of your own core file.

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
See [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow and [SECURITY.md](SECURITY.md)
to report a vulnerability; contributor notes on the code are in [AGENTS.md](AGENTS.md).

```bash
# Bootstrap (once)
odin build build -out:build_it

# Build & test
./build_it build          # optimized release build
./build_it debug          # debug build with symbols
./build_it test           # unit tests; leaks fail them (NAME[,NAME] runs only those)
./build_it check          # type-check only
./build_it dev path list  # debug build + run
./build_it clean          # remove build artifacts
./build_it install        # build + install to ~/.local/bin ($PREFIX/bin) + wayu init
./build_it release [vX.Y.Z] # manual release override (version optional; see Releasing)
./build_it help           # show all targets

# Integration Tests (Ruby)
ruby tests/integration/run_all.rb
```

## Releasing

Day-to-day work lands on the **`develop`** branch (CI runs, nothing is
released). When a batch is ready to ship, `develop` is merged into `main`;
PRs into `main` are only accepted from `develop` or `hotfix/*`
([`main-guard.yml`](.github/workflows/main-guard.yml)).

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

Behavior changes users must know about are marked breaking (`fix(scope)!:` or a
`BREAKING CHANGE:` footer): they force a major bump and are listed under
"⚠ Upgrade notes" in the changelog and release.

So you do **not** bump the version by hand — land your Conventional Commits on
`develop` and merge `develop` into `main` to ship. `./build_it release [vX.Y.Z]` exists as a manual override (it also
auto-detects the version when the argument is omitted); the version argument is
only needed when `git-cliff` is unavailable.

## License

MIT
