# Large-Effort Improvements Implementation Plan

**Goal:** Three major improvements — decompose plugin.odin (2,621 lines) into 5 focused files, implement TUI Enter-key detail views for all 7 stubs, and extract text truncation to style.odin + implement real-time fuzzy filtering in TUI.

**Architecture:** Plugin decomposition is a pure refactor (move functions, no logic changes). TUI Enter-key handlers add overlay/detail state to the TEA state machine with new bridge functions. Text truncation extraction centralizes `truncate_to_width` from table.odin into style.odin, and TUI fuzzy filtering adds an inline filter input mode to list views.

**Design:** Self-contained plan based on thorough source analysis of all affected files.

---

## Dependency Graph

```
Batch 1 (parallel): 1.1, 1.2, 1.3, 1.4, 1.5 [plugin decomposition - pure file moves]
Batch 2 (sequential): 2.1 [verify plugin decomposition compiles + tests pass]
Batch 3 (parallel): 3.1, 3.2, 3.3, 3.4 [TUI state + bridge + style extraction]
Batch 4 (parallel): 4.1, 4.2, 4.3 [TUI view handlers + renderers + fuzzy]
Batch 5 (sequential): 5.1 [integration verification]
```

---

## Task 1: Decompose plugin.odin (2,621 lines -> 5 files)

### Background

`src/plugin.odin` is the largest file in the codebase at 2,621 lines. It contains types, registry data, utility helpers, config I/O, git operations, dependency resolution, conflict detection, and 10 command handlers. All functions are in the `main` package so decomposition keeps them in `src/` with no import changes needed.

Additionally, `handle_plugin_enable` (lines 1700-1803) and `handle_plugin_disable` (lines 1805-1911) are structurally identical — they differ only in: `enabled=true` vs `false`, idempotent check inversion, header text, and success messages. These will be merged into a single `handle_plugin_set_enabled(args: []string, enable: bool)`.

### File Decomposition Map

| New File | Contents | Source Lines | ~Size |
|----------|----------|-------------|-------|
| `src/plugin.odin` | Types, structs, enums, POPULAR_PLUGINS, utility helpers, `handle_plugin_command` dispatcher | 1-213, 2507-2535 | ~250 lines |
| `src/plugin_registry.odin` | Config paths, config read/write (pipe + JSON5), migration, git ops, plugin file detection, find/lookup, URL utils, dependency validation, circular dep detection, priority resolution, conflict detection, resolve_plugin, remote_commit | 268-1427 | ~1,160 lines |
| `src/plugin_operations.odin` | handle_plugin_add, handle_plugin_remove, handle_plugin_update, handle_plugin_check, handle_plugin_enable, handle_plugin_disable (merged), handle_plugin_priority, handle_plugin_get, handle_plugin_list | 1429-2505 | ~950 lines |
| `src/plugin_config.odin` | generate_plugins_file (loader generation, ~200 lines) | 583-785 | ~200 lines |
| `src/plugin_help.odin` | print_plugin_help, print_plugin_add_help | 2539-2621 | ~85 lines |

### Merge: enable/disable -> set_enabled

**Current** (two ~100-line functions):
```
handle_plugin_enable(args)   // lines 1700-1803
handle_plugin_disable(args)  // lines 1805-1911
```

**After** (one function + two thin wrappers):
```odin
// In plugin_operations.odin
handle_plugin_set_enabled :: proc(args: []string, enable: bool) {
    action_word := enable ? "Enabling" : "Disabling"
    past_word := enable ? "enabled" : "disabled"
    // ... shared logic with enable param controlling the boolean flip
}

handle_plugin_enable :: proc(args: []string) {
    handle_plugin_set_enabled(args, true)
}

handle_plugin_disable :: proc(args: []string) {
    handle_plugin_set_enabled(args, false)
}
```

The dispatcher in `handle_plugin_command` already calls `handle_plugin_enable(args)` and `handle_plugin_disable(args)`, so the wrappers maintain backward compatibility with zero changes to the dispatcher.

---

## Batch 1: Plugin Decomposition (parallel - 5 implementers)

All tasks in this batch have NO dependencies and run simultaneously. Each task creates one new file by extracting functions from the original `src/plugin.odin`. The original file is replaced in Task 1.1.

**CRITICAL**: All files are in `package main` (same as original). No import changes needed — all functions remain in the same package namespace.

### Task 1.1: plugin.odin (types + dispatcher, replaces original)
**File:** `src/plugin.odin`
**Test:** `tests/unit/test_plugin.odin` (existing — must still pass after all 5 tasks complete)
**Depends:** none (but all 5 tasks must complete before verification)

