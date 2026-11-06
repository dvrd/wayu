# Wayu Feature Map & Dead Code Audit

Generated 2026-05-09 after first pass of dead-code removal.

## Overview

| Metric | Before | After | Removed |
|--------|--------|-------|---------|
| Source files | 75 | 68 | 7 files |
| Source lines | 37,812 | 33,570 | ~4,242 lines |
| Unit test files | 12 | 9 | 3 files |

## Command Feature Map

### 1. PATH (`wayu path`)
- **Entry**: `handle_path_command` in `src/path.odin` (990 lines)
- **Spec**: `PATH_SPEC` in `src/config_specs.odin`
- **Alive actions**: add, remove, list, clean, dedup, get
- **Support**: `src/config_entry.odin` (generic TOML entry dispatcher)
- **Status**: ✅ Fully alive

### 2. ALIAS (`wayu alias`)
- **Entry**: `handle_alias_command` in `src/alias.odin` (522 lines)
- **Spec**: `ALIAS_SPEC` in `src/config_specs.odin`
- **External sources**: `src/alias_sources.odin` (244 lines) — reads `alias-sources.conf`
- **Alive actions**: add, remove, list, get
- **Status**: ✅ Fully alive

### 3. CONSTANTS (`wayu constants`)
- **Entry**: `handle_constants_command` in `src/constants.odin` (591 lines)
- **Spec**: `CONSTANTS_SPEC` in `src/config_specs.odin`
- **Alive actions**: add, remove, list, get
- **Status**: ✅ Fully alive

### 4. COMPLETIONS (`wayu completions`)
- **Entry**: `handle_completions_command_extended` in `src/wayu_completions.odin` (867 lines)
- **Old system**: `src/completions.odin` — ❌ **REMOVED** (superseded by wayu_completions.odin)
- **Alive actions**: list, add, remove, generate (zsh self-completions)
- **Status**: ✅ Alive after merge

### 5. BACKUP (`wayu backup`)
- **Entry**: `handle_backup_command` in `src/backup.odin` (781 lines)
- **Alive actions**: list, restore
- **Status**: ✅ Alive

### 6. PLUGIN (`wayu plugin`)
- **Entry**: `handle_plugin_command` in `src/plugin.odin` (775 lines)
- **Storage**: `src/plugin_storage.odin` (2302 lines) — mostly alive, some dead internals
- **Loader**: `src/plugin_loader.odin` (525 lines) — partially alive
- **Alive actions**: add, remove, list, check, update
- **Status**: ✅ Alive but bloated

### 7. INIT (`wayu init`)
- **Entry**: `handle_init_command` in `src/main.odin`
- **Generator**: `src/init_generator.odin` (1086 lines) — alive but bloated
- **Templates**: `src/preload.odin` (628 lines) — partially alive
- **Status**: ✅ Alive

### 8. MIGRATE (`wayu migrate`)
- **Entry**: `handle_migrate_command` in `src/migrate.odin` (510 lines)
- **Schema upgrade**: `src/migrate_schema.odin` (438 lines) — `migrate_toml_schema` alive
- **Status**: ✅ Alive

### 9. CONFIG (`wayu config`)
- **Entry**: `handle_config_extra_command` in `src/config_command.odin` (442 lines)
- **Alive actions**: edit, extend, scan
- **Status**: ✅ Alive

### 10. BUILD (`wayu build`)
- **Entry**: `handle_build_command` in `src/main.odin` → delegates to `src/build_output.odin`
- **Status**: ✅ Alive but shrunk (was 198 lines, now 53)
- **Dead removed**: `adaptive_optimizer.odin` (359 lines) — entire file removed

### 11. EXPORT (`wayu export`)
- **Entry**: `handle_export_command` in `src/turbo_export.odin` (458 lines)
- **Status**: ✅ Alive

### 12. TOML (`wayu toml`)
- **Entry**: `handle_toml_command` in `src/toml.odin` (1844 lines)
- **Status**: ✅ Alive but very bloated
- **Note**: Many internal TOML helper procs may be dead; needs deeper audit

### 13. DOCTOR (`wayu doctor`)
- **Entry**: `handle_doctor_command` in `src/doctor.odin` (776 lines)
- **Checks**: `src/doctor_checks.odin` (493 lines) — alive via CHECKS function-pointer array
- **Status**: ✅ Alive

### 14. TEMPLATE (`wayu template`)
- **Entry**: `handle_template_command` in `src/templates.odin` (250 lines)
- **Status**: ✅ Alive but bloated (only entry point used; template apply procs mostly dead)

### 15. HOOKS (`wayu hooks`)
- **Entry**: `handle_hooks_command` in `src/hooks.odin` (485 lines)
- **Status**: ✅ Alive but bloated (many hook procs are stubs assigned as function pointers)

### 16. RELOAD / WATCH (`wayu reload`)
- **Entry**: `handle_watch_command` in `src/hot_reload.odin` (583 lines)
- **Status**: ✅ Alive

### 17. SEARCH / FIND (`wayu search` / `wayu find`)
- **Entry**: `handle_search_command` in `src/search.odin` (441 lines)
- **Fuzzy**: `src/fff_integration.odin` (604 lines) — alive (used by search, path, alias, constants)
- **Status**: ✅ Alive

