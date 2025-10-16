name: "PRP-12.5: Main TUI Loop - The Elm Architecture Event Loop"
description: |
  Implement main TUI event loop using The Elm Architecture (TEA) pattern with render → input →
  update cycle, integrate with main.odin via --tui flag, and handle graceful cleanup.

version: "1.0.0"
parent: "PRP-12_FULL_TUI_MODE_BASE.md"
phase: "5 of 7"
status: "READY_FOR_EXECUTION"

---

## Goal

**Feature Goal**: Implement core TUI event loop following The Elm Architecture (TEA) pattern that coordinates terminal initialization, event polling, state updates, and screen rendering.

**Deliverable**:
- `src/tui/tui_main.odin` with tui_run() event loop
- Integration with `src/main.odin` via --tui flag
- `tests/unit/test_tui_main.odin` with unit tests
- Graceful cleanup on Ctrl+C and errors

**Success Definition**:
- tui_run() orchestrates full render → input → update → render cycle
- --tui flag launches TUI mode from CLI
- Ctrl+C exits cleanly (restores terminal state)
- Terminal state cleanup happens even on panic
- All unit tests pass

---

## Why

- **Orchestration**: Coordinates Terminal, Events, Screen, and State subsystems
- **Pattern**: TEA (Model-Update-View) provides predictable state flow
- **Integration**: Seamless CLI → TUI transition without breaking existing commands
- **Safety**: Must handle crashes gracefully to avoid leaving terminal in raw mode
- **Reuse Pattern**: Similar to fuzzy.odin's event loop (lines 753-821)

---

## What

### Implementation Tasks

```yaml
Task 1: CREATE src/tui/tui_main.odin
  Components:
    - tui_run() - Main event loop entry point
    - tui_init() - Initialize all subsystems
    - tui_cleanup() - Cleanup all subsystems
    - tui_handle_event() - Process events and update state
    - tui_render() - Render current state to screen

  Event Loop Structure (The Elm Architecture):
    1. Initialize: Terminal + State + Screen
    2. Render: Draw current state
    3. Poll: Get keyboard/resize events
    4. Update: Modify state based on event
    5. Check: Exit condition or loop back to step 2
    6. Cleanup: Restore terminal (in defer)

Task 2: INTEGRATE with src/main.odin
  Changes:
    - Add --tui flag to Command struct
    - Parse --tui flag in parse_arguments()
    - Call tui_run() if --tui flag present
    - Fallback to existing CLI if flag absent

  Backward Compatibility:
    - No changes to existing CLI behavior
    - --tui is opt-in only
    - All existing tests must pass

Task 3: HANDLE graceful cleanup
  Scenarios:
    - Normal exit (user pressed q or Esc from main menu)
    - Ctrl+C (SIGINT) signal
    - Panic or runtime error
    - Terminal resize during operation

  Solution:
    - defer tui_cleanup() immediately after tui_init()
    - SIGINT handler sets state.running = false
    - Panic recovery (if needed) calls cleanup

Task 4: CREATE tests/unit/test_tui_main.odin
  Tests:
    - test_tui_init: All subsystems initialize correctly
    - test_tui_cleanup: Resources freed properly
    - test_event_handling: Events update state correctly
    - test_render_cycle: Rendering doesn't crash
```

### Success Criteria

- [ ] tui_run() successfully initializes all subsystems
- [ ] Event loop completes one full cycle without crash
- [ ] Ctrl+C exits cleanly and restores terminal
- [ ] --tui flag launches TUI from main.odin
- [ ] Existing CLI commands still work (no regression)
- [ ] defer ensures cleanup even on panic
- [ ] All unit tests pass
- [ ] Terminal never left in raw mode after exit

---

## All Needed Context

### Documentation References

```yaml
- file: /Users/kakurega/dev/projects/wayu/src/fuzzy.odin
  lines: 753-821
  why: Event loop structure with raw mode lifecycle
  pattern: init → defer cleanup → loop (render → input → update)

- file: /Users/kakurega/dev/projects/wayu/src/form.odin
  lines: 54-73
  why: form_run lifecycle pattern
  pattern: enable_raw_mode, defer disable_raw_mode

- file: /Users/kakurega/dev/projects/wayu/src/main.odin
  lines: 1-150
  why: Argument parsing and command dispatch
  pattern: parse_arguments() returns Command struct

- docfile: /Users/kakurega/dev/projects/wayu/docs/references/TUI_DESIGN_PATTERNS.md
  section: "The Elm Architecture (TEA)"
  why: Model-Update-View pattern
  critical: State transitions are pure functions, side effects isolated
```

### Known Gotchas

