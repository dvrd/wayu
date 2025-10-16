name: "PRP-12.6: View Implementations - 8 Interactive TUI Views"
description: |
  Implement all 8 TUI views (Main Menu, PATH, Aliases, Constants, Completions, Backups,
  Plugins, Settings) with full CRUD operations and integration with existing wayu logic.

version: "1.0.0"
parent: "PRP-12_FULL_TUI_MODE_BASE.md"
phase: "6 of 7"
status: "READY_FOR_EXECUTION"

---

## Goal

**Feature Goal**: Implement 8 complete TUI views that provide full interactive access to all wayu functionality with list, add, edit, and remove operations.

**Deliverable**:
- `src/tui/tui_views.odin` with all 8 view render functions
- `src/tui/tui_views_handlers.odin` with event handlers for each view
- `tests/unit/test_tui_views.odin` with view-specific tests
- All views fully functional with existing wayu commands

**Success Definition**:
- All 8 views render correctly
- Can perform CRUD operations in each view
- Views integrate with existing path.odin, alias.odin, etc.
- Keyboard shortcuts work (a=add, d=delete, e=edit, etc.)
- All operations create backups automatically
- Navigation between views works seamlessly

---

## Why

- **Feature Parity**: TUI must support all CLI functionality (PATH, Aliases, Constants, Completions, Backups, Plugins)
- **Discoverability**: TUI makes features visible to users who don't know CLI commands
- **Efficiency**: Interactive operations are faster than typing commands
- **Safety**: Visual confirmation before destructive operations
- **Reuse**: Leverage existing wayu logic from path.odin, alias.odin, constants.odin, etc.

---

## What

### Implementation Tasks

```yaml
Task 1: CREATE src/tui/tui_views.odin
  View Render Functions (8 total):
    - render_main_menu() - 7 menu items with selection
    - render_path_view() - List PATH entries with add/remove
    - render_alias_view() - List aliases with definitions
    - render_constants_view() - List env vars with values
    - render_completions_view() - List completion scripts
    - render_backups_view() - List backups with timestamps
    - render_plugins_view() - List plugins with status
    - render_settings_view() - Configuration options

  Each view includes:
    - Header with view title and help text
    - Scrollable list of items (using scroll_offset)
    - Selected item highlight
    - Footer with keyboard shortcuts
    - Status messages (success/error)

Task 2: CREATE src/tui/tui_views_handlers.odin
  Event Handlers (8 total):
    - handle_main_menu_event()
    - handle_path_event() - Add/remove PATH entries
    - handle_alias_event() - Add/remove/edit aliases
    - handle_constants_event() - Add/remove/edit env vars
    - handle_completions_event() - Add/remove completions
    - handle_backups_event() - List/restore/cleanup backups
    - handle_plugins_event() - Install/remove plugins
    - handle_settings_event() - Change configuration

  Common Patterns:
    - 'a' key: Add new item (open form)
    - 'd' or 'x': Delete selected item (with confirmation)
    - 'e': Edit selected item
    - Enter: View details or activate
    - Esc: Go back to main menu
    - j/k or ↓/↑: Navigate list

Task 3: INTEGRATE with existing wayu logic
  Reuse Functions:
    - path.odin: extract_path_entries(), add_to_path_config(), remove_from_path_config()
    - alias.odin: extract_aliases(), add_alias(), remove_alias()
    - constants.odin: extract_constants(), add_constant(), remove_constant()
    - completions.odin: list_completions(), add_completion(), remove_completion()
    - backup.odin: list_backups(), restore_backup(), cleanup_backups()

  Data Loading:
    - Cache loaded data in state.data_cache map
    - Reload data after modifications
    - Handle errors gracefully with status messages

Task 4: IMPLEMENT interactive forms
  Form Components (reuse form.odin patterns):
    - Input fields for add/edit operations
    - Tab navigation between fields
    - Enter to submit, Esc to cancel
    - Validation before submission

  Forms Needed:
    - Add PATH: Single input (path)
    - Add Alias: Two inputs (name, command)
    - Add Constant: Two inputs (name, value)
    - Add Completion: File picker
    - Settings: Multiple options

Task 5: CREATE tests/unit/test_tui_views.odin
  Tests:
    - test_render_all_views: Each view renders without crash
    - test_view_data_loading: Data loads from config files
    - test_view_selection: Navigation works in each view
    - test_add_operations: Add forms appear and submit
    - test_remove_operations: Deletion with confirmation
```

