# Handoff — wayu

## What is wayu

wayu is a shell configuration management CLI written in Odin. It manages PATH entries, aliases, environment constants, and shell plugins by generating shell config files in `~/.config/wayu/` that users source via an init file. The core design is dual-mode: fully non-interactive CLI (default) and a full-screen TUI (`wayu` with no args). Configuration is stored in `wayu.toml` (TOML) which gets compiled to optimized shell scripts at init time.

Notable: It has a hand-rolled TOML parser (no external dependency), a hand-rolled TUI with The Elm Architecture (no ncurses), and generates zcompiled zsh bytecode for fast startup.

---

## Current State

### Build

**Command:** `./build_it`

**Output:**
```
[INFO] Building wayu (optimized)...
[INFO] directory 'bin' already exists
[INFO] CMD: odin build src -out:bin/wayu -o:speed
[INFO] Built bin/wayu
```
**Status:** ✅ Clean — zero warnings, zero errors.

**Type-check only:** `./build_it check` → ✅ passes (odin check src).

### Tests

| Suite | Command | Result | Count |
|-------|---------|--------|-------|
| Unit tests | `./build_it test` | ✅ Pass | 505/505 |
| Integration tests | `ruby tests/integration/run_all.rb` | ✅ Pass | 15/15 suites |
| UI tests | `odin test tests/ui -file` | ❌ Broken | Package name mismatch across files |
| Benchmark suite | `odin build tests/benchmark/benchmark_suite.odin -file` | ❌ Broken | Uses non-existent `os.system`, `os.OS`, `os.remove_directory` |

**Unit test files:** 10 files in `tests/unit/` (down from 13 — 3 removed in this session).

**Integration test breakdown:** Constants(22), Init(10), Completions(10), Migrate(7), Fish(6), Path(25), Alias(21), Completions_multishell(5), Backup(9), Errors(7), Dry_run(5), Helper(1), Build_profile(2), Validation(8), Plugin(25).

**UI test issue:** `tests/ui/test_form_container.odin` declares `package test_form_container`, `test_render_box.odin` declares `package test_ui`, but `odin test` expects all files in a directory to share the same package name. These tests have been broken for an unknown duration.

**Benchmark issue:** `tests/benchmark/benchmark_suite.odin` references APIs that don't exist in the current Odin core library (`os.system`, `os.OS`, `os.remove_directory`). It likely worked on an older Odin version. The benchmark has a `main :: proc()` entry point and would need porting to current Odin APIs (use `os2.execute` or `libc.system`) to compile.

### Performance

No reproducible benchmark numbers available this session — the benchmark suite doesn't compile. The `profile.odin` module has a `profile_startup_performance()` proc that spawns the user's shell as a subprocess and measures wall-clock time, but it requires `wayu init` to have been run first. It was not exercised in this session.

---

## Project Structure