**What stays in this file:**
- Package declaration and all imports used by types/helpers
- All type definitions: `ShellCompat`, `PluginInfo`, `InstalledPlugin`, `PluginConfig`, `PluginMetadata`, `GitMetadata`, `ConflictInfo`, `PluginConfigJSON` (lines 1-100)
- `POPULAR_PLUGINS` registry constant (lines 100-160)
- Utility helpers: `parse_shell_compat`, `shell_compat_to_string`, `get_iso8601_timestamp`, `exec_command_output` (lines 160-213)
- Git metadata helpers: `get_git_info`, `cleanup_plugin_metadata`, `cleanup_plugin_config_json` (lines 215-266)
- `handle_plugin_command` dispatcher (lines 2507-2535)

**What gets removed:** Everything else (moved to other files).

**Approximate result:** ~300 lines

**Implementation notes:**
- Keep ALL existing imports that the types and helpers need (fmt, strings, os, etc.)
- The dispatcher calls `handle_plugin_*` procs that now live in `plugin_operations.odin` — this works because they're in the same package
- Do NOT change any function signatures or type definitions

### Task 1.2: plugin_registry.odin (discovery, config I/O, dependency resolution)
**File:** `src/plugin_registry.odin`
**Test:** `tests/unit/test_plugin.odin` (existing — shared)
**Depends:** none

**What goes in this file (extracted from plugin.odin):**
```
// Config file paths (lines 268-281)
get_plugins_config_file
get_plugins_json_config_file
get_plugins_dir

// Config read/write - pipe-delimited format (lines 283-364)
read_plugin_config
write_plugin_config

// Config read/write - JSON5 format (lines 366-428)
read_plugin_config_json
write_plugin_config_json

// Migration (lines 430-506)
migrate_plugin_config

// Git operations (lines 508-550)
git_clone
git_update
is_git_repo

// Plugin file detection (lines 552-581)
detect_plugin_file

// URL/name utilities (lines 787-812)
is_valid_git_url
extract_plugin_name_from_url

// Find/lookup (lines 814-857)
find_plugin
is_plugin_installed
find_plugin_json
validate_plugin_dependencies

// Dependents check (lines 860-883)
check_plugin_dependents

// Circular dependency detection - DFS (lines 885-1048)
// All procs in this section

// Priority resolution (lines 1050-1166)
resolve_dependencies_with_priority
dfs_visit_with_priority

// Conflict detection (lines 1168-1371)
scan_plugin_conflicts
detect_conflicts

// Resolve plugin (lines 1373-1400)
resolve_plugin

// Remote commit check (lines 1402-1427)
get_remote_commit
```

**Approximate result:** ~1,160 lines

**Implementation notes:**
- File header: `package main`
- Import only what these functions need (fmt, strings, os, filepath, etc.)
- These functions reference types from plugin.odin (same package, no import needed)

### Task 1.3: plugin_operations.odin (command handlers)
**File:** `src/plugin_operations.odin`
**Test:** `tests/unit/test_plugin.odin` (existing — shared)
**Depends:** none

**What goes in this file (extracted from plugin.odin):**
```
// Merged enable/disable (lines 1700-1911 -> single proc + 2 wrappers)
handle_plugin_set_enabled  // NEW - merged logic
handle_plugin_enable       // thin wrapper -> handle_plugin_set_enabled(args, true)
handle_plugin_disable      // thin wrapper -> handle_plugin_set_enabled(args, false)

// All other command handlers
handle_plugin_check    (lines 1429-1522)
handle_plugin_update   (lines 1524-1698)
handle_plugin_priority (lines 1913-2000)
handle_plugin_add      (lines 2004-2127)
handle_plugin_list     (lines 2129-2256)
handle_plugin_remove   (lines 2258-2396)
handle_plugin_get      (lines 2398-2505)
```

**Approximate result:** ~950 lines (down from ~1,076 due to enable/disable merge saving ~100 lines)

**Enable/Disable merge implementation:**
```odin
package main

// handle_plugin_set_enabled is the shared implementation for enable/disable.
// The `enable` parameter controls whether the plugin is being enabled (true) or disabled (false).
handle_plugin_set_enabled :: proc(args: []string, enable: bool) {
    action_word := enable ? "Enabling" : "Disabling"
    past_tense  := enable ? "enabled" : "disabled"
    target_state := enable

    if len(args) < 1 {
        print_styled_error(fmt.tprintf("Usage: wayu plugin %s <name>", enable ? "enable" : "disable"))
        os.exit(int(Exit_Code.USAGE))
    }

    name := args[0]

    // Read current config
    plugins, ok := read_plugin_config()
    if !ok {
        print_styled_error("Failed to read plugin configuration")
        os.exit(int(Exit_Code.IOERR))
    }
    defer {
        for &p in plugins { /* cleanup */ }
        delete(plugins)
    }

    // Find plugin
    found_idx := -1
    for p, i in plugins {
        if p.name == name {
            found_idx = i
            break
        }
    }

    if found_idx == -1 {
        print_styled_error(fmt.tprintf("Plugin '%s' not found", name))
        os.exit(int(Exit_Code.DATAERR))
    }

    // Idempotent check
    if plugins[found_idx].enabled == target_state {
        print_styled_warning(fmt.tprintf("Plugin '%s' is already %s", name, past_tense))
        return
    }

    // Apply change
    print_styled_header(fmt.tprintf("%s plugin: %s", action_word, name))
    plugins[found_idx].enabled = target_state

    // Write config
    if !write_plugin_config(plugins) {
        print_styled_error("Failed to write plugin configuration")
        os.exit(int(Exit_Code.IOERR))
    }

    // Regenerate loader
    generate_plugins_file(plugins)

    print_styled_success(fmt.tprintf("Plugin '%s' %s successfully", name, past_tense))
}

handle_plugin_enable :: proc(args: []string) {
    handle_plugin_set_enabled(args, true)
}

handle_plugin_disable :: proc(args: []string) {
    handle_plugin_set_enabled(args, false)
}
```

