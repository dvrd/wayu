# Handoff — wayu

## What is wayu

Shell configuration management CLI written in Odin. Manages PATH entries, aliases, environment constants, completions, and plugins by generating shell config files in `~/.config/wayu/` that users source via an init file. Dual-mode: non-interactive CLI (default) and full-screen TUI (`wayu --tui`). Supports Zsh, Bash, and Fish (all three now have working completions/templates/plugins paths). Current version: **v3.11.1** (published on GitHub Releases + Homebrew tap).

## Current State

### Build

```
./build_it              # Production build — SUCCESS (odin build src -out:bin/wayu -o:speed)
./build_it check        # Type-check only — SUCCESS
./build_it debug        # Debug build — SUCCESS
./build_it test         # Unit tests via build system — SUCCESS (554/554)
```

No warnings. Build produces `bin/wayu` binary.

### Tests

**Unit tests (Odin):** 554 tests, **ALL PASS**, 0 bad frees, 0 segfaults.
```
odin test tests/unit -file -o:speed -define:ODIN_TEST_THREADS=1 -ignore-unused-defineables
# Finished 554 tests in ~17s. All tests were successful.
```

**Integration tests (Ruby):** ALL PASS (135 total tests across 11 suites).
```
ruby tests/integration/test_path.rb         # 13 tests ✓
ruby tests/integration/test_alias.rb        # 17 tests ✓
ruby tests/integration/test_constants.rb    # 22 tests ✓
ruby tests/integration/test_backup.rb       #  8 tests ✓
ruby tests/integration/test_validation.rb   #  8 tests ✓
ruby tests/integration/test_errors.rb       #  8 tests ✓
ruby tests/integration/test_dry_run.rb      #  6 tests ✓
ruby tests/integration/test_init.rb         # 10 tests ✓
ruby tests/integration/test_completions.rb  # 10 tests ✓
ruby tests/integration/test_plugin.rb       # 25 tests ✓
ruby tests/integration/test_fish.rb         #  8 tests ✓  (added coverage for shell-aware completions + TOML-routed templates)
```

**CI (GitHub Actions):** ALL PASSING. Push-driven release pipeline is fully automated:
- `push` to `main` → `CI` workflow runs tests
- Same push → `Bump Version & Release` computes next semver via git-cliff, rewrites `VERSION`/CHANGELOG, tags, builds `wayu-linux-amd64` and `wayu-macos-arm64`, creates GitHub Release with artifacts + SHAs, pushes new `Formula/wayu.rb` to `dvrd/homebrew-wayu`.
- Verified end-to-end over 3 releases this session (v3.10.0 → v3.11.1).

### Performance

No benchmarks were run this session. Benchmark suite exists at `tests/benchmark/benchmark_suite.odin` — compares wayu vs Zinit, Sheldon, Antidote, OMZ on startup time, list ops, fuzzy search, memory.

## Project Structure

### Source Files (`src/`, 71 files, 37,172 lines)

