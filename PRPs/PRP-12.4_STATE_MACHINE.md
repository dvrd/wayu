name: "PRP-12.4: State Machine - View Navigation and State Management"
description: |
  Implement TUI state machine with view enum, navigation stack, and state transitions
  for managing current view, selection, and scroll position.

version: "1.0.0"
parent: "PRP-12_FULL_TUI_MODE_BASE.md"
phase: "4 of 7"
status: "READY_FOR_EXECUTION"

---

## Goal

**Feature Goal**: Implement state management system for TUI navigation between 8 views (Main Menu, PATH, Aliases, Constants, Completions, Backups, Plugins, Settings) with back navigation and selection tracking.

**Deliverable**:
- `src/tui/tui_state.odin` with TUIState struct, TUIView enum, state transition functions
- `tests/unit/test_tui_state.odin` with unit tests
- All state transitions work correctly, tests pass

**Success Definition**:
- Can initialize state (starts at MAIN_MENU)
- Can navigate to any view and back
- Can track selection and scroll offset
- Selection wraps around at boundaries
- All unit tests pass

---

## Why

- **Navigation**: Users need to move between views (Main Menu ↔ PATH view ↔ Add form)
- **State Tracking**: Must remember which item is selected, scroll position
- **Back Button**: Users expect Esc/← to return to previous view
- **Reuse Pattern**: Similar to fuzzy.odin's FuzzyView state (lines 110-133)

---

## What

### Implementation Tasks

```yaml
Task 1: CREATE src/tui/tui_state.odin
  Types:
    - TUIView enum (MAIN_MENU, PATH_VIEW, ALIAS_VIEW, etc.)
    - TUIState struct (current_view, previous_view, selected_index, scroll_offset, etc.)

  Functions:
    - tui_state_init() -> TUIState (starts at MAIN_MENU, selected_index=0)
    - tui_state_destroy(state: ^TUIState) - free data_cache map
    - tui_state_goto_view(state: ^TUIState, view: TUIView) - change view
    - tui_state_go_back(state: ^TUIState) - return to previous view
    - tui_state_move_selection(state: ^TUIState, delta: int) - move up/down with wrap

Task 2: CREATE tests/unit/test_tui_state.odin
  Tests:
    - test_state_init: Starts at MAIN_MENU, selected_index=0
    - test_goto_view: Transitions to new view, tracks previous_view
    - test_go_back: Returns to previous view
    - test_move_selection: Up/down movement, wraps at boundaries
    - test_scroll_update: scroll_offset follows selection
```

### Success Criteria

- [ ] tui_state_init() creates valid initial state
- [ ] goto_view() transitions correctly and tracks previous view
- [ ] go_back() restores previous view
- [ ] move_selection() handles up/down with wrap-around
- [ ] scroll_offset updates to keep selection visible
- [ ] All unit tests pass
- [ ] No memory leaks (data_cache cleaned up)

---

## All Needed Context

### Documentation References

```yaml
- file: /Users/kakurega/dev/projects/wayu/src/fuzzy.odin
  lines: 110-133
  why: FuzzyView struct pattern
  pattern: selected_index, scroll_offset, visible_items

- docfile: /Users/kakurega/dev/projects/wayu/docs/references/TUI_DESIGN_PATTERNS.md
  section: "The Elm Architecture (TEA)"
  why: Model-Update-View pattern for state management
  critical: State is immutable, transitions create new state
```

### Known Gotchas

```odin
// GOTCHA: Selection wrapping at boundaries
state.selected_index += delta
if state.selected_index < 0 {
    state.selected_index = item_count - 1  // Wrap to end
} else if state.selected_index >= item_count {
    state.selected_index = 0  // Wrap to start
}

// GOTCHA: Scroll follows selection
visible_height := state.terminal_height - 6  // Account for header/footer
if state.selected_index < state.scroll_offset {
    state.scroll_offset = state.selected_index
} else if state.selected_index >= state.scroll_offset + visible_height {
    state.scroll_offset = state.selected_index - visible_height + 1
}

// GOTCHA: Clean up data_cache map
for key, value in state.data_cache {
    // Free cached data based on view type
    free(value)
}
delete(state.data_cache)
```

---

## Implementation Blueprint

### Complete Code Pattern