### Task 1.4: plugin_config.odin (loader generation)
**File:** `src/plugin_config.odin`
**Test:** `tests/unit/test_plugin.odin` (existing — shared)
**Depends:** none

**What goes in this file (extracted from plugin.odin):**
```
// Loader generation (lines 583-785)
generate_plugins_file  // ~200 lines, generates plugins.{zsh,bash} loader script
```

**Approximate result:** ~210 lines (including package header and imports)

**Implementation notes:**
- This is the most complex single function — it generates shell scripts
- References types from plugin.odin and helpers from plugin_registry.odin (same package)
- Needs fmt, strings, os imports

### Task 1.5: plugin_help.odin (help text)
**File:** `src/plugin_help.odin`
**Test:** none (help text output, tested via integration tests)
**Depends:** none

**What goes in this file (extracted from plugin.odin):**
```
// Help text (lines 2539-2621)
print_plugin_help
print_plugin_add_help
```

**Approximate result:** ~90 lines

**Implementation notes:**
- Pure output functions, no complex logic
- References styled output procs from style.odin (same package)

---

## Batch 2: Plugin Decomposition Verification (sequential - 1 implementer)

### Task 2.1: Verify plugin decomposition compiles and tests pass
**File:** none (verification only)
**Test:** `tests/unit/test_plugin.odin` (existing 16 tests)
**Depends:** 1.1, 1.2, 1.3, 1.4, 1.5

**Steps:**
```bash
# 1. Verify compilation
task check

# 2. Run unit tests (all 235 should pass, especially the 16 plugin tests)
task test

# 3. Run plugin integration tests specifically
task test:plugin

# 4. Build and smoke test
task build-dev
./bin/wayu plugin help
./bin/wayu plugin list
```

**Success criteria:**
- `task check` exits 0 (no compiler errors)
- `task test` shows 235/235 passing
- `task test:plugin` shows 16/16 passing
- `wayu plugin help` displays help text
- `wayu plugin list` works correctly

**Common issues to watch for:**
- Missing imports in new files (each file needs its own import block)
- Duplicate proc names (shouldn't happen since we're moving, not copying)
- Missing package declaration (`package main` at top of each file)

---

## Task 2: TUI Phase 6 — Enter Key Detail Views

### Background

`src/tui/main.odin` has 7 TODO stubs at lines 165-183 in the `handle_selection` proc. When a user presses Enter on a selected item in any view, nothing happens. We need to implement view-specific detail/action behaviors.

### Design Decisions

**Overlay approach:** Add `show_detail: bool` and `detail_lines: [dynamic]string` fields to `TUIState`. When Enter is pressed, the handler populates `detail_lines` and sets `show_detail = true`. The render loop draws a centered overlay panel on top of the current view. Pressing Esc or Enter dismisses the overlay.

**Bridge functions needed:** Some detail views need data from the main package (e.g., checking if a path directory exists, getting backup file sizes). We'll add new bridge function pointers for these.

**What each Enter key does:**

| View | Enter Behavior | Bridge Needed? |
|------|---------------|----------------|
| PATH_VIEW | Show path details: exists?, permissions, symlink target | Yes: `g_get_path_detail` |
| ALIAS_VIEW | Show alias details: name, full command, shell | No (data already cached) |
| CONSTANTS_VIEW | Show constant details: name, value, type detection | No (data already cached) |
| COMPLETIONS_VIEW | Show completion file info: size, path, preview | Yes: `g_get_completion_detail` |
| BACKUPS_VIEW | Trigger restore of selected backup | Yes: `g_restore_backup` |
| PLUGINS_VIEW | Show plugin details: status, URL, deps, conflicts | Yes: `g_get_plugin_detail` |
| SETTINGS_VIEW | No-op (settings are display-only) | No |

---

## Batch 3: TUI State + Bridge + Style Extraction (parallel - 4 implementers)

### Task 3.1: Add overlay state to TUIState
**File:** `src/tui/state.odin`
**Test:** `tests/unit/test_tui_state.odin` (new)
**Depends:** none

**Changes to `src/tui/state.odin`:**