| File | Lines | Purpose |
|------|-------|---------|
| `src/main.odin` | 722 | Entry point. Parses args, dispatches to command handlers. Contains `AppContext` global and `tui_launch` helper. |
| `src/cli_parser.odin` | 419 | CLI argument parsing: global flags, command + action resolution, doctor/component-test flags. Returns `ParsedArgs`. |
| `src/path.odin` | 990 | PATH entry management: add, remove, list, clean, dedup. All ops write to `wayu.toml [paths]`. |
| `src/alias.odin` | 522 | Alias management: add, remove, list. TOML-native. |
| `src/constants.odin` | 591 | Environment constant management: add, remove, list. TOML-native. |
| `src/config_entry.odin` | 1151 | Generic config entry abstraction (Strategy Pattern). Provides `handle_toml_entry_command` used by path/alias/constants. |
| `src/config_specs.odin` | 474 | `ConfigEntrySpec` instances for PATH, ALIAS, CONSTANTS. Defines validators, formatters, parsers as function pointers. |
| `src/toml.odin` | 1844 | Hand-rolled TOML parser, serializer, and `wayu toml` CLI handlers. Single source of truth for all TOML operations. |
| `src/backup.odin` | 781 | Timestamped backups, restore, cleanup (keeps last 5). Auto-creates backup before any write. |
| `src/plugin.odin` | 775 | Plugin command handler: add, remove, list, check, update, enable, disable, priority. |
| `src/plugin_storage.odin` | 2302 | Plugin JSON config read/write, GitHub URL handling, dependency resolution, conflict detection. Massive file. |
| `src/plugin_loader.odin` | 525 | Generates `plugins.zsh` / `plugins.bash` runtime loader and plugin config file. |
| `src/init_generator.odin` | 1086 | Generates `init-core.zsh`, `init-lazy.zsh`, `init-login.zsh`, `init-helpers.zsh`. Compiles to zsh bytecode via `zcompile`. |
| `src/preload.odin` | 628 | Shell script templates for `wayu init` (path, aliases, constants, init, tools, extra). |
| `src/migrate.odin` | 510 | `wayu migrate`: converts legacy shell configs → wayu.toml. Also cross-shell migration. |
| `src/migrate_schema.odin` | 438 | `migrate_toml_schema`: upgrades obsolete `[[paths]]`/`[[aliases]]` array-of-tables schema to inline tables. |
| `src/doctor.odin` | 776 | Health check orchestrator. Uses arena allocator (64KB) for all check allocations. |
| `src/doctor_checks.odin` | 493 | Individual health check procs registered in a `CHECKS` function-pointer array. |
| `src/hooks.odin` | 485 | Pre/post action hooks. `execute_hook` replaces placeholders in shell command strings. Most hooks are stubs. |
| `src/hot_reload.odin` | 583 | File watcher with debounced auto-regeneration (`wayu reload`). Spawns a thread, writes PID file. |
| `src/static_gen.odin` | 596 | Static shell script generation from TOML (used by hot reload). |
| `src/turbo_export.odin` | 458 | `wayu export`: generates unified pre-computed `turbo.zsh` for fast startup. |
| `src/build_output.odin` | 53 | `wayu build` helpers. Now minimal after dead code removal. |
| `src/search.odin` | 441 | `wayu search` / `wayu find`: fuzzy search across all configs. |
| `src/fff_integration.odin` | 604 | Fuzzy matching engine (acronym matching, scoring). Used by search, path, alias, constants for interactive selection. |
| `src/fuzzy.odin` | 1116 | Full-screen fuzzy finder UI with raw terminal mode. Mostly unused — only `enable_raw_mode` and `is_tty` are widely called. |
| `src/templates.odin` | 250 | `wayu template`: configuration presets (developer, minimal, datascience). Entry point alive, apply procs mostly dead. |
| `src/config_command.odin` | 442 | `wayu config`: edit extra.<shell>, edit wayu.toml, scan .zshrc for scripts. |
| `src/wayu_completions.odin` | 867 | Zsh self-completion script generation + completions command handler. Merged from removed `completions.odin`. |
| `src/completions.odin` | — | **REMOVED** — superseded by `wayu_completions.odin`. |
| `src/validation.odin` | 274 | Input validation: reserved words, dangerous chars, length limits. |
| `src/shell.odin` | 207 | Shell type detection from `$SHELL`, extension mapping (`.zsh`/`.bash`). |
| `src/shell_fish.odin` | 301 | Fish shell init generation. Only `shell_fish_generate_init` and `command_exists` are used. |
| `src/colors.odin` | 380 | ANSI color profiles (TrueColor, 256, ASCII). Auto-detects from `COLORTERM` / `TERM`. |
| `src/style.odin` | 1134 | TUI styling DSL: margins, padding, borders, foreground/background. Mostly unused — only a few procs called by `form.odin`. |
| `src/table.odin` | 372 | Table rendering for CLI output. Mostly unused. |
| `src/output.odin` | 44 | **DRASTICALLY SHRUNK** — now only `json_escape` and `AliasEntry` struct. |
| `src/errors.odin` | 203 | Error handling with context and suggestions. `safe_read_file`, `safe_write_file`. |
| `src/exit_codes.odin` | 27 | **DRASTICALLY SHRUNK** — BSD sysexits constants only. |
| `src/interfaces.odin` | 162 | **DRASTICALLY SHRUNK** — shared types: `LockFile`, `TomlConfig`, `TomlAlias`, etc. Removed dead theme/integration/benchmark types. |
| `src/lock.odin` | 734 | Lock file read/write with SHA256 hashes. Only `lock_read` is used externally. |
| `src/env_snapshot.odin` | 199 | Cross-reference TOML data with actual shell environment. Used by TUI data loading. |
| `src/alias_sources.odin` | 244 | Reads `alias-sources.conf` for external alias sources. Alive but only via `print_external_alias_sources` function pointer in `ALIAS_SPEC`. |
| `src/profile.odin` | 318 | `wayu build profile`: measures shell startup time. Spawns shell subprocess, times it. |
| `src/prompt_generator.odin` | 661 | Native zsh prompt generation. Only `dsl_to_zsh_format`, `parse_full_prompt_config`, `generate_full_prompt` used by init_generator. |
| `src/prompt_interactive.odin` | 429 | Interactive prompt features (vi-mode, transient, async). Only `generate_interactive_prompt` and `parse_interactive_config` used. |
| `src/form.odin` | 547 | Multi-field form component for TUI. Used by TUI add-overlay. |
| `src/input.odin` | 421 | Single-line text input component with cursor and editing. Used by form. |
| `src/spinner.odin` | 195 | Terminal spinner animations (dots, arc, line). Used by init and template commands. |
| `src/special_chars.odin` | 156 | Visual width calculations for emojis and box-drawing chars. Used by form/input. |
| `src/subprocess.odin` | 227 | Cross-platform subprocess execution. Used by doctor, profile, hooks. |
| `src/schema_check.odin` | 90 | Detects obsolete `wayu.toml` schema and aborts with migration hint. |
| `src/entry.odin` | 91 | `Entry` sum type (PATH/ALIAS/CONSTANT variants) and unified add/remove. |
| `src/path_keys.odin` | 171 | Derives TOML keys from filesystem paths (e.g. `/usr/local/bin` → `local_bin`). |
| `src/debug.odin` | 10 | No-op debug logging (activates only with `-define:DEBUG=true`). |
| `src/comp_testing.odin` | 120 | Component testing framework for CLI golden files (`wayu -c=... --snapshot --test`). |
| `src/tui_main.odin` | 823 | TUI entry point. Main event loop: handle events → update state → render. Elm Architecture. |
| `src/tui_state.odin` | 547 | TUI state machine: views, notifications, source filter, add form, detail pane. |
| `src/tui_data.odin` | 646 | TUI data loading helpers (`tui_load_*`) and mutation helpers (`tui_enable_plugin`, etc.). Bridge between TUI and config system. |
| `src/tui_render.odin` | 247 | TUI render orchestrator. Delegates to view-specific renderers. |
| `src/tui_layout.odin` | 289 | Layout constants and helpers (header height, footer Y, content area). |
| `src/tui_terminal.odin` | 143 | Terminal raw mode, size detection, alt-screen enter/exit. |
| `src/tui_screen.odin` | 133 | Screen buffer: cell grid, diff-based flushing. |
| `src/tui_components.odin` | 196 | Component test rendering (headless) for golden files. |
| `src/tui_events.odin` | 129 | Event type definitions (resize, key, quit). |
| `src/tui_input.odin` | 77 | Low-level input reading with `select()` timeout and escape sequence parsing. |
| `src/tui_colors.odin` | 135 | TrueColor palette (hot-pink + teal) for TUI. |
| `src/tui_views_cache.odin` | 107 | Per-view data cache with lazy loading. |
| `src/tui_views_handlers.odin` | 271 | View event handlers (keyboard shortcuts, navigation). |
| `src/tui_views_overlays.odin` | 319 | Add-form and detail-pane overlay rendering. |
| `src/tui_views_shared.odin` | 533 | Shared list view rendering (headers, items, scroll indicators, empty states). |
| `src/tui_view_hooks.odin` | 37 | Hooks view renderer (placeholder). |
| `src/tui_view_plugins.odin` | 250 | Plugins view renderer. |
| `src/tui_view_settings.odin` | 49 | Settings view renderer (placeholder). |