```odin
package wayu_tui

TUIView :: enum {
    MAIN_MENU,
    PATH_VIEW,
    ALIAS_VIEW,
    CONSTANTS_VIEW,
    COMPLETIONS_VIEW,
    BACKUPS_VIEW,
    PLUGINS_VIEW,
    SETTINGS_VIEW,
}

TUIState :: struct {
    current_view:    TUIView,
    previous_view:   TUIView,
    selected_index:  int,
    scroll_offset:   int,
    terminal_width:  int,
    terminal_height: int,
    needs_refresh:   bool,
    running:         bool,
    data_cache:      map[TUIView]rawptr,
}

// Initialize TUI state
tui_state_init :: proc() -> TUIState {
    return TUIState{
        current_view = .MAIN_MENU,
        previous_view = .MAIN_MENU,
        selected_index = 0,
        scroll_offset = 0,
        terminal_width = 80,
        terminal_height = 24,
        needs_refresh = true,
        running = true,
        data_cache = make(map[TUIView]rawptr),
    }
}

// Destroy state and free resources
tui_state_destroy :: proc(state: ^TUIState) {
    // Free cached data
    for key, value in state.data_cache {
        if value != nil {
            free(value)
        }
    }
    delete(state.data_cache)
}

// Go to new view
tui_state_goto_view :: proc(state: ^TUIState, view: TUIView) {
    state.previous_view = state.current_view
    state.current_view = view
    state.selected_index = 0
    state.scroll_offset = 0
    state.needs_refresh = true
}

// Go back to previous view
tui_state_go_back :: proc(state: ^TUIState) {
    temp := state.current_view
    state.current_view = state.previous_view
    state.previous_view = temp
    state.selected_index = 0
    state.scroll_offset = 0
    state.needs_refresh = true
}

// Move selection up/down
tui_state_move_selection :: proc(state: ^TUIState, delta: int, item_count: int) {
    if item_count == 0 do return

    state.selected_index += delta

    // Wrap around at boundaries
    if state.selected_index < 0 {
        state.selected_index = item_count - 1
    } else if state.selected_index >= item_count {
        state.selected_index = 0
    }

    // Update scroll offset to keep selection visible
    visible_height := state.terminal_height - 6  // Header + footer

    if state.selected_index < state.scroll_offset {
        // Scrolled above visible area
        state.scroll_offset = state.selected_index
    } else if state.selected_index >= state.scroll_offset + visible_height {
        // Scrolled below visible area
        state.scroll_offset = state.selected_index - visible_height + 1
    }

    state.needs_refresh = true
}

// Get item count for current view (helper)
get_view_item_count :: proc(state: ^TUIState) -> int {
    switch state.current_view {
    case .MAIN_MENU:
        return 7  // 7 menu items
    case .PATH_VIEW:
        // Get from cached data or query
        return 10  // Placeholder
    case .ALIAS_VIEW:
        return 8  // Placeholder
    // ... other views
    }
    return 0
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
odin test tests/unit/test_tui_state.odin -file
# Expected: All tests pass
```

### Level 3: State Transition Test

```odin
// Test state machine transitions
state := tui_state_init()
assert(state.current_view == .MAIN_MENU)

tui_state_goto_view(&state, .PATH_VIEW)
assert(state.current_view == .PATH_VIEW)
assert(state.previous_view == .MAIN_MENU)

tui_state_go_back(&state)
assert(state.current_view == .MAIN_MENU)

// Test selection movement
tui_state_move_selection(&state, 1, 7)  // Down 1 (7 items)
assert(state.selected_index == 1)

tui_state_move_selection(&state, 10, 7)  // Down 10 (wraps)
assert(state.selected_index == 4)  // (1 + 10) % 7 = 4

tui_state_destroy(&state)
```

---

## Final Validation Checklist

- [ ] Compiles without errors
- [ ] All unit tests pass
- [ ] State initializes to MAIN_MENU
- [ ] goto_view() changes current view
- [ ] previous_view tracked correctly
- [ ] go_back() restores previous view
- [ ] move_selection() handles delta correctly
- [ ] Selection wraps at boundaries
- [ ] scroll_offset updates with selection
- [ ] data_cache cleaned up on destroy
- [ ] No memory leaks

---

**Status**: ✅ READY FOR EXECUTION
**Estimated Time**: 1-2 hours
**Dependencies**: None (independent of Phase 1-3)
**Confidence**: 10/10