| File | Lines | Purpose |
|------|------:|---------|
| `main.odin` | 2281 | Entry point, arg parsing, all command handlers, CLI output formatting |
| `config_toml.odin` | 2030 | TOML parser/serializer, profile merge, config file I/O, `cleanup_toml_config` helper |
| `interfaces.odin` | 304 | Shared type definitions (TomlConfig, LockEntry, ConfigEntry, etc.) |
| `config_entry.odin` | 1047 | Generic config entry CRUD with strategy pattern, file I/O, form handling |
| `config_specs.odin` | 448 | Per-type parse/format/validate specs for PATH, alias, constants |
| `config_toml_simple.odin` | 308 | Minimal TOML parser for doc parsing |
| `path.odin` | 996 | PATH management — array-based `WAYU_PATHS=()` format |
| `alias.odin` | 568 | Alias management |
| `constants.odin` | 697 | Environment constant management |
| `validation.odin` | 274 | Input validation (reserved words, dangerous chars, length) |
| `backup.odin` | 788 | Timestamped backups, restore, cleanup (keeps last 5) |
| `hooks.odin` | 414 | Pre/post operation hooks (subprocess execution) |
| `hot_reload.odin` | 558 | File watcher for live config reload (complete, needs CLI wiring) |
| `lock.odin` | 696 | Lock file system (SHA256 hashing, JSON format) |
| `output.odin` | 793 | JSON/table/text output formatting for all commands |
| `shell.odin` | 207 | Shell detection from `$SHELL`, file extension resolution |
| `preload.odin` | 729 | Embedded shell script templates for `init` command |
| `init_generator.odin` | 709 | Init script generation for zsh/bash/fish |
| `plugin.odin` | 705 | Plugin system core |
| `plugin_operations.odin` | 1124 | Plugin CRUD operations |
| `plugin_registry.odin` | 1165 | Plugin registry (download, install, update) |
| `plugin_config.odin` | 525 | Plugin configuration management |
| `plugin_help.odin` | 96 | Plugin help text |
| `fuzzy.odin` | 1069 | Fuzzy matching and search (falls back to static list) |
| `search.odin` | 441 | Cross-config search |
| `doctor.odin` | 1189 | Health check and diagnostics |
| `form.odin` | 547 | TUI form components |
| `style.odin` | 1050 | ANSI styling and color definitions |
| `theme.odin` | 1119 | Theme management |
| `theme_starship.odin` | 419 | Starship prompt integration |
| `prompt_generator.odin` | 404 | Shell prompt generation |
| `prompt_interactive.odin` | 414 | Interactive prompt builder |
| `completions.odin` | 373 | Completion management |
| `wayu_completions.odin` | 465 | Zsh completion script generation |
| `table.odin` | 372 | Table formatting |
| `spinner.odin` | 195 | Terminal spinner animation |
| `progress.odin` | 312 | Progress bar |
| `static_gen.odin` | 596 | Static asset generation |
| `subprocess.odin` | 227 | Subprocess execution |
| `env_snapshot.odin` | 199 | Environment variable snapshotting |
| `alias_sources.odin` | 244 | Alias source file management |
| `colors.odin` | 380 | Color constants |
| `special_chars.odin` | 156 | Unicode/special character constants |
| `errors.odin` | 216 | Error type definitions |
| `exit_codes.odin` | 59 | BSD sysexits.h constants + helpers |
| `debug.odin` | 10 | Debug logging (conditional on `-define:DEBUG=true`) |
| `types.odin` | 80 | Misc type definitions |
| `comp_testing.odin` | 121 | Component testing utilities |
| `adaptive_optimizer.odin` | 443 | Adaptive optimization system |
| `turbo_export.odin` | 458 | Turbo mode export optimization |
| `fff_integration.odin` | 609 | FFF (Fast File Finder) integration |
| `integration_direnv.odin` | 350 | direnv integration |
| `integration_mise.odin` | 541 | mise integration |
| `input.odin` | 421 | Input handling utilities |
| `shell_fish.odin` | 301 | Fish shell support (partial) |
| `templates.odin` | 277 | Configuration presets |
| `tui_bridge_impl.odin` | 895 | Connects TUI to config system via function pointers |
| `tui/main.odin` | 805 | TUI main loop, rendering, event handling |
| `tui/views.odin` | 1358 | All TUI view rendering (main menu, PATH, alias, etc.) |
| `tui/state.odin` | 547 | TUI state management (TEA architecture) |
| `tui/render.odin` | 247 | Low-level terminal rendering |
| `tui/layout.odin` | 289 | Layout calculations |
| `tui/components.odin` | 196 | Reusable TUI components |
| `tui/bridge.odin` | 249 | TUI ↔ config bridge interface |
| `tui/events.odin` | 129 | Event type definitions |
| `tui/input.odin` | 77 | Input processing |
| `tui/screen.odin` | 128 | Screen buffer management |
| `tui/terminal.odin` | 143 | Terminal size/detection |
| `tui/colors.odin` | 150 | TUI color scheme |
| `tui/rawmode.odin` | 81 | Raw terminal mode |
| `tui/views_handlers.odin` | 359 | View-specific event handlers |
| `tui/layout.odin` | 289 | Layout engine |
| `tui/terminal.odin` | 143 | Terminal detection |

### Test Files

| Path | Lines | Purpose |
|------|------:|---------|
| `tests/unit/test_*.odin` | ~13,000 total | Unit tests (554 tests) |
| `tests/integration/test_*.rb` | ~3,500 total | Integration tests (Ruby) |
| `tests/benchmark/benchmark_suite.odin` | 464 | Performance benchmarks |
| `tests/golden/` | — | Golden files for visual regression |
| `tests/ui/` | — | Visual/alignment component tests |
| `tests/tui/` | — | TUI responsive tests (Python/pyte) |

