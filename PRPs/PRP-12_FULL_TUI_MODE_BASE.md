name: "PRP-12: Full TUI Mode - Complete Interactive Terminal Interface"
description: |
  Transform wayu from CLI-first tool into dual-mode application with full-screen Terminal User
  Interface (TUI) while preserving existing CLI functionality.

version: "1.0.0"
created: "2025-10-16"
status: "READY_FOR_IMPLEMENTATION"

---

## Goal

**Feature Goal**: Implement a full-screen Terminal User Interface (TUI) that allows users to interactively manage all wayu configuration features (PATH, aliases, constants, completions, backups, plugins) through visual navigation and keyboard-driven workflows.

**Deliverable**:
- Dual-mode wayu application: `wayu` (no args) launches TUI, `wayu <command>` uses CLI
- Complete TUI framework with view system, event loop, and screen management
- 7 interactive views: Main Menu, PATH, Aliases, Constants, Completions, Backups, Settings
- Zero CLI regressions - all existing commands work unchanged

**Success Definition**:
- New users can navigate and use wayu without reading documentation
- Power users can still use CLI for scripting and automation
- TUI feels responsive (< 50ms input lag) and polished
- All manual tests in "Final Validation Checklist" pass
- Zero existing integration/unit test failures

---

## User Persona

**Target User**: Shell configuration users (developers, DevOps, power users)

**Use Case**:
- **Primary**: New user discovers wayu, runs `wayu`, immediately sees all features in menu
- **Secondary**: Existing user prefers visual interface for complex operations (backup restore, multi-entry management)
- **Tertiary**: Power user scripts with CLI but occasionally uses TUI for exploration

**User Journey**:
```
1. User runs: wayu
2. TUI shows main menu with 7 categories (PATH, Aliases, etc.)
3. User navigates with j/k or arrow keys
4. User presses Enter on "PATH Management"
5. PATH view shows all entries with status indicators (✓exists, ✗missing, ⚠duplicate)
6. User presses 'a' to add new PATH entry
7. Interactive form appears (reusing existing form.odin)
8. User fills path, presses Enter to submit
9. Success feedback, PATH view refreshes with new entry
10. User presses Esc to return to main menu
11. User presses 'q' to quit TUI
```

**Pain Points Addressed**:
- **Discoverability**: New users don't know what commands exist → TUI shows all options
- **Context Switching**: Typing commands repeatedly → Visual navigation reduces friction
- **Feature Awareness**: Users miss features like backups → All features visible in menu
- **Complex Workflows**: Multi-step operations require multiple commands → Single TUI session

---

## Why

- **Business Value**: Dramatically lowers barrier to entry for new users (improves adoption)
- **User Impact**: Provides guided, discoverable interface without sacrificing CLI power
- **Competitive**: Modern CLI tools (lazygit, k9s, bottom) all offer TUI modes
- **Integration**: Reuses existing interactive components (fuzzy.odin, form.odin, style.odin)
- **Problems Solved**:
  - For **new users**: Learn wayu features through exploration, not documentation
  - For **occasional users**: Visual reminder of available operations
  - For **power users**: Optional visual interface for complex tasks (backup management)

---

## What

### User-Visible Behavior

**TUI Mode Entry**:
- Running `wayu` with no arguments enters full-screen TUI
- Running `wayu --tui` explicitly enters TUI
- TUI uses alternate screen buffer (terminal history preserved on exit)
- Ctrl+C or 'q' key exits TUI cleanly

**Main Menu View**:
- Displays wayu version and detected shell (zsh/bash)
- Shows 7 menu items with emoji icons and entry counts
- Navigation: j/k or ↑/↓ keys, Enter to select
- Footer shows keyboard shortcuts

**Category Views** (PATH, Aliases, Constants, etc.):
- List/table display of current configuration
- Real-time status indicators (✓ exists, ✗ missing, ⚠ duplicate)
- Actions: 'a' add, 'd' delete, 'e' edit (where applicable)
- Reuses existing interactive components (form.odin for add, fuzzy.odin for delete)
- Back navigation: Esc or ← key returns to main menu

**Settings View**:
- Display current configuration (shell, config directory, version)
- Toggle options: dry-run mode, auto backups, color output, verbose mode
- Maintenance actions: migrate shell, reinitialize, check updates

### Technical Requirements

**Terminal Control**:
- Raw terminal mode with termios (reuse existing pattern from fuzzy.odin)
- Alternate screen buffer enable/disable
- Dynamic terminal size detection via ioctl(TIOCGWINSZ)
- SIGWINCH signal handling for resize events

**Rendering System**:
- Double-buffered screen with differential updates (render only changed cells)
- Reuse existing style.odin, theme.odin, table.odin for consistent styling
- Target 30-60 FPS rendering (< 50ms per frame)

**Input Handling**:
- Character-by-character input capture (existing pattern works)
- Full escape sequence support (arrows, Home, End, Page Up/Down)
- Modal state support (reuse fuzzy.odin patterns)

**State Management**:
- View-based state machine (MainMenu → PathView → PathAdd → PathView)
- Navigation stack for back button behavior
- Data caching per view to avoid redundant file reads

### Success Criteria

- [ ] `wayu` (no args) launches TUI successfully
- [ ] All 7 views render correctly and are navigable
- [ ] Main menu shows correct entry counts for each category
- [ ] PATH view: add, remove, clean duplicates all work
- [ ] Aliases view: add, edit, remove all work
- [ ] Backups view: list, restore, create, delete all work
- [ ] Settings view: displays config, toggles work
- [ ] Forms and fuzzy finder integrate seamlessly
- [ ] Terminal resize handled gracefully (no crashes)
- [ ] Exit (q, Ctrl+C) restores terminal state correctly
- [ ] All existing CLI commands unchanged (zero regressions)
- [ ] Input lag < 50ms (feels responsive)
- [ ] No visual artifacts (flicker, misalignment)

---

## All Needed Context

### Context Completeness Check

✅ **Validation**: This PRP includes:
- Exact file paths to existing patterns in wayu codebase
- Specific line numbers for key functions to reuse
- URLs to Odin documentation with section context
- Code snippets showing terminal control patterns already working in wayu
- Detailed analysis of existing TUI-ready components (4,551 lines already written!)
- External TUI framework references with actionable links
- Known gotchas and platform-specific considerations

### Documentation & References