Add these fields to the `TUIState` struct:
```odin
TUIState :: struct {
    // ... existing fields ...

    // Overlay/detail panel state (NEW)
    show_detail:    bool,
    detail_title:   string,
    detail_lines:   [dynamic]string,
    detail_action:  DetailAction,  // What action triggered the detail view
}

DetailAction :: enum {
    NONE,
    VIEW_DETAIL,     // Just viewing info (dismiss with Esc/Enter)
    CONFIRM_RESTORE, // Backup restore confirmation (y/n)
}
```

Add cleanup and helper procs:
```odin
// Clear the detail overlay and free memory
clear_detail :: proc(state: ^TUIState) {
    state.show_detail = false
    if len(state.detail_title) > 0 {
        delete(state.detail_title)
        state.detail_title = ""
    }
    for line in state.detail_lines {
        delete(line)
    }
    clear(&state.detail_lines)
    state.detail_action = .NONE
}

// Show a detail overlay with title and lines
show_detail_overlay :: proc(state: ^TUIState, title: string, lines: []string, action: DetailAction = .VIEW_DETAIL) {
    clear_detail(state)
    state.show_detail = true
    state.detail_title = strings.clone(title)
    state.detail_action = action
    for line in lines {
        append(&state.detail_lines, strings.clone(line))
    }
}
```

**Test file `tests/unit/test_tui_state.odin`:**
```odin
package tests

import "core:testing"
import "core:strings"

@(test)
test_clear_detail_resets_state :: proc(t: ^testing.T) {
    // Test that clear_detail properly resets all overlay fields
    // (Unit test verifying memory cleanup)
}

@(test)
test_show_detail_overlay_sets_fields :: proc(t: ^testing.T) {
    // Test that show_detail_overlay populates state correctly
}

@(test)
test_detail_action_enum_values :: proc(t: ^testing.T) {
    // Test enum values exist and are distinct
}
```

### Task 3.2: Add bridge function pointers for detail views
**File:** `src/tui/bridge.odin`
**Test:** none (bridge is tested via integration)
**Depends:** none

**Add to `src/tui/bridge.odin`:**
```odin
// Detail view bridge functions (NEW)
g_get_path_detail:       proc(path: string) -> []string = nil
g_get_completion_detail: proc(name: string) -> []string = nil
g_restore_backup:        proc(config_type: string) -> bool = nil
g_get_plugin_detail:     proc(name: string) -> []string = nil
```

**Add to `src/tui_bridge_impl.odin`** (main package implementation):
```odin
// In tui_set_bridge_functions, add:
tui.g_get_path_detail = bridge_get_path_detail
tui.g_get_completion_detail = bridge_get_completion_detail
tui.g_restore_backup = bridge_restore_backup
tui.g_get_plugin_detail = bridge_get_plugin_detail

// Implementation procs:
bridge_get_path_detail :: proc(path_str: string) -> []string {
    result := make([dynamic]string)
    append(&result, strings.clone(fmt.tprintf("Path: %s", path_str)))
    
    if os.exists(path_str) {
        append(&result, strings.clone("Status: EXISTS"))
        // Check if directory
        info, err := os.stat(path_str)
        if err == 0 {
            is_dir := os.is_dir(info)
            append(&result, strings.clone(fmt.tprintf("Type: %s", is_dir ? "Directory" : "File")))
        }
    } else {
        append(&result, strings.clone("Status: MISSING"))
        append(&result, strings.clone("Warning: This path does not exist on disk"))
    }
    
    return result[:]
}

bridge_get_completion_detail :: proc(name: string) -> []string {
    result := make([dynamic]string)
    comp_path := fmt.tprintf("%s/completions/_%s", WAYU_CONFIG, name)
    append(&result, strings.clone(fmt.tprintf("Completion: %s", name)))
    append(&result, strings.clone(fmt.tprintf("File: _%s", name)))
    
    if os.exists(comp_path) {
        data, ok := os.read_entire_file_from_filename(comp_path)
        if ok {
            append(&result, strings.clone(fmt.tprintf("Size: %d bytes", len(data))))
            // Show first 3 lines as preview
            content := string(data)
            lines := strings.split(content, "\n")
            defer delete(lines)
            preview_count := min(3, len(lines))
            append(&result, strings.clone(""))
            append(&result, strings.clone("Preview:"))
            for i in 0..<preview_count {
                append(&result, strings.clone(fmt.tprintf("  %s", lines[i])))
            }
            delete(data)
        }
    }
    
    return result[:]
}

bridge_restore_backup :: proc(config_type: string) -> bool {
    // Delegate to existing backup restore logic
    return restore_backup(config_type)
}

bridge_get_plugin_detail :: proc(name: string) -> []string {
    result := make([dynamic]string)
    plugins, ok := read_plugin_config()
    if !ok {
        append(&result, strings.clone("Error: Could not read plugin config"))
        return result[:]
    }
    defer {
        for &p in plugins { /* cleanup */ }
        delete(plugins)
    }
    
    for p in plugins {
        if p.name == name {
            append(&result, strings.clone(fmt.tprintf("Name: %s", p.name)))
            append(&result, strings.clone(fmt.tprintf("URL: %s", p.url)))
            append(&result, strings.clone(fmt.tprintf("Enabled: %v", p.enabled)))
            append(&result, strings.clone(fmt.tprintf("Priority: %d", p.priority)))
            if len(p.dependencies) > 0 {
                append(&result, strings.clone(fmt.tprintf("Dependencies: %s", strings.join(p.dependencies, ", "))))
            }
            break
        }
    }
    
    return result[:]
}
```

