# Changelog

All notable changes to wayu will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.1.0] - 2026-02-26

### Added

- **Homebrew tap** (`dvrd/wayu`) — `brew tap dvrd/wayu && brew install wayu` now works
- **Automated Homebrew releases** — pushing a git tag triggers build → GitHub Release → formula update
- **`release` target in build script** — `./build_it release v3.x.x` runs tests, tags, and pushes
- **Landing page** at `dvrd.github.io/wayu` — hero terminal animation, features, install tabs
- **`alias-sources.conf`** — surface read-only aliases from external tools (e.g. fabric patterns)
  - Format: `dir <path> <command_template>` with `{name}` placeholder
  - Missing directories silently skipped
- **Plugin registry expanded to 54 plugins** with category-based search (`wayu plugin search <keyword>`)
- **TUI plugin install from Registry tab** — browse and install plugins without leaving the TUI
- **TUI add modal** for PATH, alias, and constants with Tab navigation between fields
- **TUI delete confirmation modal** with focusable buttons (h/l navigation)
- **TUI notification system** with auto-dismiss
- **TUI inline fuzzy filter** on all list views
- **TUI detail overlay** views
- **Viewport scroll follows cursor** in all list views
- **`bld` build system** replaces Taskfile — pure Odin, zero external tools required
- **SVG favicon** for landing page

### Changed

- **BREAKING**: PATH format migrated from `add_to_path "path"` function calls to centralized `WAYU_PATHS=()` array (see v3.0.0 notes)
- Shell init templates load `plugins/config.zsh` for both zsh and bash
- `docs/` directory moved from `landing/` for GitHub Pages compatibility
- CI workflow skips tag pushes (handled exclusively by `release.yml`)
- CI `fail-fast: false` — matrix jobs run independently

### Fixed

- TUI: Tab and Enter keys now correctly reach plugins view handler
- TUI: Registry tab loads reliably and exits cleanly with no residue
- TUI: Main menu clips to terminal bounds and scrolls with cursor
- TUI: Scroll-indicator row reserved so last item is never hidden
- TUI: Color bleeding fixed with active-state ANSI tracking in screen flush
- TUI: Memory safety and UB fixes for release builds
- TUI: Responsive terminal size with 3-method fallback
- Plugin: Memory leak in check loop, swallowed loader error, duplicate bridge procs
- Shell injection hardening across all input paths
- 116 → 0 memory leaks (tracking allocator clean)
- Integration tests isolated to `/tmp`, never touch real config

### Internal

- Migrated from Taskfile to `bld` (Odin build system library)
- Consolidated `layout/theme` into `style.odin`
- Added `subprocess` module
- Migrated to new `core:os` API (dev-2026-02)
- Arena allocations throughout TUI for deterministic cleanup

---

## [3.0.0] - 2025-11-09

### ⚠️ Breaking Change — PATH format migration required

The PATH management system was rewritten to fix a critical bug where newly added
entries were ineffective: they were appended *after* all `export` statements had
already executed, so the shell never saw the new paths.

### Added

- **Centralized `WAYU_PATHS=()` array** — all PATH entries live in one place
- **Single for-loop export** — `for p in "${WAYU_PATHS[@]}"; do export PATH="$p:$PATH"; done`
- **Smart array insertion** — new entries inserted inside the array, before the closing `)`
- **Plugin system Phase 1–4** — install, enable/disable, priority, dependency management

### Changed

- PATH config format: `add_to_path "/usr/local/bin"` → entry inside `WAYU_PATHS=(...)`
- New entries are guaranteed to be exported in the correct order

### Migration

Users upgrading from v2.x need to re-initialize their PATH config:

```bash
wayu init          # regenerates path.{zsh,bash} with new format
# then re-add your paths:
wayu path add /usr/local/bin
wayu path add ~/.cargo/bin
# etc.
```

Or manually replace your `~/.config/wayu/path.{zsh,bash}`:

```bash
# Old format (v2.x)
add_to_path "/usr/local/bin"
add_to_path "$HOME/.cargo/bin"

# New format (v3.x)
WAYU_PATHS=(
  "/usr/local/bin"
  "$HOME/.cargo/bin"
)
for _wayu_p in "${WAYU_PATHS[@]}"; do
  [[ -d "$_wayu_p" ]] && export PATH="$_wayu_p:$PATH"
done
```

---

## [2.2.0] - 2025-10-16

### Added

- **CLI/TUI Isolation (PRP-13)**: Complete separation of interactive and non-interactive modes
  - CLI is now fully non-interactive — safe for scripts, pipes, and CI/CD
  - All interactive features consolidated in TUI mode (`wayu --tui`)
- **BSD sysexits.h exit codes** — industry-standard codes for scripting:
  - `0` Success, `1` General error, `64` Usage error, `65` Data format error
  - `66` Input not found, `73` Can't create output, `74` I/O error, `77` Permission denied, `78` Config error
- **`--yes` / `-y` flag** — skip confirmation prompts for automation
- **CI/CD workflows** — automated testing on Ubuntu and macOS, multi-platform release builds

### Changed

- **BREAKING**: CLI commands require explicit arguments (no more interactive fallback)
  - `wayu path rm` now requires a path argument; use `wayu --tui` for interactive selection
- **BREAKING**: Destructive operations require `--yes` flag
  - `wayu path clean --yes`, `wayu path dedup --yes`
- **BREAKING**: `wayu path list` outputs static table (not interactive selector)
- Backup handlers split: CLI fails immediately on backup error, TUI prompts user
- Exit codes categorized (previously all returned `1`)

### Migration

```bash
# Old (v2.1.x)
wayu path rm                    # opened fuzzy finder
wayu path clean                 # prompted [y/N]

# New (v2.2.0)
wayu path rm /specific/path     # explicit argument required
wayu path clean --yes           # --yes flag required
wayu --tui                      # use TUI for interactive mode
```

---

## [2.1.0] - 2025-10-15

### Added

- Full TUI mode with The Elm Architecture (TEA) pattern
  - 8 interactive views: main menu, PATH, alias, constants, completions, backups, plugins, settings
  - Vim-style navigation (`j`/`k`, arrow keys)
  - Alt screen buffer, signal handling, differential rendering
  - Zero external TUI dependencies — pure Odin termios implementation
- Component testing infrastructure with golden file visual regression
- Modern style system with centralized theme and ANSI color support
- UI components: tables with borders, progress indicators, loading spinners

### Changed

- Improved visual design with bordered panels and consistent color hierarchy

---

## [2.0.0] - 2025-10-14

### Added

- **Multi-shell support** — Bash and Zsh with automatic detection
- **`wayu migrate`** — convert configurations between shells
- **`wayu version`** — display version information
- **`wayu backup`** — comprehensive backup and restore system
- **`--dry-run` / `-n`** — preview any change before applying
- **`--shell`** — override automatic shell detection

### Changed

- **BREAKING**: Config files now use shell-specific extensions (`.bash`, `.zsh`)
- Configuration stored in `~/.config/wayu/` with shell-appropriate files

---

## [1.0.0] - Initial Release

### Added

- PATH management (`wayu path add/rm/list`)
- Alias management (`wayu alias add/rm/list`)
- Environment constants management (`wayu constants add/rm/list`)
- Backup system with automatic timestamped backups
- Configuration initialization (`wayu init`)

---

[3.1.0]: https://github.com/dvrd/wayu/releases/tag/v3.1.0
[3.0.0]: https://github.com/dvrd/wayu/releases/tag/v3.0.0
[2.2.0]: https://github.com/dvrd/wayu/releases/tag/v2.2.0
[2.1.0]: https://github.com/dvrd/wayu/releases/tag/v2.1.0
[2.0.0]: https://github.com/dvrd/wayu/releases/tag/v2.0.0
[1.0.0]: https://github.com/dvrd/wayu/releases/tag/v1.0.0