```yaml
# MUST READ - Odin Terminal Capabilities
- url: https://pkg.odin-lang.org/core/terminal/ansi/
  why: ANSI escape code constants for cursor control, colors, screen manipulation
  critical: Use CSI, SGR, CUU/CUD/CUF/CUB for cursor movement, ED/EL for screen clearing

- url: https://pkg.odin-lang.org/core/sys/posix/
  why: termios structure, tcgetattr/tcsetattr for raw mode, ioctl for terminal size
  critical: Must save/restore terminal state, handle errors from tcgetattr

- url: https://github.com/odin-lang/examples/tree/master/console/raw_console
  why: Official Odin example of raw terminal mode implementation
  critical: Shows proper cleanup with defer, POSIX vs Windows patterns

# MUST READ - Existing Wayu Patterns
- file: /Users/kakurega/dev/projects/wayu/src/fuzzy.odin
  why: Production-ready terminal control, modal state machine (Normal/Insert modes)
  pattern: Lines 15-79 (termios setup), 52-79 (enable/disable raw mode), 753-821 (event loop)
  gotcha: macOS termios c_cc array is [20]c.uchar, Linux may differ
  critical: Always defer disable_raw_mode() and cursor show to prevent terminal corruption

- file: /Users/kakurega/dev/projects/wayu/src/form.odin
  why: Multi-field form system with Tab navigation, validation, preview panels
  pattern: Lines 54-73 (form_run lifecycle), 94-140 (navigation), 252-338 (rendering)
  gotcha: Form requires init_special_chars() before use for emoji width calculations

- file: /Users/kakurega/dev/projects/wayu/src/input.odin
  why: Single-line text input with cursor management
  pattern: Lines 109-123 (arrow key handling), 127-207 (char insert/delete), 210-288 (cursor rendering)
  gotcha: Cursor position tracked separately from string index, handle emoji width correctly

- file: /Users/kakurega/dev/projects/wayu/src/style.odin
  why: Complete rendering pipeline with borders, padding, colors
  pattern: Lines 12-64 (render proc), 159-196 (border drawing), 273-309 (text styling)
  gotcha: Must use visible_width() not len() for emoji/ANSI-aware width calculation

- file: /Users/kakurega/dev/projects/wayu/src/table.odin
  why: Table rendering with auto-width columns, headers, styled rows
  pattern: Lines 87-102 (column width calculation), 105-185 (table rendering)
  gotcha: recalculate_column_widths() before every render if data changes

- file: /Users/kakurega/dev/projects/wayu/src/layout.odin
  why: Visual width utilities, text alignment, box model
  pattern: Lines 9-157 (visual_width, is_wide_character), 312-349 (center/align text)
  critical: Lines 460-470 show PLACEHOLDER terminal size detection - MUST IMPLEMENT REAL VERSION

# MUST READ - TUI Design Patterns
- docfile: /Users/kakurega/dev/projects/wayu/docs/references/TUI_DESIGN_PATTERNS.md
  why: Comprehensive research on modern TUI architecture, keybindings, rendering strategies
  section: "The Elm Architecture (TEA)" - Model-Update-View pattern (industry consensus)
  section: "Rendering Strategies" - Double buffering with differential updates
  section: "Keybinding Standards" - vim-style j/k + arrow keys for navigation
  critical: All modern TUIs use TEA pattern, diff-based rendering is now standard

- url: https://ratatui.rs/concepts/application-patterns/the-elm-architecture/
  why: TEA pattern explanation with code examples in Rust
  critical: Model (state) → Update (event handler) → View (render) loop

- url: https://ratatui.rs/concepts/rendering/under-the-hood/
  why: Differential rendering implementation (120μs → 55μs, 55% speedup)
  critical: Compare current frame to previous frame, only update changed cells

- url: https://github.com/jesseduffield/lazygit/blob/master/docs/dev/Codebase_Guide.md
  why: Production TUI architecture (45k stars), View-Controller pattern
  critical: Separate views from controllers, use contexts for view state
```

### Current Codebase Tree

```bash
wayu/
├── src/
│   ├── main.odin               # Entry point (WILL MODIFY for TUI routing)
│   ├── shell.odin              # Shell detection
│   ├── path.odin               # PATH command handler
│   ├── alias.odin              # Alias command handler
│   ├── constants.odin          # Constants command handler
│   ├── completions.odin        # Completions command handler
│   ├── backup.odin             # Backup system
│   ├── plugin.odin             # Plugin system
│   ├── validation.odin         # Input validation
│   ├── fuzzy.odin              # ✅ Interactive fuzzy finder (REUSE)
│   ├── form.odin               # ✅ Interactive form system (REUSE)
│   ├── input.odin              # ✅ Text input component (REUSE)
│   ├── style.odin              # ✅ Styling engine (REUSE)
│   ├── theme.odin              # ✅ Theme system (REUSE)
│   ├── table.odin              # ✅ Table renderer (REUSE)
│   ├── layout.odin             # ✅ Layout utilities (REUSE)
│   ├── colors.odin             # ✅ Color system (REUSE)
│   ├── special_chars.odin      # ✅ Emoji width handling (REUSE)
│   ├── types.odin              # Shared types
│   ├── preload.odin            # Config templates
│   └── debug.odin              # Debug logging
│
├── tests/
│   ├── unit/                   # 218 unit tests (MUST PASS)
│   ├── ui/                     # 10 UI tests (MUST PASS)
│   └── integration/            # 27 integration tests (MUST PASS)
│
├── docs/
│   ├── planning/
│   │   ├── PRP-12_FULL_TUI_MODE.md        # Original design doc (REFERENCE)
│   │   └── TUI_LAYOUT_ALGORITHM.md        # Box rendering algorithm
│   └── references/
│       └── TUI_DESIGN_PATTERNS.md         # Research findings (CRITICAL READ)
│
├── scripts/
│   └── tui_box_generator.py    # Python validator for TUI boxes
│
├── Taskfile.yml                # Build tasks
├── CLAUDE.md                   # Project overview
└── README.md                   # User docs
```

### Desired Codebase Tree (Files to Add)