### Success Criteria

- [ ] All 8 views render correctly
- [ ] Can navigate between views using main menu
- [ ] PATH view: Add/remove entries, see live list
- [ ] Alias view: Add/remove/edit aliases
- [ ] Constants view: Add/remove/edit env vars
- [ ] Completions view: Add/remove completion scripts
- [ ] Backups view: List backups, restore, cleanup
- [ ] Plugins view: List plugins (basic view)
- [ ] Settings view: View configuration
- [ ] All operations create backups automatically
- [ ] Keyboard shortcuts work consistently
- [ ] Error messages display clearly
- [ ] Success messages confirm operations
- [ ] All unit tests pass

---

## All Needed Context

### Documentation References

```yaml
- file: /Users/kakurega/dev/projects/wayu/src/path.odin
  lines: 1-200
  why: PATH entry extraction and manipulation
  pattern: extract_path_entries(), add_to_path_config(), remove_from_path_config()

- file: /Users/kakurega/dev/projects/wayu/src/alias.odin
  lines: 1-200
  why: Alias parsing and management
  pattern: extract_aliases(), add_alias(), remove_alias()

- file: /Users/kakurega/dev/projects/wayu/src/constants.odin
  lines: 1-200
  why: Environment variable management
  pattern: extract_constants(), add_constant(), remove_constant()

- file: /Users/kakurega/dev/projects/wayu/src/completions.odin
  lines: 1-150
  why: Completion script management
  pattern: list_completions(), add_completion(), remove_completion()

- file: /Users/kakurega/dev/projects/wayu/src/backup.odin
  lines: 1-300
  why: Backup system integration
  pattern: list_backups(), restore_backup(), cleanup_backups()

- file: /Users/kakurega/dev/projects/wayu/src/form.odin
  lines: 94-140
  why: Form field navigation pattern
  pattern: Tab navigation, field validation

- file: /Users/kakurega/dev/projects/wayu/src/style.odin
  lines: 273-309
  why: Styled output for status messages
  pattern: print_success(), print_error()
```

### Known Gotchas

```odin
// GOTCHA: Load data into cache, don't query every frame
render_path_view :: proc(state: ^TUIState, screen: ^Screen) {
    // Check if data is cached
    if state.data_cache[.PATH_VIEW] == nil {
        // Load PATH entries
        entries := extract_path_entries(get_shell())
        state.data_cache[.PATH_VIEW] = rawptr(&entries)
    }

    entries := cast(^[]string)state.data_cache[.PATH_VIEW]
    // ... render entries
}

// GOTCHA: Clear cache after modification
handle_path_add :: proc(state: ^TUIState, new_path: string) {
    add_to_path_config(new_path, get_shell())

    // Clear cache to force reload
    if state.data_cache[.PATH_VIEW] != nil {
        free(state.data_cache[.PATH_VIEW])
        delete_key(&state.data_cache, .PATH_VIEW)
    }

    state.needs_refresh = true
}

// GOTCHA: Viewport scrolling for long lists
visible_items := state.terminal_height - 6  // Header + footer
start := state.scroll_offset
end := min(start + visible_items, len(items))

for i in start..<end {
    render_item(screen, items[i], i == state.selected_index)
}

// GOTCHA: Confirmation for destructive operations
if key.char == 'd' {
    // Show confirmation prompt
    state.awaiting_confirmation = true
    state.confirmation_message = "Delete selected item? (y/n)"
    state.needs_refresh = true
}

if state.awaiting_confirmation && key.char == 'y' {
    // Perform deletion
    remove_selected_item(state)
    state.awaiting_confirmation = false
}
```

---

## Implementation Blueprint

### Complete Code Pattern (tui_views.odin)