```odin
// GOTCHA: Always defer cleanup immediately after init
tui_init()
defer tui_cleanup()  // Runs even on panic

// GOTCHA: Check terminal_resized flag each iteration
for state.running {
    if terminal_resized {
        width, height, _ := get_terminal_size()
        screen_resize(&screen, width, height)
        terminal_resized = false
    }

    // ... rest of loop
}

// GOTCHA: Handle no-input case (non-blocking read)
event := poll_event()
if event == nil {
    // No input available, continue to next iteration
    continue
}

// GOTCHA: Screen flush is expensive, only when needed
if state.needs_refresh {
    tui_render(&state, &screen)
    screen_flush(&screen)
    state.needs_refresh = false
}
```

---

## Implementation Blueprint

### Complete Code Pattern (tui_main.odin)

```odin
package wayu_tui

import "core:fmt"
import "core:os"
import "../"  // Access main wayu package

// Main TUI entry point
tui_run :: proc() {
    // Initialize all subsystems
    tui_init()
    defer tui_cleanup()

    // Get initial terminal size
    width, height, ok := get_terminal_size()
    if !ok {
        width, height = 80, 24  // Fallback
    }

    // Create screen buffer
    screen := screen_create(width, height)
    defer screen_destroy(&screen)

    // Initialize state machine
    state := tui_state_init()
    state.terminal_width = width
    state.terminal_height = height
    defer tui_state_destroy(&state)

    // Main event loop (The Elm Architecture)
    for state.running {
        // Handle terminal resize
        if terminal_resized {
            new_width, new_height, _ := get_terminal_size()
            screen_resize(&screen, new_width, new_height)
            state.terminal_width = new_width
            state.terminal_height = new_height
            state.needs_refresh = true
            terminal_resized = false
        }

        // Render current state
        if state.needs_refresh {
            tui_render(&state, &screen)
            screen_flush(&screen)
            state.needs_refresh = false
        }

        // Poll for events (non-blocking)
        event := poll_event()
        if event == nil {
            continue  // No input, loop again
        }

        // Update state based on event
        tui_handle_event(&state, event)
    }
}

// Initialize TUI subsystems
tui_init :: proc() {
    tui_lifecycle_init()  // Enter alt screen, hide cursor, setup signals
    enable_raw_mode()     // Enable raw terminal input
}

// Cleanup TUI subsystems
tui_cleanup :: proc() {
    disable_raw_mode()         // Restore cooked mode
    tui_lifecycle_cleanup()    // Exit alt screen, show cursor
}

// Handle single event and update state
tui_handle_event :: proc(state: ^TUIState, event: Event) {
    #partial switch e in event {
    case KeyEvent:
        handle_key_event(state, e)
    case ResizeEvent:
        // Already handled in main loop via terminal_resized flag
    }
}

// Handle keyboard events
handle_key_event :: proc(state: ^TUIState, key: KeyEvent) {
    // Global keys (work in all views)
    if key.modifiers & {.Ctrl} && key.char == 'c' {
        state.running = false
        return
    }

    if key.key == .Escape && state.current_view == .MAIN_MENU {
        state.running = false  // Quit from main menu
        return
    }

    // Navigation keys
    switch key.key {
    case .Up, .Char:
        if key.char == 'k' || key.key == .Up {
            item_count := get_view_item_count(state)
            tui_state_move_selection(state, -1, item_count)
        }

    case .Down:
        if key.char == 'j' || key.key == .Down {
            item_count := get_view_item_count(state)
            tui_state_move_selection(state, 1, item_count)
        }

    case .Enter:
        handle_selection(state)

    case .Escape:
        if state.current_view != .MAIN_MENU {
            tui_state_go_back(state)
        }
    }
}

// Handle selection in current view
handle_selection :: proc(state: ^TUIState) {
    switch state.current_view {
    case .MAIN_MENU:
        // Navigate to selected view
        menu_items := []TUIView{
            .PATH_VIEW,
            .ALIAS_VIEW,
            .CONSTANTS_VIEW,
            .COMPLETIONS_VIEW,
            .BACKUPS_VIEW,
            .PLUGINS_VIEW,
            .SETTINGS_VIEW,
        }
        if state.selected_index >= 0 && state.selected_index < len(menu_items) {
            tui_state_goto_view(state, menu_items[state.selected_index])
        }

    case .PATH_VIEW:
        // TODO: Implement PATH-specific selection (Phase 6)

    case .ALIAS_VIEW:
        // TODO: Implement Alias-specific selection (Phase 6)

    // ... other views
    }
}

// Render current state to screen
tui_render :: proc(state: ^TUIState, screen: ^Screen) {
    // Clear screen
    screen_clear(screen)

    // Render based on current view
    switch state.current_view {
    case .MAIN_MENU:
        render_main_menu(state, screen)

    case .PATH_VIEW:
        render_path_view(state, screen)

    case .ALIAS_VIEW:
        render_alias_view(state, screen)

    // ... other views (will be implemented in Phase 6)
    }
}

// Render main menu
render_main_menu :: proc(state: ^TUIState, screen: ^Screen) {
    // Header
    render_text(screen, 2, 1, "wayu - Shell Configuration Manager")
    render_text(screen, 2, 2, "Press Esc or q to quit")

    // Menu items
    menu_items := []string{
        "1. PATH Configuration",
        "2. Aliases",
        "3. Environment Constants",
        "4. Completions",
        "5. Backups",
        "6. Plugins",
        "7. Settings",
    }

    for item, i in menu_items {
        y := 4 + i
        if i == state.selected_index {
            // Highlight selected item
            render_text(screen, 2, y, fmt.tprintf("> %s", item))
        } else {
            render_text(screen, 2, y, fmt.tprintf("  %s", item))
        }
    }

    // Footer
    footer_y := state.terminal_height - 2
    render_text(screen, 2, footer_y, "Use ↑/↓ or j/k to navigate, Enter to select")
}

// Placeholder for PATH view (implemented in Phase 6)
render_path_view :: proc(state: ^TUIState, screen: ^Screen) {
    render_text(screen, 2, 1, "PATH Configuration (TODO: Phase 6)")
}

// Placeholder for Alias view (implemented in Phase 6)
render_alias_view :: proc(state: ^TUIState, screen: ^Screen) {
    render_text(screen, 2, 1, "Alias Configuration (TODO: Phase 6)")
}
```