```bash
wayu/
├── src/
│   ├── main.odin                        # [MODIFY] Add TUI routing logic
│   │
│   ├── tui/                             # [NEW PACKAGE] TUI framework
│   │   ├── tui_main.odin               # [CREATE] TUI entry point, main loop
│   │   ├── tui_state.odin              # [CREATE] State machine, view enum
│   │   ├── tui_terminal.odin           # [CREATE] Terminal control (size, signals, alt screen)
│   │   ├── tui_events.odin             # [CREATE] Event types (KeyEvent, MouseEvent, ResizeEvent)
│   │   ├── tui_input.odin              # [CREATE] Input parser (escape sequences, keys)
│   │   ├── tui_screen.odin             # [CREATE] Screen buffer, double buffering
│   │   ├── tui_render.odin             # [CREATE] Differential rendering, screen flush
│   │   │
│   │   └── views/                       # [NEW] View implementations
│   │       ├── main_menu.odin          # [CREATE] Main menu view with 7 categories
│   │       ├── path_view.odin          # [CREATE] PATH management view
│   │       ├── alias_view.odin         # [CREATE] Alias management view
│   │       ├── constants_view.odin     # [CREATE] Constants management view
│   │       ├── completions_view.odin   # [CREATE] Completions view
│   │       ├── backups_view.odin       # [CREATE] Backups view
│   │       ├── plugins_view.odin       # [CREATE] Plugins view
│   │       └── settings_view.odin      # [CREATE] Settings view
│   │
│   └── [existing files unchanged]
│
└── tests/
    └── unit/
        ├── test_tui_state.odin          # [CREATE] State machine tests
        ├── test_tui_terminal.odin       # [CREATE] Terminal control tests
        ├── test_tui_events.odin         # [CREATE] Event parsing tests
        ├── test_tui_screen.odin         # [CREATE] Screen buffer tests
        └── test_tui_views.odin          # [CREATE] View rendering tests
```

### Known Gotchas & Library Quirks

```odin
// CRITICAL: macOS termios structure differs from Linux
// macOS: c_cc is [20]c.uchar, c_iflag/c_oflag/c_cflag/c_lflag are c.ulong
// Linux: c_cc is [32]c.uchar, flags are c.uint
// Solution: Use platform-specific definitions or test on both
when ODIN_OS == .Darwin {
    termios :: struct {
        c_iflag:  c.ulong,
        c_oflag:  c.ulong,
        c_cflag:  c.ulong,
        c_lflag:  c.ulong,
        c_cc:     [20]c.uchar,  // macOS NCCS=20
        c_ispeed: c.ulong,
        c_ospeed: c.ulong,
    }
}

// CRITICAL: TIOCGWINSZ constant differs by platform
// macOS: 0x40087468
// Linux: 0x5413
when ODIN_OS == .Darwin {
    TIOCGWINSZ :: 0x40087468
} else when ODIN_OS == .Linux {
    TIOCGWINSZ :: 0x5413
}

// CRITICAL: Always defer terminal cleanup to prevent corruption
enable_raw_mode()
fmt.print(HIDE_CURSOR)
defer {
    fmt.print(CLEAR_SCREEN)
    fmt.print(SHOW_CURSOR)
    disable_raw_mode()
}

// GOTCHA: Emoji width calculation required for correct rendering
// Use get_rune_visual_width() from special_chars.odin, NOT len()
// "📂 PATH" has len()=6 but visual width=7 (emoji is 2 columns)

// GOTCHA: ANSI escape sequences have zero visual width but take bytes
// Strip ANSI codes before calculating width or use get_visual_width_no_ansi()

// GOTCHA: Odin's os.read() for stdin is blocking by default
// In raw mode, read() returns immediately with available bytes or 0
// Check n (bytes read) before accessing input_buf

// GOTCHA: Signal handlers MUST use "c" calling convention
terminal_resize_handler :: proc "c" (sig: i32) {
    // Cannot use Odin allocator or context in signal handlers
    // Set atomic flag, handle in main loop
}

// GOTCHA: Alternate screen buffer must be exited before program ends
// Use defer or atexit to ensure EXIT_ALT_SCREEN is printed
```

---

## Implementation Blueprint

### Data Models and Structure

```odin
// Core TUI types

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
    previous_view:   TUIView,          // For back navigation
    selected_index:  int,              // Currently highlighted item
    scroll_offset:   int,              // For scrolling long lists
    terminal_width:  int,              // From ioctl(TIOCGWINSZ)
    terminal_height: int,              // From ioctl(TIOCGWINSZ)
    needs_refresh:   bool,             // Data changed, re-render needed
    running:         bool,             // Main loop control
    data_cache:      map[TUIView]rawptr, // Per-view cached data
}

Event :: union {
    KeyEvent,
    MouseEvent,
    ResizeEvent,
}

KeyEvent :: struct {
    key:       Key,
    char:      rune,        // For printable keys
    modifiers: KeyModifiers,
}

Key :: enum {
    // Printable
    Char,
    // Special
    Enter, Tab, Backspace, Delete, Escape,
    // Navigation
    Up, Down, Left, Right, Home, End, PageUp, PageDown,
    // Function
    F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
}

KeyModifiers :: bit_set[KeyModifier]
KeyModifier :: enum { Shift, Ctrl, Alt }

ResizeEvent :: struct {
    width, height: int,
}

Cell :: struct {
    char:  rune,
    fg:    string,  // ANSI color
    bg:    string,  // ANSI color
    bold:  bool,
    dim:   bool,
}

Screen :: struct {
    buffer:      [][]Cell,  // Current frame
    prev_buffer: [][]Cell,  // Previous frame (for differential updates)
    width:       int,
    height:      int,
    cursor_x:    int,
    cursor_y:    int,
}
```

### Implementation Tasks (ordered by dependencies)