```odin
package wayu_tui

import "core:fmt"
import "core:strings"
import "../"  // Access main wayu package

// Render PATH configuration view
render_path_view :: proc(state: ^TUIState, screen: ^Screen) {
    // Load data if not cached
    if state.data_cache[.PATH_VIEW] == nil {
        shell := wayu.get_shell()
        entries := wayu.extract_path_entries(shell)
        state.data_cache[.PATH_VIEW] = rawptr(&entries)
    }

    entries := cast(^[]string)state.data_cache[.PATH_VIEW]

    // Header
    render_text(screen, 2, 1, "PATH Configuration")
    render_text(screen, 2, 2, fmt.tprintf("%d entries", len(entries^)))

    // List items with scrolling
    visible_height := state.terminal_height - 6
    start := state.scroll_offset
    end := min(start + visible_height, len(entries^))

    for i in start..<end {
        y := 4 + (i - start)
        entry := entries^[i]

        if i == state.selected_index {
            // Highlight selected
            render_text(screen, 2, y, fmt.tprintf("> %s", entry))
        } else {
            render_text(screen, 4, y, entry)
        }
    }

    // Footer with shortcuts
    footer_y := state.terminal_height - 2
    render_text(screen, 2, footer_y, "a=Add  d=Delete  Esc=Back  ↑/↓=Navigate")
}

// Render Alias view
render_alias_view :: proc(state: ^TUIState, screen: ^Screen) {
    // Load aliases if not cached
    if state.data_cache[.ALIAS_VIEW] == nil {
        shell := wayu.get_shell()
        aliases := wayu.extract_aliases(shell)
        state.data_cache[.ALIAS_VIEW] = rawptr(&aliases)
    }

    aliases := cast(^map[string]string)state.data_cache[.ALIAS_VIEW]

    // Header
    render_text(screen, 2, 1, "Aliases")
    render_text(screen, 2, 2, fmt.tprintf("%d aliases", len(aliases^)))

    // Convert map to sorted list for display
    alias_list := make([dynamic]string)
    defer delete(alias_list)

    for name, cmd in aliases^ {
        append(&alias_list, fmt.tprintf("%s = %s", name, cmd))
    }

    // List items with scrolling
    visible_height := state.terminal_height - 6
    start := state.scroll_offset
    end := min(start + visible_height, len(alias_list))

    for i in start..<end {
        y := 4 + (i - start)
        item := alias_list[i]

        if i == state.selected_index {
            render_text(screen, 2, y, fmt.tprintf("> %s", item))
        } else {
            render_text(screen, 4, y, item)
        }
    }

    // Footer
    footer_y := state.terminal_height - 2
    render_text(screen, 2, footer_y, "a=Add  d=Delete  e=Edit  Esc=Back")
}

// Render Constants view
render_constants_view :: proc(state: ^TUIState, screen: ^Screen) {
    // Load constants if not cached
    if state.data_cache[.CONSTANTS_VIEW] == nil {
        shell := wayu.get_shell()
        constants := wayu.extract_constants(shell)
        state.data_cache[.CONSTANTS_VIEW] = rawptr(&constants)
    }

    constants := cast(^map[string]string)state.data_cache[.CONSTANTS_VIEW]

    // Header
    render_text(screen, 2, 1, "Environment Constants")
    render_text(screen, 2, 2, fmt.tprintf("%d constants", len(constants^)))

    // Convert to list
    const_list := make([dynamic]string)
    defer delete(const_list)

    for name, value in constants^ {
        append(&const_list, fmt.tprintf("%s = \"%s\"", name, value))
    }

    // List with scrolling
    visible_height := state.terminal_height - 6
    start := state.scroll_offset
    end := min(start + visible_height, len(const_list))

    for i in start..<end {
        y := 4 + (i - start)
        item := const_list[i]

        if i == state.selected_index {
            render_text(screen, 2, y, fmt.tprintf("> %s", item))
        } else {
            render_text(screen, 4, y, item)
        }
    }

    // Footer
    footer_y := state.terminal_height - 2
    render_text(screen, 2, footer_y, "a=Add  d=Delete  e=Edit  Esc=Back")
}

// Render Backups view
render_backups_view :: proc(state: ^TUIState, screen: ^Screen) {
    // Load backups if not cached
    if state.data_cache[.BACKUPS_VIEW] == nil {
        backups := wayu.list_backups("all")
        state.data_cache[.BACKUPS_VIEW] = rawptr(&backups)
    }

    backups := cast(^[]wayu.BackupInfo)state.data_cache[.BACKUPS_VIEW]

    // Header
    render_text(screen, 2, 1, "Backups")
    render_text(screen, 2, 2, fmt.tprintf("%d backups available", len(backups^)))

    // List backups
    visible_height := state.terminal_height - 6
    start := state.scroll_offset
    end := min(start + visible_height, len(backups^))

    for i in start..<end {
        y := 4 + (i - start)
        backup := backups^[i]

        display := fmt.tprintf("%s - %s", backup.timestamp, backup.config_type)

        if i == state.selected_index {
            render_text(screen, 2, y, fmt.tprintf("> %s", display))
        } else {
            render_text(screen, 4, y, display)
        }
    }

    // Footer
    footer_y := state.terminal_height - 2
    render_text(screen, 2, footer_y, "r=Restore  c=Cleanup  Esc=Back")
}

// Placeholder for Completions view
render_completions_view :: proc(state: ^TUIState, screen: ^Screen) {
    render_text(screen, 2, 1, "Completions")
    render_text(screen, 2, 3, "Completion scripts management")
    footer_y := state.terminal_height - 2
    render_text(screen, 2, footer_y, "a=Add  d=Delete  Esc=Back")
}

// Placeholder for Plugins view
render_plugins_view :: proc(state: ^TUIState, screen: ^Screen) {
    render_text(screen, 2, 1, "Plugins")
    render_text(screen, 2, 3, "Plugin management (future feature)")
    footer_y := state.terminal_height - 2
    render_text(screen, 2, footer_y, "Esc=Back")
}

// Settings view
render_settings_view :: proc(state: ^TUIState, screen: ^Screen) {
    render_text(screen, 2, 1, "Settings")
    render_text(screen, 2, 3, "wayu Configuration")

    settings := []string{
        fmt.tprintf("Shell: %v", wayu.get_shell()),
        fmt.tprintf("Config Dir: %s", wayu.WAYU_CONFIG),
        fmt.tprintf("Backup Retention: 5 (last 5 backups kept)"),
    }

    for setting, i in settings {
        render_text(screen, 4, 5 + i, setting)
    }

    footer_y := state.terminal_height - 2
    render_text(screen, 2, footer_y, "Esc=Back")
}
```