### 18. VERSION (`wayu version` / `wayu -v`)
- **Entry**: `print_version` in `src/main.odin`
- **Status**: ✅ Alive

### 19. HELP (`wayu help` / `wayu -h`)
- **Entry**: `print_help` in `src/main.odin`
- **Status**: ✅ Alive

### 20. TUI (`wayu` with no args, or `wayu --tui`)
- **Core**: `src/tui_main.odin` (823 lines)
- **State**: `src/tui_state.odin` (547 lines)
- **Data**: `src/tui_data.odin` (646 lines)
- **Render**: `src/tui_render.odin` (247 lines)
- **Layout**: `src/tui_layout.odin` (289 lines)
- **Events**: `src/tui_events.odin` (129 lines)
- **Terminal**: `src/tui_terminal.odin` (143 lines)
- **Screen**: `src/tui_screen.odin` (133 lines)
- **Components**: `src/tui_components.odin` (196 lines)
- **Views**: `src/tui_views_*.odin` files
- **Status**: ✅ Alive

---

## Removed Dead Features / Files

### Entire Files Removed

| File | Lines | Reason |
|------|-------|--------|
| `src/completions.odin` | 410 | Superseded by `wayu_completions.odin`; merged needed logic |
| `src/progress.odin` | 312 | Zero references anywhere |
| `src/integration_mise.odin` | 542 | Zero references anywhere |
| `src/integration_direnv.odin` | 351 | Zero references anywhere |
| `src/theme.odin` | 1119 | Theme command never wired in CLI parser |
| `src/theme_starship.odin` | 419 | Starship theme system unused |
| `src/adaptive_optimizer.odin` | 359 | Only referenced by dead build_output internals |

### Files Drastically Shrunk

| File | Before | After | Kept |
|------|--------|-------|------|
| `src/output.odin` | 857 | 44 | `json_escape`, `AliasEntry` |
| `src/build_output.odin` | 198 | 53 | `generate_eval_output_optimized`, `print_build_help` |
| `src/interfaces.odin` | 304 | 162 | Removed dead theme/integration/benchmark types |
| `src/exit_codes.odin` | 59 | 27 | Removed dead `exit_with_code`, `error_to_exit_code` |

### Unit Test Files Removed

| File | Reason |
|------|--------|
| `tests/unit/test_output.odin` | Tested dead formatters that were removed |
| `tests/unit/test_lock.odin` | Tested mostly dead lock system internals |
| `tests/unit/test_theme.odin` | Tested removed theme system |

---

## Remaining Bloated / Likely Dead Subsystems (Future Cleanup)

These files are alive at their entry point but contain large amounts of likely-dead internal code:

1. **`src/plugin_storage.odin` (2302 lines)** — massive file; many internal procs may be unused
2. **`src/toml.odin` (1844 lines)** — only a few entry points used; many TOML helper procs likely dead
3. **`src/style.odin`** — `form.odin`/`input.odin` were removed (2026-11-06); audit remaining style procs for dead code
4. **`src/fuzzy.odin` (1116 lines)** — only `enable_raw_mode` and `is_tty` are widely used
5. **`src/init_generator.odin` (1086 lines)** — entry points alive but many internal procs likely unused
6. **`src/config_entry.odin`** — dead interactive/form procs removed (2026-11-06)
7. **`src/wayu_completions.odin` (867 lines)** — merged from completions.odin; some dead procs remain
8. **`src/lock.odin` (734 lines)** — only `lock_read` is used externally; rest is unused lock write/update logic
9. **`src/doctor.odin` (776 lines)** — alive but `attempt_auto_fixes` is dead
10. **`src/static_gen.odin` (596 lines)** — only called by `hot_reload.odin`; many internal procs may be unused
11. **`src/fff_integration.odin` (604 lines)** — alive core but some procs unused
12. **`src/hot_reload.odin` (583 lines)** — alive entry point but many internal procs unused
13. **`src/backup.odin` (781 lines)** — alive but contains dead TUI-specific backup procs
14. **`src/turbo_export.odin` (458 lines)** — alive entry point but many internal procs unused
15. **`src/table.odin` (372 lines)** — mostly unused table rendering system
16. **`src/prompt_generator.odin` (661 lines)** — only 3 procs used by init_generator
17. **`src/prompt_interactive.odin` (429 lines)** — only 2 procs used by init_generator
18. **`src/migrate_schema.odin` (438 lines)** — `migrate_toml_schema` alive; many internal procs likely dead
19. **`src/profile.odin` (318 lines)** — `profile_startup_performance` alive; `render_phase_breakdown_zsh` dead
20. **`src/shell_fish.odin` (301 lines)** — only 2 procs used; Fish shell not fully wired in CLI

---

## Build Verification

- ✅ `./build_it` — production build passes
- ✅ `./build_it check` — type-check passes
- ✅ `./build_it test` — all 505 unit tests pass
- ✅ `./bin/wayu --version` — CLI runs correctly
- ✅ `./bin/wayu help` — help output correct