```yaml
PHASE 1: Terminal Infrastructure (Priority: CRITICAL, Days: 1-2)

Task 1.1: CREATE src/tui/tui_terminal.odin
  - IMPLEMENT: get_terminal_size() using ioctl(TIOCGWINSZ) with platform-specific constants
  - IMPLEMENT: setup_resize_handler() for SIGWINCH signal
  - IMPLEMENT: enter_alt_screen() and exit_alt_screen() with ANSI codes
  - IMPLEMENT: tui_lifecycle_init() and tui_lifecycle_cleanup()
  - FOLLOW pattern: src/fuzzy.odin lines 15-79 (termios structure, raw mode)
  - NAMING: snake_case for all functions
  - PLATFORM: Handle macOS (0x40087468) and Linux (0x5413) TIOCGWINSZ constants
  - CRITICAL: Always use defer for cleanup functions

Task 1.2: CREATE tests/unit/test_tui_terminal.odin
  - IMPLEMENT: Test terminal size detection returns positive dimensions
  - IMPLEMENT: Test alternate screen buffer enable/disable (manual verification)
  - IMPLEMENT: Test signal handler registration doesn't crash
  - COVERAGE: Happy path for terminal operations
  - RUN: odin test tests/unit/test_tui_terminal.odin -file

PHASE 2: Event System (Priority: CRITICAL, Days: 2-3)

Task 2.1: CREATE src/tui/tui_events.odin
  - IMPLEMENT: Event union type (KeyEvent, MouseEvent, ResizeEvent)
  - IMPLEMENT: Key enum (Char, Enter, Tab, arrows, function keys, etc.)
  - IMPLEMENT: KeyModifiers bit_set (Shift, Ctrl, Alt)
  - IMPLEMENT: parse_key_event(input_buf: []byte, n: int) -> (KeyEvent, bool)
  - FOLLOW pattern: src/fuzzy.odin lines 553-707 (escape sequence parsing)
  - CRITICAL: Handle 3-byte escape sequences (ESC [ A/B/C/D for arrows)
  - CRITICAL: Handle function keys (F1-F12), Ctrl+arrow combinations

Task 2.2: CREATE src/tui/tui_input.odin
  - IMPLEMENT: poll_event() -> Event (reads from stdin, parses to Event)
  - IMPLEMENT: non-blocking input with timeout support
  - FOLLOW pattern: src/fuzzy.odin lines 774-818 (input loop structure)
  - NAMING: poll_event for non-blocking, wait_event for blocking
  - CRITICAL: Check os.read() error codes, handle n==0 (no input available)

Task 2.3: CREATE tests/unit/test_tui_events.odin
  - IMPLEMENT: Test parse_key_event for common keys (arrows, Enter, letters)
  - IMPLEMENT: Test escape sequence parsing (ESC [ A → Up arrow)
  - IMPLEMENT: Test Ctrl key combinations (Ctrl+C → code 3)
  - COVERAGE: All Key enum variants
  - RUN: odin test tests/unit/test_tui_events.odin -file

PHASE 3: Screen Management (Priority: CRITICAL, Days: 2-3)

Task 3.1: CREATE src/tui/tui_screen.odin
  - IMPLEMENT: Screen struct with double buffer (buffer, prev_buffer)
  - IMPLEMENT: Cell struct (char, fg, bg, bold, dim)
  - IMPLEMENT: screen_create(width, height: int) -> Screen
  - IMPLEMENT: screen_resize(screen: ^Screen, width, height: int)
  - IMPLEMENT: screen_set_cell(screen: ^Screen, x, y: int, cell: Cell)
  - IMPLEMENT: screen_clear(screen: ^Screen) - fills with space cells
  - NAMING: screen_* prefix for all screen operations
  - MEMORY: Allocate buffers with make([][]Cell), free with delete()

Task 3.2: CREATE src/tui/tui_render.odin
  - IMPLEMENT: screen_flush(screen: ^Screen) - differential update algorithm
  - IMPLEMENT: render_text(screen: ^Screen, x, y: int, text: string, style: Style)
  - IMPLEMENT: render_box(screen: ^Screen, x, y, width, height: int, border: BorderStyle)
  - FOLLOW pattern: Ratatui diff algorithm (compare current to previous frame)
  - CRITICAL: Only output ANSI codes for changed cells (minimize terminal writes)
  - CRITICAL: Track cursor position to minimize cursor movement codes
  - OPTIMIZATION: Batch consecutive unchanged cells, skip rendering

Task 3.3: CREATE tests/unit/test_tui_screen.odin
  - IMPLEMENT: Test screen creation with dimensions
  - IMPLEMENT: Test set_cell updates correct position
  - IMPLEMENT: Test screen_clear fills all cells with spaces
  - IMPLEMENT: Test screen_resize preserves existing content where possible
  - COVERAGE: All screen manipulation operations
  - RUN: odin test tests/unit/test_tui_screen.odin -file

PHASE 4: State Machine (Priority: HIGH, Days: 1-2)

Task 4.1: CREATE src/tui/tui_state.odin
  - IMPLEMENT: TUIState struct (current_view, selected_index, scroll_offset, etc.)
  - IMPLEMENT: TUIView enum (MAIN_MENU, PATH_VIEW, etc.)
  - IMPLEMENT: tui_state_init() -> TUIState (default: MAIN_MENU)
  - IMPLEMENT: tui_state_goto_view(state: ^TUIState, view: TUIView)
  - IMPLEMENT: tui_state_go_back(state: ^TUIState) - return to previous view
  - IMPLEMENT: tui_state_move_selection(state: ^TUIState, delta: int) - handle up/down
  - FOLLOW pattern: src/fuzzy.odin lines 110-133 (FuzzyView struct, state fields)
  - NAMING: tui_state_* prefix for state operations

Task 4.2: CREATE tests/unit/test_tui_state.odin
  - IMPLEMENT: Test state initialization (starts at MAIN_MENU)
  - IMPLEMENT: Test goto_view transitions and previous_view tracking
  - IMPLEMENT: Test go_back restores previous view
  - IMPLEMENT: Test move_selection handles bounds correctly (wrap around)
  - COVERAGE: All state transitions
  - RUN: odin test tests/unit/test_tui_state.odin -file

PHASE 5: Main TUI Loop (Priority: HIGH, Days: 2-3)

Task 5.1: CREATE src/tui/tui_main.odin
  - IMPLEMENT: tui_run() -> bool (main TUI entry point, returns success)
  - IMPLEMENT: Main event loop (render → poll input → handle event → repeat)
  - IMPLEMENT: Global event handlers (q=quit, Esc=back, arrows=navigate)
  - FOLLOW pattern: The Elm Architecture (Model-Update-View)
  - FOLLOW pattern: src/fuzzy.odin lines 753-821 (event loop structure)
  - LIFECYCLE: Call tui_lifecycle_init() at start, tui_lifecycle_cleanup() in defer
  - CRITICAL: Use defer for cleanup to handle Ctrl+C gracefully

Task 5.2: MODIFY src/main.odin
  - FIND: main() procedure (entry point)
  - ADD: Check if len(os.args) < 2 (no arguments provided)
  - ADD: If no args, import "tui" and call tui.tui_run()
  - ADD: If args == ["--tui"], also call tui.tui_run()
  - PRESERVE: All existing CLI argument parsing logic (CLI must work unchanged)
  - PATTERN:
    main :: proc() {
        // ... existing init code ...

        // NEW: TUI mode check
        if len(os.args) < 2 || (len(os.args) == 2 && os.args[1] == "--tui") {
            success := tui.tui_run()
            os.exit(success ? 0 : 1)
        }

        // EXISTING: CLI mode continues as before
        parsed := parse_args(os.args[1:])
        // ... rest of CLI logic unchanged ...
    }

PHASE 6: View Implementations (Priority: HIGH, Days: 4-6)

Task 6.1: CREATE src/tui/views/main_menu.odin
  - IMPLEMENT: render_main_menu(state: ^TUIState, screen: ^Screen)
  - IMPLEMENT: handle_main_menu_input(state: ^TUIState, event: KeyEvent) -> bool
  - DISPLAY: 7 menu items (PATH, Aliases, Constants, Completions, Backups, Plugins, Settings)
  - DISPLAY: Entry counts for each category (call existing list functions)
  - DISPLAY: wayu version and detected shell in header
  - DISPLAY: Keyboard shortcuts in footer
  - FOLLOW pattern: src/fuzzy.odin lines 284-550 (component-based rendering)
  - FOLLOW pattern: PRP-12 main menu layout (76 columns width)
  - NAVIGATION: j/k or arrows move, Enter selects, q quits

Task 6.2: CREATE src/tui/views/path_view.odin
  - IMPLEMENT: render_path_view(state: ^TUIState, screen: ^Screen)
  - IMPLEMENT: handle_path_view_input(state: ^TUIState, event: KeyEvent) -> bool
  - DISPLAY: List all PATH entries with status (✓exists, ✗missing, ⚠duplicate)
  - ACTIONS: 'a' = add (call form.odin), 'd' = delete (call fuzzy.odin), 'c' = clean
  - REUSE: path.odin functions (extract_path_entries, validate_path, etc.)
  - REUSE: form.odin for add operation (existing form_run)
  - REUSE: fuzzy.odin for delete operation (existing fuzzy_run)
  - NAVIGATION: Esc/← = back to main menu

Task 6.3: CREATE src/tui/views/alias_view.odin
  - IMPLEMENT: render_alias_view(state: ^TUIState, screen: ^Screen)
  - IMPLEMENT: handle_alias_view_input(state: ^TUIState, event: KeyEvent) -> bool
  - DISPLAY: Table of aliases (name, command) using table.odin
  - ACTIONS: 'a' = add, 'e' = edit, 'd' = delete, 'v' = view full command
  - REUSE: alias.odin functions (extract_alias_items, validate_alias, etc.)
  - REUSE: table.odin for table rendering
  - REUSE: form.odin for add/edit operations

Task 6.4: CREATE src/tui/views/constants_view.odin
  - IMPLEMENT: render_constants_view(state: ^TUIState, screen: ^Screen)
  - IMPLEMENT: handle_constants_view_input(state: ^TUIState, event: KeyEvent) -> bool
  - DISPLAY: Table of constants (name, value, type)
  - ACTIONS: 'a' = add, 'd' = delete
  - REUSE: constants.odin functions (extract_constant_items, validate_constant, etc.)

Task 6.5: CREATE src/tui/views/completions_view.odin
  - IMPLEMENT: render_completions_view(state: ^TUIState, screen: ^Screen)
  - IMPLEMENT: handle_completions_view_input(state: ^TUIState, event: KeyEvent) -> bool
  - DISPLAY: List of completion scripts with file size
  - ACTIONS: 'a' = add, 'd' = delete
  - REUSE: completions.odin functions

Task 6.6: CREATE src/tui/views/backups_view.odin
  - IMPLEMENT: render_backups_view(state: ^TUIState, screen: ^Screen)
  - IMPLEMENT: handle_backups_view_input(state: ^TUIState, event: KeyEvent) -> bool
  - DISPLAY: Table of backups (filename, timestamp, size, type)
  - ACTIONS: 'r' = restore, 'c' = create, 'd' = delete, 'v' = view contents
  - REUSE: backup.odin functions (list_backups, restore_backup, etc.)
  - CRITICAL: Add confirmation dialog before restore/delete (reuse fuzzy.odin confirm pattern)

Task 6.7: CREATE src/tui/views/plugins_view.odin
  - IMPLEMENT: render_plugins_view(state: ^TUIState, screen: ^Screen)
  - IMPLEMENT: handle_plugins_view_input(state: ^TUIState, event: KeyEvent) -> bool
  - DISPLAY: List of installed plugins
  - ACTIONS: 'a' = add, 'd' = delete
  - REUSE: plugin.odin functions

Task 6.8: CREATE src/tui/views/settings_view.odin
  - IMPLEMENT: render_settings_view(state: ^TUIState, screen: ^Screen)
  - IMPLEMENT: handle_settings_view_input(state: ^TUIState, event: KeyEvent) -> bool
  - DISPLAY: Current configuration (shell, config directory, version)
  - DISPLAY: Toggle options (dry-run, auto backups, color output, verbose)
  - ACTIONS: Space = toggle option, 'm' = migrate shell, 'i' = reinit
  - REUSE: shell.odin for shell detection info

Task 6.9: CREATE tests/unit/test_tui_views.odin
  - IMPLEMENT: Test each view renders without crashing
  - IMPLEMENT: Test input handlers return correct values
  - IMPLEMENT: Test state transitions (view changes on Enter/Esc)
  - COVERAGE: Basic smoke tests for all 8 views
  - RUN: odin test tests/unit/test_tui_views.odin -file

PHASE 7: Integration & Polish (Priority: MEDIUM, Days: 2-3)

Task 7.1: Integration testing
  - TEST: Launch TUI with `./bin/wayu` (manual test)
  - TEST: Navigate all 7 views and return to main menu
  - TEST: Perform add/delete operations in each view
  - TEST: Verify terminal state restored on exit (run `stty -a` before/after)
  - TEST: Verify all existing CLI commands unchanged (run integration test suite)

Task 7.2: Performance optimization
  - PROFILE: Measure rendering time per frame (target < 50ms)
  - OPTIMIZE: Screen flush to minimize ANSI output
  - OPTIMIZE: Cache data per view (avoid redundant file reads)
  - BENCHMARK: Run on different terminal sizes (80x24, 120x40, 200x60)

Task 7.3: Error handling
  - HANDLE: Terminal size too small (< 80x24) - show error message
  - HANDLE: Terminal doesn't support ANSI (check NO_COLOR, TERM env vars)
  - HANDLE: Raw mode fails - fallback to CLI with error message
  - HANDLE: SIGWINCH during resize - graceful re-layout

Task 7.4: Documentation updates
  - UPDATE: README.md with TUI mode section
  - UPDATE: CLAUDE.md with TUI architecture overview
  - UPDATE: Task build commands (task run-tui)
```

