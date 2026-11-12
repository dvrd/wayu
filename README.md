# wayu

**v7.0.0** · A shell configuration management CLI written in [Odin](https://odin-lang.org/) with zero external dependencies. Manages PATH entries, aliases, environment variables, completions, and backups across Bash, Zsh, and Fish.

![wayu demo: path, alias and run-only secret added, constants listed with the secret masked, a Python script created and run with the secret, doctor, then an alias added in the TUI](docs/demo/demo.gif)

<sub>Recorded with [VHS](https://github.com/charmbracelet/vhs) in a throwaway home: `vhs docs/demo/demo.tape` (see [docs/demo/](docs/demo/)). Website: [wayu.dvrd.io](https://wayu.dvrd.io).</sub>

## Features

- **Multi-shell** -- Automatic Bash/Zsh/Fish detection with shell-specific config files
- **Dual mode** -- Non-interactive CLI for scripting + interactive TUI (default when run with no args)
- **PATH management** -- TOML-based keyed entries with deduplication and validation
- **Alias & constants** -- Add, remove, list with input validation and reserved word checking
- **Fuzzy matching** -- Smart search with acronym support (e.g., `faak` → `FIREWORKS_AI_API_KEY`)
- **Completions** -- Manage shell completion scripts (Zsh, Bash, Fish)
- **Plugin management** -- Install, enable/disable, and prioritize shell plugins with dependency resolution
- **Built-in autosuggestions** -- opt-in fish-like history suggestions for zsh (`[settings] autosuggest = true`), without wrapping every zle widget like the zsh-autosuggestions plugin
- **Built-in syntax highlighting** -- opt-in command-line highlighting for zsh (`[settings] highlight = true`) with zsh-syntax-highlighting's styles, using zsh's own lexer, no widget wrapping and no forks; a keystroke re-highlights only the last words
- **Functions and scripts** -- shell functions (`wayu function`, sourced at startup) and standalone executables in any language (`wayu script`: swift compiled, python/ruby/node/bun/shells/... linked) on PATH; existing scripts can be imported
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

Prebuilt for macOS 15 Sequoia or later (Apple silicon and Intel) and Linux
(x86_64 and arm64, glibc); on other platforms build from source.

**Tested with** (anything else may work but isn't tested):

| | Versions |
|---|---|
| macOS | 15 (CI; Intel: CI smoke test), 26, 27 |
| Linux | Ubuntu 24.04 (CI; arm64: CI smoke test) |
| zsh | 5.9 |
| bash | 3.2 (macOS `/bin/bash`), 5.x |
| fish | 4.x |

### Install script

On the same platforms, without Homebrew:

```bash
curl -fsSL https://wayu.dvrd.io/install.sh | sh
wayu init
```

[`docs/install.sh`](docs/install.sh) (POSIX sh) downloads the release
archive for your OS and CPU, verifies its SHA-256 (and its build provenance
attestation when `gh` is installed and logged in), and installs `wayu` to
`~/.local/bin` atomically. `WAYU_VERSION=vX.Y.Z` pins a release,
`WAYU_INSTALL_DIR` picks the directory, and it refuses to install next to a
Homebrew-managed wayu unless `WAYU_FORCE=1`. Run it again to upgrade.

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
and the install script refuse to run (`--force` / `WAYU_FORCE=1`
override): two copies on `PATH` mean the shell runs one version and you
upgrade the other. To switch from Homebrew to a source build or the script,
`brew uninstall wayu` first; to switch back, delete `~/.local/bin/wayu`.

## Shell setup

`wayu init` creates `~/.config/wayu/` (a `wayu.toml` scaffold and the other
files you edit) and the data dir `~/.local/share/wayu/` (your PATH entries,
aliases and constants, plus the generated files), and offers to add one line
to your rc file — or prints it when stdin is not a terminal:

| Shell | rc file | Line |
|---|---|---|
| zsh | `${ZDOTDIR:-~}/.zshrc` | `source "${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.zsh"` |
| bash | `~/.bash_profile` if it exists, else `~/.bashrc` | `source "${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.bash"` |
| fish | `~/.config/fish/config.fish` | `if test -n "$WAYU_DATA_DIR"; source $WAYU_DATA_DIR/init.fish; else if test -n "$XDG_DATA_HOME"; source $XDG_DATA_HOME/wayu/init.fish; else; source ~/.local/share/wayu/init.fish; end` |

The line finds the data dir however it was chosen (`WAYU_DATA_DIR`,
`XDG_DATA_HOME`, or the default). The shell is detected from `$SHELL`;
`wayu init --shell bash` (or `zsh`, `fish`) picks another one. Run
`wayu init` once per shell you use; they share one `wayu.toml` and one set of
entries.

zsh: to give scripts (`zsh -c`, editors, cron) your PATH and env too, put the
line in `~/.zshenv` instead of `~/.zshrc` — once, not in both. A login shell
runs `/etc/zprofile` after `.zshenv`, and on macOS its `path_helper` moves the
system dirs ahead of yours; wayu puts its dirs back in front at the first
prompt, or right before the command in `zsh -l -c …` (dirs you prepend in
`.zshrc` stay ahead of them).

`init.<ext>` sources one precomputed file, `core.<ext>`, which wayu rewrites
after every change (`wayu path|alias|const …`, the TUI, `wayu build`). That
is the recommended setup. The alternatives:

| rc line | When |
|---|---|
| `source ".../wayu/init.zsh"` (the line above) | Default. Fast; picks up every wayu change. |
| `source "${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/turbo.zsh"` | Only for rc files that already use it: `turbo.<ext>` (zsh/bash, written by `wayu export`) is a copy of `core.<ext>`, kept current by wayu. |
| `eval "$(wayu export --eval)"` | Only constants, PATH entries and aliases, as shell code, without plugins, `[tools]`, prompt or completions. For scripts, containers or CI that want the variables but none of the interactive setup. Writes nothing. |

After editing `wayu.toml` by hand, run `wayu build` (or `wayu toml validate`
first). PATH changes reach shells that are already open at their next
prompt (see [PATH changes in open shells and
scripts](#path-changes-in-open-shells-and-scripts)); other changes apply to
new shells, or `source` the init file again.

Every key of `wayu.toml`, the entry store and the other config files is
described in [docs/config-reference.md](docs/config-reference.md).

## Upgrading

```bash
brew upgrade wayu        # or, from source: git pull && ./build_it install
wayu init                # refresh init.<ext> and regenerate core.<ext>
wayu doctor              # check the result
```

`wayu init` keeps `wayu.toml`, `extra.<ext>` and your other files; an
unmodified `init.<ext>` from the previous release is replaced (the old one is
backed up). Any ordinary write (`wayu alias add …`) regenerates too. From
7.0 on, a release that changes a data format or moves a file converts or
moves yours automatically the first time it runs (backup first, one-time
notice); see [docs/STABILITY.md](docs/STABILITY.md) for what each release
guarantees.

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
wayu backup restore entries --yes  # restore the latest entries.json backup

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

# Hot reload (auto-regenerate static output on save)
wayu reload start                # alias: wayu watch
wayu reload status
wayu reload stop

# Pre/post hooks (run custom commands around wayu operations)
wayu hooks                       # show configured hooks
wayu hooks edit                  # edit ~/.config/wayu/hooks.conf

# Functions and scripts (see "Functions and scripts" below)
wayu function add mkcd           # shell function: seed a skeleton, open $EDITOR
wayu script new hello --lang python  # executable on PATH: skeleton, $EDITOR, build
wayu script import ~/bin/* --dry-run # preview adopting existing scripts

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
| `path` | Manage PATH entries |
| `alias` | Manage aliases |
| `constants`, `const`, `env` | Manage constants (environment variables) |
| `search`, `find`, `f` | Fuzzy search across all configurations |
| `completions` | Manage shell completion scripts |
| `backup` | List, restore and prune backups |
| `plugin` | Install and manage shell plugins |
| `init` | Create the config and wire up your shell |
| `config` | Edit wayu.toml / extra.<shell>, scan your rc file |
| `build` | Regenerate the init files; `profile` startup; clear the evalcache |
| `export` | Write turbo.<shell> or print env/PATH/aliases for eval |
| `toml` | Validate / show wayu.toml |
| `doctor` | Health check and diagnostics (`--json`, `--fix`) |
| `template` | Apply config presets (developer / minimal / data-science / full) |
| `hooks` | Pre/post operation hooks |
| `function`, `functions`, `func`, `fn` | Manage shell functions (data dir `functions/`) |
| `script`, `scripts` | Manage standalone scripts on PATH (data dir `scripts/` + `bin/`) |
| `reload`, `watch`, `hot-reload` | Watch wayu.toml, entries.json, secrets.json and script sources; regenerate on change |
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

### Encrypted secrets

`wayu const add NAME --secret` reads the value from stdin (hidden on a
terminal) and stores it encrypted in `secrets.json`. Prefer the prompt or a
pipe: a value given as an argument also works, but is visible to other
local users in `ps` and saved in your shell history (wayu warns). Nothing
in the config or generated files holds the value in plaintext. The master key lives in the macOS keychain (Secret Service on
Linux, or a `0600` key file: `[secrets] backend = "file"`). Shells load
secrets from a per-session cache in `$XDG_RUNTIME_DIR` / `$TMPDIR`
(decrypted once, then sourced without forking); that cache is plaintext on
disk (`0600`) until `wayu secrets lock` or the next store change deletes it.

```bash
wayu const add OPENAI_API_KEY --secret      # prompts, input hidden
wayu const get OLD_TOKEN | wayu const add OLD_TOKEN --secret   # convert a plain one
wayu const get OPENAI_API_KEY               # decrypts
wayu secrets list                           # names and mode, never values
wayu secrets rekey                          # new master key
wayu secrets lock                           # drop the decrypted session cache
```

A **run-only** secret (`--run-only`) is never exported to your shells; only
`wayu secrets run NAME... -- CMD` decrypts it, into that one command's
environment (exec, no shell):

```bash
wayu const add GH_TOKEN --run-only
wayu alias add gh 'wayu secrets run GH_TOKEN -- gh'
```

See [docs/config-reference.md](docs/config-reference.md#secrets).

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
| Space | Plugins (Installed) | Enable / disable selected plugin |
| `e` / `x` | Plugins (Installed) | Enable / disable selected plugin |
| `u` | Plugins (Installed) | Update selected plugin (Esc cancels) |
| `d` | Plugins (Installed) | Remove selected plugin (with confirmation) |
| `i` | Plugins (Registry) | Install selected plugin (with confirmation) |
| `c` | Backups view | Cleanup old backups |
| Ctrl+C | Anywhere | Quit |

Built from scratch with raw termios control, alternate screen buffer, differential rendering, and signal handling. No external TUI libraries.

## Configuration

wayu keeps the files you edit in `~/.config/wayu/` and the data it manages in
`~/.local/share/wayu/`:

```
~/.config/wayu/
  # --- You edit these (version-control them) ---
  wayu.toml                 # [shell], [settings], [tools], [prompt]
  extra.{zsh,bash,fish}     # custom scripts (conda init, tool evals, etc.)
  tools.{zsh,bash,fish}     # one-off tool setup not expressible as [tools]
  alias-sources.conf        # external alias sources (shell-agnostic, read-only)
  hooks.conf                # pre/post operation hooks

~/.local/share/wayu/        # ${XDG_DATA_HOME:-~/.local/share}/wayu
  # --- wayu manages these (`wayu path|alias|const|plugin`, the TUI) ---
  entries.json              # PATH entries, aliases, constants
  plugins.json              # installed plugin metadata (JSON5)

  # --- wayu generates these (safe to delete; regenerated on change) ---
  init.{zsh,bash,fish}      # entry point — source THIS in your RC file
  core.{zsh,bash,fish}      # the generated init loaded by init.<shell> (one precomputed file)
  path_sync.{zsh,bash,fish} # PATH entry list re-read by the live PATH sync prompt hook
  plugins.{zsh,bash,fish}   # generated plugin loader
  plugins/                  # cloned plugin repos + runtime config
  turbo.{zsh,bash,fish}     # optional copy of core via `wayu export`
  completions/              # shell completion scripts
  backup/                   # timestamped backups (last 5 per file)

  # --- managed by commands (`wayu function`, `wayu script`) ---
  functions/                # shell functions, sourced at startup
  scripts/                  # script sources (NAME.<ext>)
  bin/                      # what runs: links / compiled binaries, first on PATH
```

Shell is detected automatically from `$SHELL`. Override with `--shell bash`, `--shell zsh`, or `--shell fish`.

`WAYU_CONFIG_DIR` moves the files you edit and `WAYU_DATA_DIR` the data
dir. Every `wayu.toml` table and key (`[tools]`, `[prompt]`, …),
`entries.json`, `hooks.conf`, `plugins.json` and the other files are
described in
[docs/config-reference.md](docs/config-reference.md).

### Functions and scripts

Both live in the data dir and are managed with commands; the directory is
the source of truth.

- **Functions** (`wayu function add|list|remove`) are shell functions in
  `functions/<name>.<ext>`, sourced by `core.<ext>`: they run inside your
  shell and can change its state (`cd`, variables).
- **Scripts** (`wayu script new|edit|list|remove|import|build`) are
  standalone executables in any language: swift, python, ruby, node, bun,
  bash, zsh, fish, perl, lua, sh. The source is `scripts/<name>.<ext>`;
  `bin/<name>` runs it (a link for interpreted languages, a `swiftc -O`
  binary for swift), and `bin/` is first among wayu's PATH entries in zsh,
  bash and fish. `script new` writes the interpreter's absolute path as the
  shebang, `wayu build` rebuilds scripts whose source changed, and
  `script import` adopts existing scripts while skipping binaries,
  symlinks and package-manager launchers (a file that declares its own
  build command needs `--allow-build`). Default language:
  `[scripts] default_lang` (else swift).

```bash
wayu script new today --lang python   # create, edit, link into bin/
today                                 # on PATH (open shells: next prompt)
wayu script import ~/bin/* --dry-run  # what would be imported / skipped
wayu script list --json
```

### PATH changes in open shells and scripts

`wayu path add/rm` (and hand edits of `entries.json`) reach already-open
zsh/bash shells at their next prompt: `core.<ext>` installs a prompt hook,
`_wayu_paths_sync` (zsh `precmd`, bash `PROMPT_COMMAND`, fish `fish_prompt`
event), that re-reads `path_sync.<ext>` only when the PATH entry list
changed.

**Scripts** never show a prompt, so the hook never runs. A script that sources
`init.<ext>` and changes PATH entries applies the change itself:

```bash
source "$HOME/.local/share/wayu/init.bash"   # or init.zsh
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
`wayu.toml` and `entries.json` is precomputed into straight-line code (zcompiled for zsh), and
the dynamic parts — `[tools]` lazy loaders, the native prompt, live PATH
sync — are function definitions and hooks, not work done at startup. zsh
runs `compinit` (with a cached, zcompiled `.zcompdump`) and sets up the
prompt in interactive shells only.

Measured with `tests/benchmark/startup.sh` (20 PATH entries, 60 aliases,
20 constants; macOS, hyperfine, empty zsh ≈ 3.5 ms, empty bash ≈ 2–3 ms):

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
3. Bumps `VERSION` in `src/main.odin`, regenerates `CHANGELOG.md`, renames
   the `## Unreleased` section of `docs/UPGRADING.md` to the version, commits
   `chore: release vX.Y.Z`, and tags it.
4. Builds the release binaries
   ([`release-build.yml`](.github/workflows/release-build.yml): macOS arm64
   and x86_64, Linux x86_64 and arm64; macOS x86_64 is cross-compiled on
   arm64, since Odin ships no macOS x86_64 toolchain), smoke-tests each on
   its own platform, attests them, publishes the GitHub release, and
   regenerates the Homebrew tap formula (`dvrd/homebrew-wayu`). CI runs the
   same build and smoke test on every push to `develop` and every PR.

The workflow never deletes or moves an existing tag or release: if the target
version's tag already exists elsewhere it fails and prints the manual fix.
CI uses the Odin release pinned in `.github/odin-release`.

Behavior changes users must know about are marked breaking (`fix(scope)!:` or a
`BREAKING CHANGE:` footer): they force a major bump and are listed under
"⚠ Upgrade notes" in the changelog. The release page's "⚠ Upgrade notes" are
the version's section of `docs/UPGRADING.md`.

So you do **not** bump the version by hand — land your Conventional Commits on
`develop` and merge `develop` into `main` to ship. `./build_it release [vX.Y.Z]` exists as a manual override (it also
auto-detects the version when the argument is omitted); the version argument is
only needed when `git-cliff` is unavailable.

## License

MIT