## Architecture

```
CLI Flow:
  main.odin → parse_command() → Command/Action/Args
    → path.odin / alias.odin / constants.odin / ... (command handlers)
      → config_entry.odin (generic CRUD via ConfigEntrySpec strategy)
        → config_specs.odin (per-type parse/format/validate)
      → config_toml.odin (TOML config: parse, serialize, merge profiles)
      → backup.odin (auto-backup before writes)
      → validation.odin (input validation)

TUI Flow:
  main.odin (--tui flag) → tui/main.odin (TEA loop)
    → tui/state.odin (centralized state) → events → update → render
    → tui/views.odin (view rendering, data loading)
    → tui_bridge_impl.odin (function pointers to config system)

Data Flow:
  Config files (~/.config/wayu/*.zsh|.bash)
    → read_file → parse_line → ConfigEntry{name, value, line}
    → modify in memory → write back
  
  TOML config (~/.config/wayu/wayu.toml)
    → toml_parse → TomlConfig{path, aliases, constants, plugins, profiles, settings}
    → toml_to_string → serialize back

Memory Strategy:
  - strings.clone() for all parsed data (avoids dangling refs to file buffers)
  - Arena allocator in toml_parse for temporary parse data (freed after doc_to_config)
  - defer-based cleanup throughout
  - cleanup_toml_config() helper for complete TomlConfig deallocation
  - [dynamic] arrays used for building, then extracted to owned []T slices
```

### Key Types

```
ConfigEntry :: struct {type, name, value, line}     — single config line
TomlConfig :: struct {version, shell, path, aliases, constants, plugins, profiles, settings}
LockEntry :: struct {type, name, value, hash, source, added_at, modified_at, metadata}
ConfigEntrySpec :: struct {parse_line, format_line, validate, ...}  — strategy pattern
```

## Key Design Decisions

1. **Strategy Pattern for config types** — `ConfigEntrySpec` in `config_specs.odin` provides per-type parse/format/validate without if/else chains
2. **Dual-mode CLI/TUI** — Same codebase, TUI via bridge pattern (function pointers) to avoid circular deps
3. **Plain shell scripts as config** — Not a database; files are parsed line-by-line with string prefix matching
4. **TOML as declarative overlay** — `wayu.toml` for advanced config, shell files remain primary
5. **Memory safety via deep-clone in merge** — `toml_merge_profiles` creates independent copies of all strings/slices to avoid double-free between base and merged configs
6. **cleanup_toml_config helper** — Centralized deallocation prevents leaks from `settings.autosuggestions_accept_keys` and other easily-forgotten fields

## Known Issues

| Issue | Severity | Where | Workaround |
|-------|----------|-------|------------|
| Legacy `aliases.{ext}` / `constants.{ext}` / `path.{ext}` are empty until `wayu build eval` runs | Medium | `src/init_generator.odin` seeds them at init but never syncs from `wayu.toml`; `init.{ext}` sources them | Run `wayu build eval` after any config change, source `init-core.{ext}` |
| TOML migration incomplete | Low | `src/config_toml.odin:~1615` | — |
| `wayu build profile` not implemented | Low | Profiling stub | — |
| Fuzzy real-time filtering falls back | Low | `src/fuzzy.odin:~1017` | Static list works |
| Memory leaks in tests | Low | Various toml tests leak small strings from `get_string_array`, `get_string`, `doc_to_config` | Non-blocking, tracked by test framework |

## Incomplete Work

### CI Deployment Fixes (SHIPPED)

**Status:** Landed across commits `e903d8e`, `4f146ab`, and `7bd1ff3` on `main`. Verified CI green + release artifacts on GitHub + homebrew tap updated.

**What was done (11 files modified, +347/-583 lines):**

1. **`.github/workflows/bump.yml`** — Fixed duplicate `permissions:` key that prevented the workflow from ever running. Merged into single `permissions: contents: write, actions: read`. This fixes auto-release and homebrew tap updates.

2. **`tests/unit/test_tui_state.odin` + `tests/unit/test_tui_main.odin`** — Updated menu item count from 7→8 (8th item "Hooks" was added). Fixed wrap-around index to match.