### Implementation Patterns & Key Details

```odin
// PATTERN: Terminal size detection (Task 1.1)
// FOLLOW: POSIX ioctl with platform-specific constants

when ODIN_OS == .Darwin {
    TIOCGWINSZ :: 0x40087468
} else when ODIN_OS == .Linux {
    TIOCGWINSZ :: 0x5413
}

foreign import libc "system:c"

winsize :: struct {
    ws_row:    c.ushort,
    ws_col:    c.ushort,
    ws_xpixel: c.ushort,
    ws_ypixel: c.ushort,
}

foreign libc {
    ioctl :: proc(fd: c.int, request: c.ulong, arg: rawptr) -> c.int ---
}

get_terminal_size :: proc() -> (width, height: int, ok: bool) {
    ws: winsize
    result := ioctl(1, TIOCGWINSZ, &ws)  // 1 = STDOUT_FILENO

    if result == 0 {
        return int(ws.ws_col), int(ws.ws_row), true
    }
    return 80, 24, false  // Fallback
}

// PATTERN: SIGWINCH handler (Task 1.1)
// CRITICAL: Signal handlers MUST use "c" calling convention

terminal_resized: bool  // Global atomic flag

sigwinch_handler :: proc "c" (sig: i32) {
    terminal_resized = true
}

setup_resize_handler :: proc() {
    import "core:sys/posix"

    act := posix.sigaction{
        sa_handler = sigwinch_handler,
        sa_flags = {.RESTART},  // Restart interrupted syscalls
    }
    posix.sigaction(.SIGWINCH, &act, nil)
}

// PATTERN: Alternate screen buffer (Task 1.1)
// CRITICAL: Always defer exit to prevent leaving alternate screen

ENTER_ALT_SCREEN :: "\x1b[?1049h"  // Save screen, enter alternate
EXIT_ALT_SCREEN  :: "\x1b[?1049l"  // Exit alternate, restore screen

tui_lifecycle_init :: proc() {
    fmt.print(ENTER_ALT_SCREEN)
    fmt.print(HIDE_CURSOR)
}

tui_lifecycle_cleanup :: proc() {
    fmt.print(SHOW_CURSOR)
    fmt.print(EXIT_ALT_SCREEN)
}

// PATTERN: Differential rendering (Task 3.2)
// FOLLOW: Ratatui algorithm - compare frames, only update changed cells

screen_flush :: proc(screen: ^Screen) {
    import "core:strings"

    builder: strings.Builder
    strings.builder_init(&builder)
    defer strings.builder_destroy(&builder)

    for y in 0..<screen.height {
        for x in 0..<screen.width {
            curr := screen.buffer[y][x]
            prev := screen.prev_buffer[y][x]

            // Skip unchanged cells
            if curr == prev do continue

            // Move cursor if needed (minimize cursor movement)
            if x != screen.cursor_x || y != screen.cursor_y {
                fmt.sbprintf(&builder, "\x1b[%d;%dH", y+1, x+1)
                screen.cursor_x = x
                screen.cursor_y = y
            }

            // Apply cell styling (foreground, background, bold, dim)
            if curr.fg != prev.fg {
                fmt.sbprintf(&builder, "%s", curr.fg)
            }
            if curr.bold && !prev.bold {
                fmt.sbprintf(&builder, "\x1b[1m")
            }
            if !curr.bold && prev.bold {
                fmt.sbprintf(&builder, "\x1b[22m")
            }

            // Write character
            fmt.sbprintf(&builder, "%c", curr.char)
            screen.cursor_x += 1
        }
    }

    // Single write to terminal (batch for performance)
    fmt.print(strings.to_string(builder))

    // Copy current to previous for next frame
    copy(screen.prev_buffer, screen.buffer)
}

// PATTERN: The Elm Architecture main loop (Task 5.1)
// FOLLOW: TEA pattern - Model (state) → Update (events) → View (render)

tui_run :: proc() -> bool {
    // MODEL: Initialize state
    state := tui_state_init()
    defer tui_state_destroy(&state)

    // Initialize terminal
    if !enable_raw_mode() {
        fmt.eprintln("Error: Failed to enable raw mode")
        return false
    }
    tui_lifecycle_init()

    defer {
        tui_lifecycle_cleanup()
        disable_raw_mode()
    }

    // Create screen buffer
    width, height, ok := get_terminal_size()
    if !ok {
        width, height = 80, 24
    }
    screen := screen_create(width, height)
    defer screen_destroy(&screen)

    // Setup resize handler
    setup_resize_handler()

    // Main loop: Update → View → Poll Events
    for state.running {
        // Handle terminal resize
        if terminal_resized {
            terminal_resized = false
            width, height, _ = get_terminal_size()
            screen_resize(&screen, width, height)
            state.needs_refresh = true
        }

        // VIEW: Render current view to screen
        if state.needs_refresh {
            screen_clear(&screen)

            switch state.current_view {
            case .MAIN_MENU:
                render_main_menu(&state, &screen)
            case .PATH_VIEW:
                render_path_view(&state, &screen)
            // ... other views
            }

            screen_flush(&screen)
            state.needs_refresh = false
        }

        // UPDATE: Poll and handle events
        event := poll_event()

        #partial switch e in event {
        case KeyEvent:
            // Global keys (work in all views)
            if e.key == .Escape || e.char == 'q' {
                if state.current_view == .MAIN_MENU {
                    state.running = false  // Exit TUI
                } else {
                    tui_state_go_back(&state)  // Back to previous view
                    state.needs_refresh = true
                }
                continue
            }

            // Delegate to current view's input handler
            handled := false
            switch state.current_view {
            case .MAIN_MENU:
                handled = handle_main_menu_input(&state, e)
            case .PATH_VIEW:
                handled = handle_path_view_input(&state, e)
            // ... other views
            }

            if handled {
                state.needs_refresh = true
            }

        case ResizeEvent:
            screen_resize(&screen, e.width, e.height)
            state.needs_refresh = true
        }
    }

    return true
}

// PATTERN: View integration with existing components (Task 6.2)
// CRITICAL: Reuse fuzzy.odin and form.odin, don't reimplement

handle_path_view_input :: proc(state: ^TUIState, event: KeyEvent) -> bool {
    switch event.char {
    case 'a':  // Add new PATH entry
        // Reuse existing form system
        form := create_path_add_form()
        defer destroy_form(&form)

        if form_run(&form) {
            // Form submitted successfully
            // PATH entry already added by form submit callback
            // Just refresh view data
            state.needs_refresh = true
        }
        // Form cleanup happens in defer
        return true

    case 'd':  // Delete PATH entry
        // Reuse existing fuzzy finder
        items := extract_path_items()  // From path.odin
        defer delete(items)

        view := create_fuzzy_view(
            items = items,
            title = "Select PATH entry to remove",
            action_key = 'd',
            action_label = "Delete",
        )
        defer destroy_fuzzy_view(&view)

        selected, ok := fuzzy_run(&view)
        if ok {
            // User selected item to delete
            remove_path_entry(selected.label)
            state.needs_refresh = true
        }
        return true

    case 'c':  // Clean duplicates
        clean_duplicate_paths()
        state.needs_refresh = true
        return true
    }

    return false  // Key not handled
}
```