**Total: 73 files, 33,570 lines.**

---

## Architecture

### Data Flow (CLI Path)

```
                    ┌─────────────┐
                    │   main()    │
                    └──────┬──────┘
                           │ os.args
                    ┌──────▼──────┐
                    │ parse_args()│  ← cli_parser.odin
                    └──────┬──────┘
                           │ ParsedArgs {command, action, args}
         ┌─────────────────┼─────────────────┐
         │                 │                 │
   ┌─────▼─────┐    ┌────▼────┐      ┌─────▼──────┐
   │ handle_*_ │    │ tui_run()│      │ component  │
   │ command() │    │          │      │ testing    │
   └─────┬─────┘    └──────────┘      └────────────┘
         │
   ┌─────▼────────────────────────────────────┐
   │  wayu.toml read → mutate → write back    │
   │  (hand-rolled TOML parser in toml.odin)  │
   └─────┬────────────────────────────────────┘
         │
   ┌─────▼────────────────────────────────────┐
   │  regenerate_init_core_silently()       │
   │  (init_generator.odin)                   │
   └─────┬────────────────────────────────────┘
         │
   ┌─────▼────────────────────────────────────┐
   │  Generates:                              │
   │    init-core.zsh  ← essential (PATH, aliases, constants)
   │    init-lazy.zsh  ← deferred plugins    │
   │    init-login.zsh ← login-only stuff    │
   │    init-helpers.zsh ← utility functions │
   │  Then zcompile to bytecode (.zwc)        │
   └──────────────────────────────────────────┘
```