### Task 3.3: Extract truncate_to_width to style.odin
**File:** `src/style.odin`
**Test:** `tests/unit/test_style.odin` (existing — add new tests)
**Depends:** none

**Current state:**
- `truncate_to_width` lives in `src/table.odin` (lines 140-188)
- `align_text` in `src/style.odin` (line 398) has a TODO: when `text_width >= width`, it returns text as-is without truncation

**Changes:**

1. **Move `truncate_to_width` from `src/table.odin` to `src/style.odin`:**
   - Cut the proc from table.odin
   - Paste into style.odin (near `align_text`, around line 395)
   - table.odin continues to call it (same package, no import needed)

2. **Fix the TODO in `align_text`** (style.odin ~line 398):
   ```odin
   // BEFORE (current):
   if text_width >= width {
       return text  // TODO: should truncate
   }
   
   // AFTER (fixed):
   if text_width >= width {
       return truncate_to_width(text, width)
   }
   ```

3. **Add new tests to `tests/unit/test_style.odin`:**
   ```odin
   @(test)
   test_truncate_to_width_basic :: proc(t: ^testing.T) {
       result := truncate_to_width("Hello, World!", 8)
       testing.expect_value(t, result, "Hello...")
   }
   
   @(test)
   test_truncate_to_width_no_truncation :: proc(t: ^testing.T) {
       result := truncate_to_width("Hi", 10)
       testing.expect_value(t, result, "Hi")
   }
   
   @(test)
   test_truncate_to_width_exact :: proc(t: ^testing.T) {
       result := truncate_to_width("Hello", 5)
       testing.expect_value(t, result, "Hello")
   }
   
   @(test)
   test_align_text_truncates_long_text :: proc(t: ^testing.T) {
       // Verify the TODO fix: align_text now truncates instead of returning as-is
       result := align_text("This is a very long string", 10, .Left)
       // Should be truncated to 10 chars with ellipsis
       testing.expect(t, visible_width(result) <= 10, "align_text should truncate long text")
   }
   ```

### Task 3.4: Add TUI filter input state
**File:** `src/tui/state.odin` (additional changes beyond Task 3.1)
**Test:** `tests/unit/test_tui_state.odin` (shared with 3.1)
**Depends:** 3.1 (adds to same file)

**NOTE:** This task MUST run after Task 3.1 since both modify `state.odin`. If running in parallel, merge carefully.

**Add filter state to TUIState:**
```odin
TUIState :: struct {
    // ... existing fields ...
    // ... overlay fields from Task 3.1 ...

    // Inline filter state (NEW - for fuzzy filtering in list views)
    filter_active:  bool,           // Is the filter input visible?
    filter_text:    [dynamic]u8,    // Current filter input buffer
    filtered_items: [dynamic]string, // Filtered subset of current view's items
    pre_filter_index: int,          // Saved cursor position before filtering
}
```

Add helper procs:
```odin
// Activate filter mode (triggered by '/' key)
activate_filter :: proc(state: ^TUIState) {
    state.filter_active = true
    state.pre_filter_index = state.selected_index
    clear(&state.filter_text)
    // filtered_items will be populated by the view handler
}

// Deactivate filter mode and restore state
deactivate_filter :: proc(state: ^TUIState) {
    state.filter_active = false
    clear(&state.filter_text)
    for item in state.filtered_items {
        delete(item)
    }
    clear(&state.filtered_items)
}

// Check if a string matches the current filter (case-insensitive substring)
matches_filter :: proc(item: string, filter: []u8) -> bool {
    if len(filter) == 0 { return true }
    filter_str := string(filter)
    lower_item := strings.to_lower(item)
    lower_filter := strings.to_lower(filter_str)
    defer { delete(lower_item); delete(lower_filter) }
    return strings.contains(lower_item, lower_filter)
}
```

---

## Batch 4: TUI View Handlers + Renderers + Fuzzy (parallel - 3 implementers)

### Task 4.1: Implement Enter key handlers in handle_selection
**File:** `src/tui/main.odin`
**Test:** manual TUI testing (interactive)
**Depends:** 3.1, 3.2

**Replace the 7 TODO stubs in `handle_selection` (lines 165-183):**