### Integration Points

```yaml
TERMINAL:
  - ioctl: Use TIOCGWINSZ for dynamic terminal size detection
  - signals: Register SIGWINCH handler for resize events
  - escape codes: ENTER_ALT_SCREEN / EXIT_ALT_SCREEN for clean TUI experience

CONFIG:
  - no changes: TUI reads same ~/.config/wayu/ files as CLI
  - reuse: All existing config file manipulation functions work as-is

EXISTING COMPONENTS:
  - fuzzy.odin: Reuse fuzzy_run() for all delete operations
  - form.odin: Reuse form_run() for all add/edit operations
  - style.odin: Reuse render() for styled text rendering
  - table.odin: Reuse table_render() for table views
  - validation.odin: Reuse all validation functions

BUILD SYSTEM:
  - Taskfile.yml: Add `task run-tui` command
  - No new dependencies: Pure Odin implementation
```

---

## Validation Loop

### Level 1: Syntax & Compilation (Immediate Feedback)

```bash
# After each file creation - fix before proceeding

# Compile TUI package
odin build src/tui -out:bin/tui_test -debug
# Expected: Zero errors. If errors exist, READ output carefully and fix.

# Type check (if available)
# Odin doesn't have separate type checker - errors caught at compile time

# Build entire project to ensure integration
task build-dev
# Expected: Compiles successfully with no errors
```