3. **`src/config_toml.odin`** — Major memory safety overhaul:
   - `get_string_array()`: Changed from `[dynamic]string` + slice to `make([]string, n)` direct allocation
   - `doc_to_config()`: Properly extracts owned slices from dynamic arrays via `make+copy+delete` pattern
   - `toml_merge_profiles()`: Deep clones ALL fields (strings, slices, profiles, settings) to prevent double-free between base and merged configs
   - Added `cleanup_toml_config()` helper that properly frees every field including `autosuggestions_accept_keys`
   - Fixed `autosuggestions_accept_keys` default to use `make([]string, 2)` instead of literal syntax that caused bad frees

4. **`src/lock.odin`** — Fixed `lock_generate_hash()`: replaced `fmt.tprintf` with `fmt.aprintf` (proper allocator tracking), proper hex encode cleanup with `strings.clone + delete(encoded)`

5. **`src/config_entry.odin`** — `cleanup_entry()` no longer deletes individual string fields (was causing bad frees on non-heap strings). `read_config_entries()` properly extracts owned slice from dynamic.

6. **`tests/unit/test_toml.odin`** — All 17 defer blocks replaced with `defer wayu.cleanup_toml_config(&config)` / `&merged`

7. **`tests/unit/test_lock.odin`** — Test entries now use `strings.clone()` for all string fields to ensure heap allocation

8. **`tests/unit/test_output.odin`** — Replaced `cleanup_entries()` calls with simple `delete(entries)` since entries contain string literals

9. **`tests/unit/test_fuzzy.odin`** — Fixed defer order: cleanup_entry now runs before delete(entries) in single defer block

10. **`tests/unit/test_theme.odin`** — Removed `defer delete(config)` on static string literal from `generate_starship_toml()`

**What remained (now complete):**
- ✅ Commits pushed to `main` on `dvrd/wayu`
- ✅ CI green across all subsequent pushes
- ✅ Bump workflow re-run via `workflow_dispatch` with `recreate_tag=v3.10.0` (the original tag pointed to an orphan commit not reachable from `main`, which broke `git describe` on the runner and caused a same-version collision). Orphan draft release also deleted.
- ✅ Homebrew tap automatically updated to v3.11.1 (current latest).

### Hot Reload (SHIPPED) — commit `f38966f`

`src/hot_reload.odin` was already feature-complete and wired through the
`RELOAD` command in the enum + `parse_command` + dispatch (aliases: `reload`,
`watch`, `hot-reload`). Two portability bugs made it unusable outside Linux:

1. `is_watcher_running()` probed `/proc/<pid>`, which doesn't exist on macOS
   / BSD — status always returned `not running` even when a watcher was
   clearly alive. Replaced with the portable `kill(pid, 0)` + `errno` check
   (`ESRCH` → stale PID file removed, `EPERM` → still running).
2. `remove_watcher_pid()` only worked when `g_watcher.pid_file` was set,
   which happens inside `hot_reload_init`. `stop` and `status` run in a
   different process than `start`, so the global was empty and the PID file
   was never cleaned up. Added a fallback deriving the path from
   `WAYU_CONFIG + WATCHER_PID_FILE`.

Also surfaced the command in `wayu --help` (was missing from the commands
list and examples). End-to-end verified on macOS arm64: `start` in bg,
`status` reports running, `touch wayu.toml` triggers debounced regen, `stop`
sends SIGTERM, PID file cleaned up.

### Fish Shell Completeness — commits `dd5c890`, `8c53d1e`

The handoff previously flagged "Fish shell declared but completion/plugin/
template paths not wired". Audit:

- **Plugins**: already complete. `plugin_registry.odin` ships 7+ fish
  plugins (z.fish, pure, tide, bass, nvm.fish, fzf.fish, autopair.fish,
  done.fish). `plugin_config.odin::generate_plugins_file` uses
  `DETECTED_SHELL`, `get_plugin_files_to_source` scans `conf.d/` and
  `functions/` for fish, `apply_load_template` emits fish-native
  `fish_add_path` / `set -gx fish_function_path` / `eval (...)` forms.
- **Completions**: `add_completion` hardcoded `_name` prefix (zsh only).
  Refactored with `completion_filename_for_shell(name, shell)` that maps
  zsh → `_name`, bash → `name.bash-completion`, fish → `name.fish`, and
  respects pre-encoded inputs (`foo.fish` stays as-is). `remove_completion`
  scans all conventions via `find_existing_completion`. `list_completions`
  filter broadened via `is_completion_file`. Help text + file header
  updated.