```odin
handle_selection :: proc(state: ^TUIState) {
    switch state.current_view {
    case .MAIN_MENU:
        // Existing: navigate to selected view
        navigate_to_view(state, state.selected_index)

    case .PATH_VIEW:
        if len(state.path_cache) > 0 && state.selected_index < len(state.path_cache) {
            selected_path := state.path_cache[state.selected_index]
            if g_get_path_detail != nil {
                detail_lines := g_get_path_detail(selected_path)
                show_detail_overlay(state, "PATH Detail", detail_lines)
                // Caller is responsible for freeing detail_lines
                for line in detail_lines { delete(line) }
                delete(detail_lines)
            }
        }

    case .ALIAS_VIEW:
        if len(state.alias_cache) > 0 && state.selected_index < len(state.alias_cache) {
            selected := state.alias_cache[state.selected_index]
            // Parse "name=command" format from cache
            parts := strings.split_n(selected, "=", 2)
            defer delete(parts)
            lines := make([dynamic]string)
            defer { for l in lines { delete(l) }; delete(lines) }
            if len(parts) >= 2 {
                append(&lines, strings.clone(fmt.tprintf("Name: %s", parts[0])))
                append(&lines, strings.clone(fmt.tprintf("Command: %s", parts[1])))
            } else {
                append(&lines, strings.clone(fmt.tprintf("Alias: %s", selected)))
            }
            show_detail_overlay(state, "Alias Detail", lines[:])
        }

    case .CONSTANTS_VIEW:
        if len(state.constants_cache) > 0 && state.selected_index < len(state.constants_cache) {
            selected := state.constants_cache[state.selected_index]
            // Parse "NAME=value" format
            parts := strings.split_n(selected, "=", 2)
            defer delete(parts)
            lines := make([dynamic]string)
            defer { for l in lines { delete(l) }; delete(lines) }
            if len(parts) >= 2 {
                append(&lines, strings.clone(fmt.tprintf("Name: %s", parts[0])))
                append(&lines, strings.clone(fmt.tprintf("Value: %s", parts[1])))
                // Type detection
                val := parts[1]
                if val == "true" || val == "false" {
                    append(&lines, strings.clone("Type: Boolean"))
                } else if _, num_ok := strconv.parse_int(val); num_ok {
                    append(&lines, strings.clone("Type: Integer"))
                } else {
                    append(&lines, strings.clone("Type: String"))
                }
            }
            show_detail_overlay(state, "Constant Detail", lines[:])
        }

    case .COMPLETIONS_VIEW:
        if len(state.completions_cache) > 0 && state.selected_index < len(state.completions_cache) {
            selected := state.completions_cache[state.selected_index]
            if g_get_completion_detail != nil {
                detail_lines := g_get_completion_detail(selected)
                show_detail_overlay(state, "Completion Detail", detail_lines)
                for line in detail_lines { delete(line) }
                delete(detail_lines)
            }
        }

    case .BACKUPS_VIEW:
        if len(state.backups_cache) > 0 && state.selected_index < len(state.backups_cache) {
            selected := state.backups_cache[state.selected_index]
            // Parse backup name to extract config type
            // Backup format: "type_YYYY-MM-DD_HH-MM-SS.bak"
            parts := strings.split(selected, "_")
            defer delete(parts)
            if len(parts) >= 1 {
                config_type := parts[0]
                lines := make([dynamic]string)
                defer { for l in lines { delete(l) }; delete(lines) }
                append(&lines, strings.clone(fmt.tprintf("Backup: %s", selected)))
                append(&lines, strings.clone(fmt.tprintf("Config Type: %s", config_type)))
                append(&lines, strings.clone(""))
                append(&lines, strings.clone("Press 'y' to restore this backup"))
                append(&lines, strings.clone("Press Esc to cancel"))
                show_detail_overlay(state, "Restore Backup?", lines[:], .CONFIRM_RESTORE)
            }
        }

    case .PLUGINS_VIEW:
        if len(state.plugins_cache) > 0 && state.selected_index < len(state.plugins_cache) {
            selected := state.plugins_cache[state.selected_index]
            if g_get_plugin_detail != nil {
                detail_lines := g_get_plugin_detail(selected)
                show_detail_overlay(state, "Plugin Detail", detail_lines)
                for line in detail_lines { delete(line) }
                delete(detail_lines)
            }
        }

    case .SETTINGS_VIEW:
        // Settings are display-only, Enter does nothing
        break
    }
}
```

### Task 4.2: Add overlay rendering to views.odin
**File:** `src/tui/views.odin`
**Test:** manual TUI testing (interactive)
**Depends:** 3.1

**Add overlay render proc and integrate into render dispatch:**