### Complete Code Pattern (tui_views_handlers.odin)

```odin
package wayu_tui

import "core:fmt"
import "../"  // Access main wayu package

// Handle PATH view events
handle_path_event :: proc(state: ^TUIState, key: KeyEvent) {
    switch key.char {
    case 'a':
        // TODO: Open add form
        show_add_path_form(state)

    case 'd', 'x':
        // Delete selected PATH entry
        if state.data_cache[.PATH_VIEW] != nil {
            entries := cast(^[]string)state.data_cache[.PATH_VIEW]
            if state.selected_index >= 0 && state.selected_index < len(entries^) {
                selected_entry := entries^[state.selected_index]

                // Remove from config
                shell := wayu.get_shell()
                wayu.remove_from_path_config(selected_entry, shell)

                // Clear cache to reload
                free(state.data_cache[.PATH_VIEW])
                delete_key(&state.data_cache, .PATH_VIEW)

                state.needs_refresh = true
            }
        }
    }
}

// Handle Alias view events
handle_alias_event :: proc(state: ^TUIState, key: KeyEvent) {
    switch key.char {
    case 'a':
        show_add_alias_form(state)

    case 'd', 'x':
        // Delete selected alias
        if state.data_cache[.ALIAS_VIEW] != nil {
            aliases := cast(^map[string]string)state.data_cache[.ALIAS_VIEW]

            // Get alias name at selected index
            alias_names := make([dynamic]string)
            defer delete(alias_names)

            for name in aliases^ {
                append(&alias_names, name)
            }

            if state.selected_index >= 0 && state.selected_index < len(alias_names) {
                selected_name := alias_names[state.selected_index]

                // Remove from config
                shell := wayu.get_shell()
                wayu.remove_alias(selected_name, shell)

                // Clear cache
                free(state.data_cache[.ALIAS_VIEW])
                delete_key(&state.data_cache, .ALIAS_VIEW)

                state.needs_refresh = true
            }
        }

    case 'e':
        // Edit selected alias
        // TODO: Open edit form with current values
    }
}

// Handle Constants view events
handle_constants_event :: proc(state: ^TUIState, key: KeyEvent) {
    switch key.char {
    case 'a':
        show_add_constant_form(state)

    case 'd', 'x':
        // Delete selected constant
        if state.data_cache[.CONSTANTS_VIEW] != nil {
            constants := cast(^map[string]string)state.data_cache[.CONSTANTS_VIEW]

            const_names := make([dynamic]string)
            defer delete(const_names)

            for name in constants^ {
                append(&const_names, name)
            }

            if state.selected_index >= 0 && state.selected_index < len(const_names) {
                selected_name := const_names[state.selected_index]

                shell := wayu.get_shell()
                wayu.remove_constant(selected_name, shell)

                free(state.data_cache[.CONSTANTS_VIEW])
                delete_key(&state.data_cache, .CONSTANTS_VIEW)

                state.needs_refresh = true
            }
        }
    }
}

// Handle Backups view events
handle_backups_event :: proc(state: ^TUIState, key: KeyEvent) {
    switch key.char {
    case 'r':
        // Restore selected backup
        if state.data_cache[.BACKUPS_VIEW] != nil {
            backups := cast(^[]wayu.BackupInfo)state.data_cache[.BACKUPS_VIEW]

            if state.selected_index >= 0 && state.selected_index < len(backups^) {
                backup := backups^[state.selected_index]

                // Restore backup
                wayu.restore_backup(backup.config_type)

                // Show success message
                state.status_message = fmt.tprintf("Restored %s from %s",
                    backup.config_type, backup.timestamp)
                state.needs_refresh = true
            }
        }

    case 'c':
        // Cleanup old backups
        wayu.cleanup_backups(5)  // Keep last 5

        // Clear cache
        free(state.data_cache[.BACKUPS_VIEW])
        delete_key(&state.data_cache, .BACKUPS_VIEW)

        state.status_message = "Cleaned up old backups"
        state.needs_refresh = true
    }
}

// Form helpers (simplified, full implementation in Phase 7)
show_add_path_form :: proc(state: ^TUIState) {
    // TODO: Implement interactive form
    // For now, placeholder
    state.status_message = "Add PATH form (TODO)"
    state.needs_refresh = true
}

show_add_alias_form :: proc(state: ^TUIState) {
    state.status_message = "Add Alias form (TODO)"
    state.needs_refresh = true
}

show_add_constant_form :: proc(state: ^TUIState) {
    state.status_message = "Add Constant form (TODO)"
    state.needs_refresh = true
}
```