### Level 2: Unit Tests (Component Validation)

```bash
# Run unit tests for each new module as it's created

# Terminal control tests
odin test tests/unit/test_tui_terminal.odin -file
# Expected: All tests pass, terminal size detection works

# Event parsing tests
odin test tests/unit/test_tui_events.odin -file
# Expected: All key parsing tests pass

# Screen buffer tests
odin test tests/unit/test_tui_screen.odin -file
# Expected: Screen operations work correctly

# State machine tests
odin test tests/unit/test_tui_state.odin -file
# Expected: State transitions work as expected

# View tests
odin test tests/unit/test_tui_views.odin -file
# Expected: All views render without crashing

# Run all new TUI tests
odin test tests/unit/test_tui_*.odin
# Expected: All TUI unit tests pass

# CRITICAL: Run existing test suite (must not break)
task test:all
# Expected: 255 tests pass (218 unit + 27 integration + 10 UI), ZERO NEW FAILURES
```

### Level 3: Integration Testing (System Validation)

```bash
# Manual TUI testing workflow

# 1. Launch TUI
./bin/wayu
# Expected:
#   - Alternate screen buffer active
#   - Main menu visible with 7 categories
#   - Cursor hidden
#   - Keyboard shortcuts shown in footer

# 2. Navigate main menu
# Press: j j j (down 3 times)
# Expected: Highlight moves down 3 items

# 3. Select PATH management
# Press: Enter
# Expected: PATH view appears with list of PATH entries

# 4. Add PATH entry
# Press: a
# Expected: Form appears (reusing form.odin)
# Type: /usr/local/test
# Press: Enter
# Expected: Form submits, PATH view refreshes, new entry visible

# 5. Delete PATH entry
# Press: d
# Expected: Fuzzy finder appears (reusing fuzzy.odin)
# Type: test
# Press: Enter
# Expected: Entry deleted, PATH view refreshes

# 6. Back to main menu
# Press: Esc
# Expected: Return to main menu

# 7. Test other views
# Navigate to each view (Aliases, Constants, etc.)
# Expected: Each view renders correctly with appropriate data

# 8. Quit TUI
# Press: q
# Expected:
#   - Exit to normal terminal
#   - Cursor visible again
#   - Terminal history preserved
#   - No visual artifacts

# 9. Verify terminal state
stty -a
# Expected: Terminal settings match pre-TUI state (canonical mode, echo on)

# 10. Test CLI unchanged
./bin/wayu path list --static
# Expected: CLI still works exactly as before

# 11. Test terminal resize
# Manually resize terminal window during TUI session
# Expected: TUI re-layouts gracefully, no crashes
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Performance testing

# 1. Rendering performance
# Launch TUI and observe responsiveness
# Press j/k rapidly (20+ times per second)
# Expected: No input lag, smooth navigation

# 2. Large dataset handling
# Create 100+ PATH entries
./bin/wayu path add /test/path/{1..100}
# Launch TUI and navigate to PATH view
# Expected: Scrolling works, no performance degradation

# 3. Terminal compatibility
# Test on different terminal emulators:
#   - iTerm2 (macOS)
#   - Terminal.app (macOS)
#   - Alacritty
#   - Kitty
# Expected: Works correctly on all modern terminals

# 4. Stress testing
# Launch TUI, spam random keys for 10 seconds
# Expected: No crashes, graceful handling of invalid inputs

# 5. Memory testing
# Launch TUI, navigate through all views multiple times
# Monitor memory usage (Activity Monitor / htop)
# Expected: Memory stable, no leaks

# 6. Box rendering validation (use Python script)
# Capture TUI output
./bin/wayu > /tmp/tui_output.txt << EOF
q
EOF

# Validate box dimensions
python3 scripts/tui_box_generator.py validate /tmp/tui_output.txt --expected-width 76
# Expected: ✅ All lines have correct width: 76 visual columns
```

---

## Final Validation Checklist

### Technical Validation

- [ ] All new files compile without errors: `task build-dev`
- [ ] All new unit tests pass: `odin test tests/unit/test_tui_*.odin`
- [ ] All existing tests pass (ZERO REGRESSIONS): `task test:all`
- [ ] No memory leaks: Memory usage stable after 5+ minutes of TUI use
- [ ] Terminal state restored correctly on exit: `stty -a` matches pre-TUI

### Feature Validation (from "What" section)