```odin
// Add to views.odin - renders a centered detail overlay panel
render_detail_overlay :: proc(state: ^TUIState, width, height: int) {
    if !state.show_detail { return }

    // Calculate overlay dimensions
    overlay_w := min(width - 4, 60)
    overlay_h := min(height - 4, len(state.detail_lines) + 4) // +4 for borders and title
    start_x := (width - overlay_w) / 2
    start_y := (height - overlay_h) / 2

    // Draw overlay background and border
    for y in start_y..<(start_y + overlay_h) {
        move_cursor(start_x, y)
        if y == start_y {
            // Top border with title
            title_display := truncate_to_width(state.detail_title, overlay_w - 4)
            fmt.printf("\x1b[48;2;30;30;46m\x1b[38;2;228;0;80m┌─ %s ", title_display)
            remaining := overlay_w - 4 - visible_width(title_display)
            for _ in 0..<remaining { fmt.print("─") }
            fmt.print("┐\x1b[0m")
        } else if y == start_y + overlay_h - 1 {
            // Bottom border with dismiss hint
            hint := state.detail_action == .CONFIRM_RESTORE ? " y/Esc " : " Enter/Esc "
            fmt.printf("\x1b[48;2;30;30;46m\x1b[38;2;228;0;80m└")
            remaining := overlay_w - 2 - len(hint)
            for _ in 0..<remaining { fmt.print("─") }
            fmt.printf("%s─┘\x1b[0m", hint)
        } else {
            // Content line
            line_idx := y - start_y - 1
            content := ""
            if line_idx >= 0 && line_idx < len(state.detail_lines) {
                content = state.detail_lines[line_idx]
            }
            padded := truncate_to_width(content, overlay_w - 4)
            pad_len := overlay_w - 4 - visible_width(padded)
            fmt.printf("\x1b[48;2;30;30;46m\x1b[38;2;208;208;208m│ %s", padded)
            for _ in 0..<pad_len { fmt.print(" ") }
            fmt.print(" │\x1b[0m")
        }
    }
}
```

**Integrate into the main render dispatch** (in `src/tui/main.odin` render proc):
```odin
// After rendering the current view, render overlay on top if active
if state.show_detail {
    render_detail_overlay(&state, term_width, term_height)
}
```

**Add overlay event handling** (in the main event loop):
```odin
// In the key event handler, BEFORE view-specific handlers:
if state.show_detail {
    switch key {
    case .ESCAPE, .ENTER:
        if state.detail_action != .CONFIRM_RESTORE {
            clear_detail(&state)
        } else if key == .ESCAPE {
            clear_detail(&state)
        }
    case .CHAR:
        if state.detail_action == .CONFIRM_RESTORE && (ch == 'y' || ch == 'Y') {
            // Extract config type from backup name and restore
            if len(state.backups_cache) > 0 && state.selected_index < len(state.backups_cache) {
                selected := state.backups_cache[state.selected_index]
                parts := strings.split(selected, "_")
                defer delete(parts)
                if len(parts) >= 1 && g_restore_backup != nil {
                    success := g_restore_backup(parts[0])
                    clear_detail(&state)
                    if success {
                        // Reload backups cache
                        state.backups_loaded = false
                    }
                }
            }
        }
    }
    continue  // Don't process other keys while overlay is showing
}
```

### Task 4.3: Add inline fuzzy filter to TUI list views
**File:** `src/tui/views_handlers.odin`
**Test:** manual TUI testing (interactive)
**Depends:** 3.4

**Add '/' key handler to activate filter mode in list views:**

In the key event handler for PATH_VIEW, ALIAS_VIEW, CONSTANTS_VIEW:
```odin
// Add to each list view's key handler section:
case '/':
    if !state.filter_active {
        activate_filter(&state)
        // Populate filtered_items with all current items
        items := get_current_view_items(&state)
        for item in items {
            append(&state.filtered_items, strings.clone(item))
        }
    }
```

**Add filter input handling** (when `state.filter_active` is true):
```odin
// In the main event loop, after overlay check but before view handlers:
if state.filter_active {
    switch key {
    case .ESCAPE:
        deactivate_filter(&state)
        state.selected_index = state.pre_filter_index
    case .ENTER:
        // Accept filter and stay on filtered view
        state.filter_active = false
        // Keep filtered_items active for display
    case .BACKSPACE:
        if len(state.filter_text) > 0 {
            ordered_remove(&state.filter_text, len(state.filter_text) - 1)
            update_tui_filter(&state)
        }
    case .CHAR:
        if ch >= 32 && ch <= 126 {
            append(&state.filter_text, ch)
            update_tui_filter(&state)
        }
    }
    continue
}
```

**Filter update proc:**
```odin
update_tui_filter :: proc(state: ^TUIState) {
    // Clear old filtered items
    for item in state.filtered_items { delete(item) }
    clear(&state.filtered_items)

    // Get source items based on current view
    items := get_current_view_items(state)

    // Apply filter
    for item in items {
        if matches_filter(item, state.filter_text[:]) {
            append(&state.filtered_items, strings.clone(item))
        }
    }

    // Reset selection
    state.selected_index = 0
}

get_current_view_items :: proc(state: ^TUIState) -> []string {
    switch state.current_view {
    case .PATH_VIEW:      return state.path_cache[:]
    case .ALIAS_VIEW:     return state.alias_cache[:]
    case .CONSTANTS_VIEW: return state.constants_cache[:]
    case:                 return {}
    }
}
```