---

## Validation Loop

### Level 1: Compilation

```bash
odin build src/tui -out:bin/tui_test -debug
# Expected: Zero errors
```

### Level 2: Unit Tests

```bash
odin test tests/unit/test_tui_views.odin -file
# Expected: All tests pass
```

### Level 3: Interactive Testing

```bash
# Test each view manually
./bin/wayu --tui

# Test PATH view:
# 1. Navigate to "PATH Configuration"
# 2. Press Enter
# 3. Verify PATH entries display
# 4. Press 'd' to delete an entry
# 5. Press Esc to go back

# Test Alias view:
# 1. Navigate to "Aliases"
# 2. Press Enter
# 3. Verify aliases display
# 4. Test navigation with j/k

# Test Backups view:
# 1. Navigate to "Backups"
# 2. Verify backups list
# 3. Test restore (r key)

# Expected: All views work, no crashes
```

### Level 4: Data Integrity

```bash
# Verify TUI modifications match CLI
./bin/wayu --tui
# Delete a PATH entry via TUI

./bin/wayu path list
# Verify entry is deleted

./bin/wayu backup list
# Verify backup was created

# Expected: TUI and CLI produce identical results
```

---

## Final Validation Checklist

- [ ] All 8 views compile without errors
- [ ] PATH view: Lists entries, delete works
- [ ] Alias view: Lists aliases, delete works
- [ ] Constants view: Lists env vars, delete works
- [ ] Completions view: Basic view renders
- [ ] Backups view: Lists backups, restore works
- [ ] Plugins view: Basic view renders
- [ ] Settings view: Displays configuration
- [ ] Navigation between views works
- [ ] Data loads correctly from config files
- [ ] Modifications create backups
- [ ] Cache invalidation works after changes
- [ ] Viewport scrolling works for long lists
- [ ] Keyboard shortcuts consistent across views
- [ ] No memory leaks in view rendering
- [ ] All unit tests pass

---

**Status**: ✅ READY FOR EXECUTION
**Estimated Time**: 6-8 hours
**Dependencies**: Phase 5 (Main Loop) MUST be complete
**Confidence**: 8/10

**Note**: Add/Edit forms are simplified in this phase. Full form implementation can be polished in Phase 7.