### Data Flow (TUI Path)

```
                    ┌─────────────┐
                    │   tui_run() │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
        ┌─────▼─────┐ ┌───▼────┐  ┌────▼─────┐
        │tui_init() │ │screen  │  │state init │
        └───────────┘ │create()│  └──────────┘
                      └────────┘
              │            │            │
              └────────────┼────────────┘
                           │
                    ┌──────▼──────┐
                    │  Event Loop │  ← The Elm Architecture
                    │  (tui_main) │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
        ┌─────▼─────┐ ┌───▼────┐  ┌────▼─────┐
        │tui_input  │ │resize  │  │tui_ensure_ │
        │ (keys)    │ │handler │  │data_loaded│
        └───────────┘ └────────┘  └───────────┘
                           │
                    ┌──────▼──────┐
                    │ tui_render()│
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
        ┌─────▼─────┐ ┌───▼────┐  ┌────▼─────┐
        │view_shared│ │overlays│  │screen    │
        │(list)     │ │(forms) │  │flush()   │
        └───────────┘ └────────┘  └──────────┘
```

### Key Types

| Type | File | Purpose |
|------|------|---------|
| `AppContext` | main.odin | Global mutable program state (home, wayu_config, shell, dry_run, etc.) |
| `Command` / `Action` | main.odin | CLI command and action enums |
| `ParsedArgs` | cli_parser.odin | Result of CLI argument parsing |
| `ConfigEntry` | config_entry.odin | Generic config entry (type, name, value, line) |
| `ConfigEntrySpec` | config_entry.odin | Strategy pattern: validator, formatter, parser, TOML ops as function pointers |
| `TomlConfig` | interfaces.odin | Parsed wayu.toml structure |
| `TomlDoc` / `TomlValue` | toml.odin | Hand-rolled TOML AST types |
| `TUIState` | tui_state.odin | TUI state machine: current view, selection, notifications, form |
| `TUIView` | tui_state.odin | Enum of all TUI views |
| `ScreenBuffer` | tui_screen.odin | Cell grid for terminal output |
| `CheckResult` | doctor.odin | Health check result with status and message |
| `PluginConfig` | plugin_storage.odin | JSON plugin metadata (name, source, enabled, priority) |

### Memory Strategy