**Render filter bar** (add to views.odin, render at bottom of list views when active):
```odin
render_filter_bar :: proc(state: ^TUIState, y, width: int) {
    if !state.filter_active { return }
    move_cursor(1, y)
    filter_str := string(state.filter_text[:])
    fmt.printf("\x1b[48;2;30;30;46m\x1b[38;2;228;0;80m / \x1b[38;2;208;208;208m%s\x1b[38;2;100;100;100m", filter_str)
    // Show cursor indicator
    fmt.print("_")
    remaining := width - 4 - len(filter_str) - 1
    for _ in 0..<remaining { fmt.print(" ") }
    fmt.print("\x1b[0m")
}
```

---

## Batch 5: Integration Verification (sequential - 1 implementer)

### Task 5.1: Full integration verification
**File:** none (verification only)
**Test:** all test suites
**Depends:** 2.1, 4.1, 4.2, 4.3

**Steps:**
```bash
# 1. Full compilation check
task check

# 2. All unit tests (should be 235+ with new style tests)
task test

# 3. All integration tests
task test:integration

# 4. Full test suite
task test:all

# 5. Build and manual TUI smoke test
task build-dev
./bin/wayu --tui
# Test: Navigate to PATH view, press Enter on an item -> overlay appears
# Test: Press Esc -> overlay dismisses
# Test: Navigate to Backups view, press Enter -> restore confirmation
# Test: Press '/' in PATH view -> filter bar appears
# Test: Type characters -> list filters in real-time
# Test: Press Esc -> filter clears, list restores
# Test: Plugin commands still work
./bin/wayu plugin help
./bin/wayu plugin list
```

**Success criteria:**
- `task check` exits 0
- `task test` passes all tests (235+ unit tests)
- `task test:all` passes all tests (272+ total)
- TUI overlay renders correctly centered
- TUI filter bar appears and filters in real-time
- Plugin decomposition is invisible to users (same behavior)
- No memory leaks (check with defer cleanup patterns)

---

## Risk Assessment

### Task 1: Plugin Decomposition
| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Missing import in new file | Medium | Low | Compiler catches immediately |
| Proc referenced before move | Low | Low | Same package, order doesn't matter in Odin |
| Enable/disable merge breaks edge case | Low | Medium | Existing 16 tests cover both paths |
| Test file needs package adjustment | Low | Low | Tests import from same package |

### Task 2: TUI Enter Key Handlers
| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Overlay renders off-screen on small terminals | Medium | Low | Clamp to terminal dimensions |
| Memory leak in detail_lines | Medium | Medium | Strict defer cleanup pattern |
| Bridge function nil when TUI launched without init | Low | Medium | Nil check before every bridge call |
| Backup restore corrupts config | Low | High | Existing backup system creates backup before restore |
| Cache field names wrong (path_cache vs paths) | Medium | Low | Verify exact field names from state.odin |

### Task 3: Style Extraction + Fuzzy Filter
| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| truncate_to_width has table-specific logic | Low | Medium | Function is already generic |
| align_text change breaks existing styled output | Medium | Medium | Add tests, verify existing tests pass |
| Filter mode conflicts with existing key bindings | Medium | Medium | '/' is unused in list views currently |
| Filter state not cleaned up on view change | Medium | Low | Clear filter in navigate_to_view |

---

## Effort Estimates

| Task | Sub-tasks | Estimated Time | Parallelism |
|------|-----------|---------------|-------------|
| 1. Plugin Decomposition | 5 file moves + merge | 2-3 hours | 5 parallel |
| 2. TUI Enter Handlers | 7 handlers + overlay | 3-4 hours | 3 parallel |
| 3. Style + Fuzzy | 2 extractions + filter | 2-3 hours | 2 parallel |
| Verification | 2 checkpoints | 1 hour | Sequential |
| **Total** | **16 sub-tasks** | **8-11 hours** | **Max 5 parallel** |

---

## Summary of All Files Modified/Created

### New Files
- `src/plugin_registry.odin` — Plugin discovery, config I/O, dependency resolution (~1,160 lines)
- `src/plugin_operations.odin` — Plugin command handlers with merged enable/disable (~950 lines)
- `src/plugin_config.odin` — Plugin loader generation (~210 lines)
- `src/plugin_help.odin` — Plugin help text (~90 lines)
- `tests/unit/test_tui_state.odin` — Tests for new TUI state helpers

### Modified Files
- `src/plugin.odin` — Reduced to types + dispatcher (~300 lines, down from 2,621)
- `src/tui/state.odin` — Add overlay + filter state fields and helpers
- `src/tui/bridge.odin` — Add 4 new bridge function pointers
- `src/tui_bridge_impl.odin` — Implement 4 new bridge functions
- `src/tui/main.odin` — Replace 7 TODO stubs, add overlay event handling
- `src/tui/views.odin` — Add overlay renderer and filter bar renderer
- `src/tui/views_handlers.odin` — Add '/' filter activation and filter input handling
- `src/style.odin` — Move `truncate_to_width` here, fix `align_text` TODO
- `src/table.odin` — Remove `truncate_to_width` (moved to style.odin)
- `tests/unit/test_style.odin` — Add truncation and align_text tests