- [ ] `wayu` (no args) launches TUI successfully
- [ ] All 7 views render correctly (Main Menu, PATH, Aliases, Constants, Completions, Backups, Settings)
- [ ] Main menu shows correct entry counts for each category
- [ ] PATH view: add, remove, clean duplicates all work
- [ ] Aliases view: add, edit, remove all work
- [ ] Constants view: add, remove work
- [ ] Completions view: add, remove work
- [ ] Backups view: list, restore, create, delete all work
- [ ] Settings view: displays config correctly, toggles work
- [ ] Forms integrate seamlessly (reuse form.odin)
- [ ] Fuzzy finder integrates seamlessly (reuse fuzzy.odin)
- [ ] Terminal resize handled gracefully (SIGWINCH works)
- [ ] Exit (q, Ctrl+C) restores terminal state
- [ ] All existing CLI commands unchanged (test with `./bin/wayu path list`, etc.)
- [ ] Input lag < 50ms (feels responsive)
- [ ] No visual artifacts (flicker, misalignment, leftover characters)

### User Persona Validation

- [ ] New user can discover all features by running `wayu` (no docs needed)
- [ ] User can navigate entire TUI without reading help
- [ ] User can add/remove PATH entries without typing commands
- [ ] User can manage backups visually (list, restore, create)
- [ ] Power user can still use CLI for scripting (`wayu path add /path`)

### Code Quality Validation

- [ ] Follows existing codebase patterns (file organization, naming conventions)
- [ ] File placement matches desired codebase tree structure
- [ ] Reuses existing components (fuzzy.odin, form.odin, style.odin)
- [ ] No duplicate code (DRY principle)
- [ ] Memory managed correctly (defer delete() for all allocations)
- [ ] Error handling consistent with existing code
- [ ] Platform compatibility (macOS and Linux via POSIX)

### Documentation Validation

- [ ] Code is self-documenting (clear variable/function names)
- [ ] Comments explain "why" not "what" (where non-obvious)
- [ ] README.md updated with TUI section
- [ ] CLAUDE.md updated with TUI architecture overview
- [ ] No new external dependencies documented (pure Odin)

---

## Anti-Patterns to Avoid

**UI Anti-Patterns**:
- ❌ Don't hide navigation keys - always show footer with shortcuts
- ❌ Don't use ambiguous labels - "Press any key" is unclear
- ❌ Don't confirm non-destructive actions - only confirm delete/restore
- ❌ Don't use static error messages - provide actionable feedback
- ❌ Don't use jargon - "PATH" not "environment variable search path"

**Technical Anti-Patterns**:
- ❌ Don't do full screen redraws every frame - use differential updates
- ❌ Don't write unbuffered output - batch ANSI codes per frame
- ❌ Don't block on input - use non-blocking read or timeout
- ❌ Don't forget cleanup - always defer disable_raw_mode and SHOW_CURSOR
- ❌ Don't ignore terminal resize - handle SIGWINCH gracefully

**Architecture Anti-Patterns**:
- ❌ Don't use global mutable state - pass ^TUIState explicitly
- ❌ Don't mix view rendering with event handling - separate concerns
- ❌ Don't tight-couple views to data layer - use indirection
- ❌ Don't reimplement existing components - reuse fuzzy.odin, form.odin
- ❌ Don't create new patterns - follow existing wayu conventions

**Odin-Specific Anti-Patterns**:
- ❌ Don't use sync where async expected - N/A (Odin doesn't have async)
- ❌ Don't hardcode platform constants - use when ODIN_OS for platform checks
- ❌ Don't forget defer for cleanup - critical for terminal state
- ❌ Don't use "c" convention unnecessarily - only for signal handlers
- ❌ Don't leak memory - explicitly delete() all allocations

---

## Success Metrics

### Quantitative Targets

| Metric | Target | Measurement Method |
|--------|--------|-------------------|
| TUI Startup Time | < 100ms | Benchmark with `time ./bin/wayu` (to q press) |
| Input Lag | < 50ms | Manual testing (spam j/k keys, observe lag) |
| CLI Compatibility | 100% | All 255 existing tests pass |
| Memory Usage | < 10MB | Activity Monitor / htop during 5min TUI session |
| Terminal Support | 95%+ | Test on iTerm2, Terminal.app, Alacritty, Kitty |

### Qualitative Targets

| Metric | Target | Measurement Method |
|--------|--------|-------------------|
| Discoverability | High | New user navigates without docs |
| Feature Awareness | High | All features visible in main menu |
| UX Consistency | Excellent | Matches existing style system |
| Keyboard Efficiency | High | No unnecessary keystrokes |
| Error Feedback | Clear | Users understand errors |

---

## Confidence Score

**9/10** - Very High Confidence for One-Pass Implementation Success

**Rationale**:
- ✅ **Existing foundation**: 4,551 lines of TUI-ready code already written (fuzzy finder, forms, styling)
- ✅ **Clear patterns**: Three research agents provided comprehensive context with exact file/line references
- ✅ **Proven patterns**: Existing fuzzy.odin demonstrates production-ready terminal control
- ✅ **No dependencies**: Pure Odin implementation, no external library risks
- ✅ **Validation strategy**: 4-level validation with 255 existing tests as regression safety net
- ⚠️ **One complexity**: Terminal size detection requires platform-specific ioctl (documented with examples)

**Risk Factors** (mitigated):
- Platform-specific constants (TIOCGWINSZ) → Clear examples provided for macOS + Linux
- Differential rendering performance → Research shows Ratatui achieved 55% speedup, pattern documented
- Signal handler constraints → Documented with "c" convention requirement and examples

---

## Next Steps

1. **Read Research Documents**:
   - `/Users/kakurega/dev/projects/wayu/docs/references/TUI_DESIGN_PATTERNS.md` (comprehensive)
   - Agent research reports (saved in context)

2. **Start Implementation**:
   - Begin with Phase 1 (Terminal Infrastructure) - most critical
   - Follow task order strictly (dependencies matter)
   - Run validation after each phase

3. **Continuous Validation**:
   - Compile after each file
   - Run unit tests after each module
   - Test TUI manually after Phase 5
   - Run full test suite before marking complete

4. **Iterate**:
   - If Level 1-3 validation passes → proceed to next phase
   - If validation fails → debug, fix, re-validate before moving forward

---

**Status**: ✅ READY FOR IMPLEMENTATION
**Confidence**: 9/10 for one-pass success
**Total Estimated Effort**: 12-18 days (across 7 phases)
**Blocking Issues**: None - all context provided

---

**Document Metadata**:
- **Version**: 1.0.0
- **Created**: 2025-10-16
- **Author**: Claude (AI Assistant) via PRP Base Template
- **Research Agents**: 3 parallel agents (codebase patterns, Odin capabilities, TUI best practices)
- **Lines of Context**: 90,000+ tokens of research findings
- **Files Referenced**: 20+ wayu source files, 45+ external URLs