- **Heap**: Default allocator. Used for long-lived strings (g_ctx fields, config file contents).
- **Temp arena**: 2MB arena in `main()`. Used for transient allocations (string building, intermediate operations). Automatically freed on scope exit via `free_all(context.temp_allocator)`.
- **Doctor arena**: 64KB static buffer (`doctor_arena_buffer`). All doctor check allocations use this arena. Cleared between runs.
- **TUI**: Screen buffer uses a fixed-size cell grid allocated once at startup. View data is cached and cleared on mutations.
- **ConfigEntry**: Caller owns all strings. Most handlers use `defer delete` for heap strings.

---

## Key Design Decisions

### 1. Hand-rolled TOML parser instead of a library
**What:** `toml.odin` (1844 lines) implements a complete TOML parser, serializer, and section replacer.  
**Why:** Odin has no mature TOML library. A custom parser lets us do in-place section replacement (e.g. rewrite only `[paths]` without touching other sections).  
**Alternative:** Use JSON or a simpler format. Rejected because users want human-editable config.

### 2. Elm Architecture for TUI
**What:** Centralized `TUIState` → events → update → render loop. No mutable view state.  
**Why:** Predictable, testable, avoids the callback spaghetti of traditional TUI libraries.  
**Alternative:** ncurses or bubbletea-like framework. Rejected to avoid C dependencies.

### 3. Bridge pattern between TUI and config system
**What:** `tui_data.odin` provides `tui_load_*` and `tui_*` mutation procs that wrap the CLI config system.  
**Why:** Avoids circular imports between `tui/` package and main config code. The TUI calls into `tui_data` which calls into path/alias/constants/TOML modules.  
**Note:** The old `tui_bridge_impl.odin` file mentioned in AGENTS.md no longer exists; its logic was absorbed into `tui_data.odin`.

### 4. TOML-first with legacy shell-file fallback
**What:** All writes go to `wayu.toml`. Shell scripts (`path.zsh`, `aliases.zsh`, etc.) are only generated during `wayu init` for backward compatibility. The init generator reads TOML at shell startup.  
**Why:** Single source of truth. Users can version-control `wayu.toml`.  
**Tradeoff:** Shell startup now parses TOML (fast enough with the hand-rolled parser, but not zero-cost).

### 5. zcompile for zsh bytecode
**What:** After generating `init-core.zsh`, wayu runs `zsh -fc 'zcompile init-core.zsh'` to produce `init-core.zsh.zwc`.  
**Why:** ~2-3x faster shell startup on zsh.  
**Limitation:** Only works on zsh. Bash has no equivalent.

### 6. Arena allocator for doctor
**What:** All doctor check allocations use a 64KB arena.  
**Why:** Simplifies memory management in a complex diagnostic pass. No need to track individual allocs.  
**Tradeoff:** Cannot return results outside the doctor scope. All results are printed before the arena is reset.

### 7. Function-pointer arrays for checks and specs
**What:** `CHECKS` array in `doctor_checks.odin` maps check names to `CheckFn` procs. `ConfigEntrySpec` in `config_specs.odin` maps entry types to validator/formatter/parser/TOML procs.  
**Why:** Extensible without modifying dispatch logic. Adding a new check = write proc + append to array.  
**Tradeoff:** Static analysis can't detect dead function pointers. Many hook procs in `hooks.odin` are assigned to specs but are no-ops.

---

## Known Issues