- **Templates**: `apply_developer_template` etc. called `add_config_entry`
  (legacy path writer) directly, which produced bash-syntax
  `constants.fish` / `aliases.fish` and orphan lines in `path.fish` while
  leaving `wayu.toml` empty. Refactored with `template_add_paths` /
  `template_add_aliases` / `template_add_constants` helpers that route
  through `toml_path_add` / `toml_alias_add` / `toml_constant_add`.
  `wayu.toml` is now the single source of truth; `wayu build eval`
  regenerates fish-native `init-core.fish` (`alias g 'git'`,
  `set -gx EDITOR ...`, `set -gx PATH`).
- **init generator bug**: `read_wayu_toml_env` only matched `[env]` but
  `wayu constants add` writes to `[constants]`. Widened to accept both
  headers so manually-added constants reach `init-core.{zsh,bash,fish}`.

`tests/integration/test_fish.rb` grew from 6 to 8 tests covering the new
shell-aware completion naming and the TOML-routed template flow.

## What To Work On Next

1. **Regenerate legacy shell files from `wayu.toml` on `wayu init` / `wayu
   build eval`**. After the "wayu.toml is source of truth" refactor, the
   seeded `aliases.{ext}`, `constants.{ext}`, and `path.{ext}` files stay
   empty even though `init.{ext}` still sources them. Users only see their
   config if they run `wayu build eval` (produces `init-core.{ext}`) and
   add `source init-core.{ext}` themselves. Either make `wayu init` emit a
   final `source init-core.{ext}` line in `init.{ext}` (only if it exists),
   or rebuild the legacy shell files from `wayu.toml` on every mutation
   hook. This affects all three shells — not fish-specific. **Difficulty:
   medium.**

2. **Wire `wayu build profile`** — currently a stub. Emit timing data for
   each phase of init (constants → path → functions → completions →
   plugins → aliases → tools → extras). Useful for users optimizing
   startup. **Difficulty: medium.**

3. **TOML migration incomplete** — `src/config_toml.odin:~1615` has a stub
   for migrating existing shell configs into `wayu.toml`. With the refactor
   landed, finishing this migrator lets users upgrade smoothly from v3.9
   and earlier. **Difficulty: medium.**

4. **Real-time fuzzy filtering** — `src/fuzzy.odin:~1017` falls back to a
   static list instead of re-filtering on every keystroke. **Difficulty:
   low.**

5. **Fix remaining test memory leaks** — Several toml tests still report
   small leaks (2-16 bytes each) from `get_string_array`, `get_string`,
   `doc_to_config`. Non-blocking but flagged by the tracking allocator.
   **Difficulty: low.**

6. **Bash completions integration test** — `test_completions.rb` only
   covers zsh naming. Now that `add_completion` is shell-aware, add a
   small bash suite asserting `*.bash-completion` output. **Difficulty:
   low.**

## Commands Reference

All commands verified this session:

```bash
# Build
./build_it              # Production build (SUCCESS)
./build_it check        # Type-check only (SUCCESS)
./build_it debug        # Debug build (SUCCESS)
./build_it test         # Unit tests (554/554 PASS)

# Run specific tests
odin test tests/unit -file -o:speed -define:ODIN_TEST_NAMES=test_wayu.test_toml_parse_basic -ignore-unused-defineables

# Integration tests (Ruby)
ruby tests/integration/test_path.rb         # 13 PASS
ruby tests/integration/test_alias.rb        # 17 PASS
ruby tests/integration/test_constants.rb    # 22 PASS
ruby tests/integration/test_backup.rb       #  8 PASS
ruby tests/integration/test_validation.rb   #  8 PASS
ruby tests/integration/test_errors.rb       #  8 PASS
ruby tests/integration/test_dry_run.rb      #  6 PASS
ruby tests/integration/test_init.rb         # 10 PASS
ruby tests/integration/test_completions.rb  # 10 PASS
ruby tests/integration/test_plugin.rb       # 25 PASS

# GitHub CLI (auth: dvrd account)
gh run list --workflow CI --limit 5
gh run list --workflow 248972478 --limit 5    # bump workflow
gh release list --limit 5
gh repo view --json nameWithOwner

# Install
./build_it install                         # installs to /usr/local/bin
```