### Integration with main.odin

```odin
// In src/main.odin, add TUI flag to Command struct
Command :: struct {
    action: Action,
    args:   []string,
    shell:  Shell,
    tui:    bool,  // NEW: TUI mode flag
}

// In parse_arguments(), check for --tui flag
parse_arguments :: proc(args: []string) -> Command {
    // ... existing parsing logic ...

    tui_flag := false
    for arg in args {
        if arg == "--tui" {
            tui_flag = true
            break
        }
    }

    return Command{
        action = action,
        args = cmd_args,
        shell = shell,
        tui = tui_flag,
    }
}

// In main(), check TUI flag
main :: proc() {
    // ... existing setup ...

    command := parse_arguments(os.args[1:])

    // Launch TUI if flag present
    if command.tui {
        import "tui"
        tui.tui_run()
        return
    }

    // ... existing CLI logic ...
}
```

---

## Validation Loop

### Level 1: Compilation

```bash
# Compile TUI package
odin build src/tui -out:bin/tui_test -debug
# Expected: Zero errors

# Compile main with TUI integration
odin build src -out:bin/wayu_tui -debug
# Expected: Zero errors
```

### Level 2: Unit Tests

```bash
# Run TUI main tests
odin test tests/unit/test_tui_main.odin -file
# Expected: All tests pass

# Run ALL existing tests to check for regression
task test:all
# Expected: All 255 tests still pass
```

### Level 3: Manual TUI Launch

```bash
# Launch TUI mode
./bin/wayu --tui
# Expected:
# - Alternate screen buffer activates
# - Main menu appears with 7 items
# - Arrow keys move selection
# - Esc quits cleanly
# - Terminal restored to normal state

# Test Ctrl+C handling
./bin/wayu --tui
# Press Ctrl+C
# Expected: Clean exit, terminal restored

# Test existing CLI still works
./bin/wayu path list
# Expected: Normal CLI output (no TUI)
```

### Level 4: Integration Test

```bash
# Create integration test
cat > tests/integration/test_tui_launch.sh <<'EOF'
#!/bin/bash

# Test TUI can be launched without crash
timeout 2s ./bin/wayu --tui <<EOF2
q
EOF2

if [ $? -eq 0 ]; then
    echo "✓ TUI launch test passed"
else
    echo "✗ TUI launch test failed"
    exit 1
fi
EOF

chmod +x tests/integration/test_tui_launch.sh
./tests/integration/test_tui_launch.sh
# Expected: Test passes
```

---

## Final Validation Checklist

- [ ] Compiles without errors
- [ ] tui_run() initializes and enters event loop
- [ ] Main menu renders correctly
- [ ] Arrow keys navigate menu items
- [ ] Enter key responds (even if views not implemented yet)
- [ ] Esc from main menu exits cleanly
- [ ] Ctrl+C exits cleanly
- [ ] Terminal state restored after exit
- [ ] --tui flag launches TUI from CLI
- [ ] CLI still works without --tui flag (no regression)
- [ ] All 255 existing tests still pass
- [ ] defer ensures cleanup on panic
- [ ] No memory leaks

---

**Status**: ✅ READY FOR EXECUTION
**Estimated Time**: 3-4 hours
**Dependencies**: Phases 1-4 MUST be complete (Terminal, Events, Screen, State)
**Confidence**: 9/10

**Critical Path**: This phase MUST complete before Phase 6 (Views) can begin.