| Issue | Severity | Where | Workaround |
|-------|----------|-------|------------|
| UI tests broken (package name mismatch) | Medium | `tests/ui/` | Don't run `odin test tests/ui`. Tests were likely broken by a refactor that renamed packages but didn't update all files. |
| Benchmark suite doesn't compile | Medium | `tests/benchmark/benchmark_suite.odin` | Don't use. References deprecated Odin APIs (`os.system`, `os.OS`, `os.remove_directory`). Needs porting to `libc.system` and `os2` equivalents. |
| `attempt_auto_fixes` in doctor is dead code | Low | `src/doctor.odin` | The `--fix` flag parses but `attempt_auto_fixes` is never called from `handle_doctor_command`. It exists but is unreachable. |
| `form` module has dead procs | Low | `src/form.odin` | `form_next_field`, `form_prev_field`, `form_validate`, `form_render_full`, `form_get_field_value` are defined but never called from any file. Only `new_form`, `form_run`, `form_destroy` are used. |
| `style.odin` is mostly unused | Low | `src/style.odin` | Only `render_title_box`, `render_box`, `render_form_container` are called (by `form.odin`). The remaining ~1100 lines of styling DSL (margins, padding, borders, colors, etc.) are dead. |
| `fuzzy.odin` full-screen finder unused | Low | `src/fuzzy.odin` | Only `enable_raw_mode` and `is_tty` are widely used. The full `fuzzy_find` / `fuzzy_render` / `fuzzy_handle_key` interactive finder is never called. `fff_integration.odin` provides the actual fuzzy matching used by search/path/alias/constants. |
| `table.odin` mostly unused | Low | `src/table.odin` | Only `new_table`, `table_add_row`, `table_add_header`, `table_render` are called (by `alias_sources.odin`, `alias.odin`, `config_entry.odin`, `constants.odin`, `plugin_storage.odin`). Many advanced features (JSON export, compact mode, bare mode, column clamping) are dead. |
| `lock.odin` write/update logic unused | Low | `src/lock.odin` | Only `lock_read` is called (by `hot_reload.odin` and `static_gen.odin`). All lock write, add, remove, verify, update procs are dead. |
| `hot_reload.odin` many internal procs unused | Low | `src/hot_reload.odin` | `handle_watch_command` is the only alive entry point. `start_watcher`, `stop_watcher`, `watcher_thread_proc`, `check_file_changes`, `get_default_watch_paths`, `default_file_change_callback` are internal to the module but `watcher_thread_proc` is only called from `start_watcher` which is only called from `handle_watch_command`. The chain is alive but the watcher thread implementation may have issues — it was not tested in this session. |
| `prompt_generator.odin` and `prompt_interactive.odin` mostly dead | Low | Both files | Only 3 of 9 procs in prompt_generator and 2 of 7 in prompt_interactive are used. The rest are never called. |
| Fish shell support incomplete | Low | `src/shell_fish.odin` | `shell_fish_generate_init` is called by `init_generator.odin` when `g_ctx.shell == .FISH`, but Fish completions and plugin loading paths are not wired. The `fish` shell type exists in `ShellType` enum but many code paths only handle ZSH and BASH. |
| `build_output.odin` is a stub | Low | `src/build_output.odin` | `generate_eval_output_optimized` just calls `generate_optimized_init_all()` and prints a source command. The "adaptive optimization" (SIMD, threaded, GPU) was in `adaptive_optimizer.odin` which was removed as dead. The build command is effectively a no-op beyond init generation. |
| `turbo_export.odin` contains many dead procs | Low | `src/turbo_export.odin` | `handle_export_command` is alive, but `generate_turbo_export`, `build_turbo_content`, `append_*_direct`, `escape_turbo_value`, `check_turbo_status`, `print_export_formats` are only called internally within the file. The export feature works but the codebase has more code than needed. |
| `alias_sources.odin` may be dead | Low | `src/alias_sources.odin` | `print_external_alias_sources` is assigned as a function pointer in `ALIAS_SPEC.list_epilogue`, which is called from `config_entry.odin` when `action == .LIST`. However, the actual `read_alias_sources` and `print_external_alias_sources` procs may not be called in practice because modern TOML-first aliases bypass the legacy list flow. Needs verification. |
| TUI placeholder views | Cosmetic | `src/tui_view_hooks.odin`, `src/tui_view_settings.odin` | Hooks view and settings view are just placeholders (37 and 49 lines). They render minimal text. |
| TUI cache returns placeholder counts | Cosmetic | `src/tui_views_cache.odin:56,63` | When cache not loaded, returns hardcoded `10` and `8` as placeholder counts. |

---

## Incomplete Work

### 1. Dead code removal (this session)
**State:** First pass completed. 7 files removed, 4 files shrunk. ~4,242 lines removed.  
**Remaining:** Many files still have large amounts of dead internal code:
- `plugin_storage.odin` (2302 lines) — likely 50%+ internally dead
- `toml.odin` (1844 lines) — many helper procs unused
- `style.odin` (1134 lines) — ~1000 lines of dead styling DSL
- `fuzzy.odin` (1116 lines) — ~1000 lines of dead full-screen finder
- `init_generator.odin` (1086 lines) — many internal procs may be unused
- `lock.odin` (734 lines) — ~600 lines of dead write/update logic
- `hot_reload.odin` (583 lines) — many internal procs may be unused
- `backup.odin` (781 lines) — some TUI-specific procs unused
- `prompt_generator.odin` (661 lines) — ~500 lines unused
- `prompt_interactive.odin` (429 lines) — ~300 lines unused
- `config_entry.odin` (1151 lines) — interactive/form procs may be dead
- `hooks.odin` (485 lines) — many hook procs are no-op stubs

### 2. Theme system
**State:** Completely removed in this session. `theme.odin` (1119 lines) and `theme_starship.odin` (419 lines) deleted.  
**What was it:** Theme management (`wayu theme list/add/apply`) and Starship prompt integration.  
**Why removed:** The theme command was never wired in `cli_parser.odin` or `main.odin`. No code path could ever invoke it.  
**If needed later:** Restore from git history. The types (`ThemeType`, `ThemeConfig`) were also removed from `interfaces.odin`.

### 3. Integration files (mise, direnv)
**State:** Removed. `integration_mise.odin` (542 lines) and `integration_direnv.odin` (351 lines) deleted.  
**What was it:** Planned integrations for `mise` (rtx) version manager and `direnv` auto-loading.  
**Why removed:** Zero references anywhere in the codebase. Complete dead code.

### 4. Completions system consolidation
**State:** `completions.odin` (410 lines) merged into `wayu_completions.odin`.  
**Result:** `wayu_completions.odin` grew from ~465 to 867 lines. The old completions handler (`handle_completions_command`) was copied in verbatim. Some dead procs may remain in the merged file.

### 5. Benchmark suite
**State:** Broken. Doesn't compile with current Odin.  
**What needs doing:** Replace `os.system()` with `libc.system()`, replace `os.OS` with `ODIN_OS` or `#config` blocks, replace `os.remove_directory` with `os.remove()`. Also the benchmark assumes `wayu` is installed at `/usr/local/bin/wayu`.

### 6. UI tests
**State:** Broken. Package name mismatch.  
**What needs doing:** Rename all `tests/ui/*.odin` files to use the same package name, or run them individually with `-file` flag one at a time.

### 7. Fish shell support
**State:** Declared in `ShellType` enum and `shell_fish.odin` exists, but:
- Fish completions not wired in `wayu_completions.odin`
- Fish plugin loading paths not implemented
- Fish TUI keybindings may differ
**What needs doing:** Add fish-specific code paths where ZSH/BASH branches exist.

### 8. Hooks system
**State:** All pre/post hook procs (`hook_pre_alias_add`, `hook_post_alias_add`, etc.) are defined as no-ops and assigned to `ConfigEntrySpec` function pointers.  
**What needs doing:** Either implement real hook execution or remove the stub system entirely.

---

## What To Work On Next

### 1. Finish dead-code removal (High priority, High difficulty)
**What:** Audit the remaining bloated files and remove dead internal procs.  
**Files:** `plugin_storage.odin`, `toml.odin`, `style.odin`, `fuzzy.odin`, `init_generator.odin`, `lock.odin`, `prompt_generator.odin`, `prompt_interactive.odin`, `hooks.odin`, `backup.odin`, `turbo_export.odin`.  
**Why:** The codebase is still 33,570 lines. Realistically ~40% may be dead. Smaller codebase = faster compiles, easier to understand, fewer bugs.  
**Difficulty:** High. Requires careful cross-reference analysis because many procs are assigned as function pointers in `ConfigEntrySpec`, `CHECKS` array, or `hooks` config. The `odin check` compiler won't catch function-pointer dead code.  
**Dependencies:** None, but must verify `./build_it && ./build_it test` after each file change.

### 2. Fix or remove broken test suites (Medium priority, Low difficulty)
**What:** Either fix the UI tests (rename packages) and benchmark suite (port to current Odin APIs), or remove them.  
**Files:** `tests/ui/*.odin`, `tests/benchmark/benchmark_suite.odin`.  
**Why:** Broken tests create noise and reduce confidence in the test suite.  
**Difficulty:** Low for removal, medium for fixing.  
**Dependencies:** None.

### 3. Implement Fish shell support fully (Medium priority, Medium difficulty)
**What:** Wire Fish shell in CLI parser, completions, plugin loader, and init generator.  
**Files:** `src/shell_fish.odin`, `src/wayu_completions.odin`, `src/plugin_loader.odin`, `src/init_generator.odin`, `src/cli_parser.odin`.  
**Why:** Fish is declared as supported in AGENTS.md but not fully wired.  
**Difficulty:** Medium. Fish syntax is different enough (no arrays, different completion system).  
**Dependencies:** None.

### 4. Implement real hooks or remove the stub system (Medium priority, Low difficulty)
**What:** Either make hooks execute user-defined shell commands, or delete the no-op hook procs and remove hook fields from `ConfigEntrySpec`.  
**Files:** `src/hooks.odin`, `src/config_specs.odin`, `src/config_entry.odin`.  
**Why:** Currently all hooks are no-ops. The system creates cognitive overhead for no benefit.  
**Difficulty:** Low if removing, medium if implementing real hooks.  
**Dependencies:** None.

### 5. TOML parser simplification (Low priority, High difficulty)
**What:** `toml.odin` is 1844 lines with a custom parser, serializer, section replacer, profile merger, etc. Evaluate if Odin now has a TOML library, or if the parser can be simplified.  
**Files:** `src/toml.odin`.  
**Why:** 1844 lines for TOML is excessive. Risk of bugs in the custom parser.  
**Difficulty:** High. The parser is deeply integrated with section replacement (only rewrite `[paths]` without touching other sections). A generic library may not support this.  
**Dependencies:** None.

### 6. Lock file system — use it or lose it (Low priority, Low difficulty)
**What:** `lock.odin` has 734 lines of SHA256 hash tracking, but only `lock_read` is used (by hot_reload and static_gen). All write/update/verify logic is dead.  
**Files:** `src/lock.odin`, `src/static_gen.odin`, `src/hot_reload.odin`.  
**Why:** Either implement lock file generation on every write (for integrity checking), or delete the write/update procs and keep only `lock_read`.  
**Difficulty:** Low.  
**Dependencies:** None.

---

## Commands Reference

All commands verified in this session:

```bash
# Build
./build_it              # Production build (optimized)
./build_it debug        # Development build
./build_it check        # Type-check only
./build_it install      # Install to /usr/local/bin

# Test
./build_it test         # Unit tests (505 tests, all pass)

# Integration tests (Ruby, requires ruby)
ruby tests/integration/run_all.rb   # 15/15 suites pass
ruby tests/integration/test_path.rb # Single suite
ruby tests/integration/test_alias.rb
ruby tests/integration/test_constants.rb
ruby tests/integration/test_backup.rb
ruby tests/integration/test_validation.rb
ruby tests/integration/test_errors.rb
ruby tests/integration/test_dry_run.rb
ruby tests/integration/test_init.rb
ruby tests/integration/test_completions.rb
ruby tests/integration/test_plugin.rb

# Component snapshot / visual regression
./build_it && ./unit --test-component-snapshot   # regenerate goldens
./build_it && ./unit --test-components            # compare against goldens

# CLI usage
./bin/wayu --version    # → "wayu v4.0.0"
./bin/wayu help         # → full help text
./bin/wayu path list    # → list PATH entries
./bin/wayu --tui        # → launch TUI
```

---

## Git State

**Branch:** `main` (ahead of `origin/main` by this session's changes)  
**Modified files:** 16 (all dead-code removals and shrinkages)  
**Untracked files:** `FEATURE_MAP.md`, `src.bak/` (manual backup directory)  
**No staged changes.**  
**Recommendation:** Commit the dead-code removals before any new work.
