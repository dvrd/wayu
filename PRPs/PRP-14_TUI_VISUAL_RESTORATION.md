name: "PRP-14: TUI Visual Restoration - Multi-Panel Layouts & Color System"
description: |
  Transform the plain monochrome TUI into a modern, visually rich interface with colored panels,
  bordered windows, and proper geometric layout. Restores search windows, preview panels, and
  visual hierarchy that users expect from modern terminal applications.

version: "1.0.0"
created: "2025-10-16"
status: "READY_FOR_IMPLEMENTATION"

---

## Goal

**Feature Goal**: Transform wayu's TUI from plain monochrome text into a visually rich interface with colored panels, bordered windows, and multi-panel layouts for search, preview, and content display.

**Deliverable**:
- All 8 TUI views use ANSI colors for visual hierarchy (headers, selections, borders)
- Multi-panel layouts with left list panel + right preview panel (PATH, Alias, Constants views)
- Bordered panels using box-drawing characters (┌─┐│└┘)
- Color scheme with proper contrast for both dark/light backgrounds
- Focused panel indication with border color changes
- Zero functionality regressions - all existing features preserved

**Success Definition**:
- Every TUI view has colored output (headers, selections, borders, footers)
- PATH/Alias/Constants views display split layout (list + preview)
- Selection highlighting uses background colors, not just ">" prefix
- Panel borders change color to indicate focus
- Performance: No noticeable lag with 1000+ items
- Compatibility: Works in iTerm2, Alacritty, GNOME Terminal, Terminal.app
- All 255 existing tests pass with zero failures

---

## User Persona

**Target User**: Developers and system administrators who use wayu TUI for interactive configuration management

**Use Cases**:
- **Primary**: Developer navigates PATH entries and needs to see details before deleting
- **Secondary**: Admin browses aliases and wants visual feedback on selection
- **Tertiary**: User expects modern TUI appearance comparable to lazygit/k9s

**User Journey (Current Pain)**:
```
User launches wayu --tui
├─ Sees plain white text on black background
├─ No visual distinction between sections
├─ Selection marked only by ">" character
├─ No preview of what will be modified
└─ Exits to use CLI because TUI is hard to read
```

**User Journey (After Improvement)**:
```
User launches wayu --tui
├─ Sees colorful interface with clear sections
├─ Headers in yellow, selections in blue background
├─ Bordered panels separate list from preview
├─ Can see PATH entry details before deleting
└─ Stays in TUI - it's faster and clearer
```

**Pain Points Addressed**:
- **Visual clarity**: "I can't tell what's selected" → Blue background highlights selection
- **Context loss**: "I don't know what this PATH does" → Preview panel shows details
- **Professionalism**: "Looks like a 1990s app" → Modern colored panels like lazygit
- **Efficiency**: "Takes too long to find entries" → Clear visual hierarchy guides eyes

---

## Why

- **Business Value**: Makes wayu TUI competitive with modern CLI tools (lazygit, k9s, btop)
- **User Impact**: Reduces cognitive load through visual hierarchy, prevents accidental deletions via preview
- **Technical Debt**: TUI was implemented with color support but never activated (Cell fields exist but unused)
- **Competitive**: Industry standard for TUIs includes colors and panels (all major tools have them)
- **Problems Solved**:
  - For **Developers**: Faster navigation with visual feedback
  - For **Power users**: Preview before action prevents mistakes
  - For **Teams**: Professional appearance encourages adoption

---

## What

### User-Visible Behavior Changes

**Before (v2.1.0 - Plain Monochrome TUI)**:
```
Terminal output when launching `wayu --tui`:

wayu - Shell Configuration Manager
Press Esc or q to quit, Ctrl+C to exit

> 📂 PATH Configuration
  📛 Aliases
  🔧 Constants
  🧩 Plugins
  💾 Backups
  ⚙️  Settings
  ❓ Help

↑/k: up  ↓/j: down  Enter: select  Esc/q: quit

(All text is white on black, no colors, no borders)
```

**After (v2.2.0 - Colored Multi-Panel TUI)**:
```
Terminal output when launching `wayu --tui`:

┌─────────────────────────────────────────────────────────────────────────────┐
│ 🛠️  wayu - Shell Configuration Manager                                      │ [Yellow header]
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│                        ┌─────────────────────────────┐                      │
│                        │                             │                      │ [Blue border]
│                        │ ▶ 📂 PATH Configuration     │ [Blue background]    │
│                        │   📛 Aliases                │                      │
│                        │   🔧 Constants              │                      │
│                        │   🧩 Plugins                │                      │
│                        │   💾 Backups                │                      │
│                        │   ⚙️  Settings               │                      │
│                        │   ❓ Help                    │                      │
│                        │                             │                      │
│                        └─────────────────────────────┘                      │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│ ↑/k: up  ↓/j: down  Enter: select  Esc/q: quit                       [Gray] │
└─────────────────────────────────────────────────────────────────────────────┘

(Colors: Yellow headers, Blue selection background, Gray borders and footer)
```

**PATH View Before**:
```
📂 PATH Configuration
12 entries

> /usr/local/bin
  /usr/bin
  /bin
  $HOME/.local/bin

d=Delete  Esc=Back  ↑/↓ or j/k=Navigate
```

**PATH View After**:
```
┌──────────────────────┬──────────────────────────────────────────────────────┐
│ 📂 PATH (12)         │ Preview: /usr/local/bin                       [Yellow]│
├──────────────────────┼──────────────────────────────────────────────────────┤
│                      │                                                      │
│ ▶ /usr/local/bin     │ Directory: /usr/local/bin                     [Blue  │
│   /usr/bin           │ Status: ✓ Exists                               bg]   │
│   /bin               │ Contains: 2,048 entries                              │
│   $HOME/.local/bin   │                                                      │
│                      │ This directory contains user-installed binaries      │
│                      │ and scripts commonly used for development tools.     │
│                      │                                                      │
├──────────────────────┴──────────────────────────────────────────────────────┤
│ d=Delete  /=Search  Enter=Select  Esc=Back  ↑/↓ j/k=Navigate         [Gray] │
└─────────────────────────────────────────────────────────────────────────────┘

Left panel: List with blue highlight on selection
Right panel: Preview showing details of selected item
Borders: Gray when not focused, cyan when focused
```

### Technical Requirements

**Color System**:
- Use ANSI 256-color palette for compatibility
- Semantic colors: PRIMARY (headers), SELECTED (background), DIM (footer)
- Border colors: NORMAL (gray) vs FOCUSED (cyan/blue)
- Always end with RESET (`\x1b[0m`) to prevent color bleeding

**Panel System**:
- Fixed layout calculations (30% left, 70% right for split views)
- Centered panel for main menu (35 chars wide, vertically centered)
- Full-width header (line 0) and footer (line height-2)
- Content panels respect borders (1 char padding on all sides)

**Rendering Architecture**:
- Cell struct ALREADY supports `fg`, `bg`, `bold`, `dim` fields (tui_screen.odin:6-12)
- screen_flush() ALREADY handles ANSI codes (tui_render.odin:29-50)
- Only need to SET these fields when creating cells
- Differential rendering continues to work (Cell comparison includes all fields)

### Success Criteria

**Visual Quality**:
- [ ] All 8 views use colors (headers yellow, selections blue, borders gray)
- [ ] Main menu has centered bordered panel
- [ ] PATH/Alias/Constants views have split layout (list + preview)
- [ ] Selection uses background color, not just ">" prefix
- [ ] Borders change color when panel focused

**Functionality**:
- [ ] All existing TUI features work (navigation, selection, deletion)
- [ ] Performance: No lag with 1000+ items
- [ ] Terminal resize updates layouts correctly
- [ ] Colors work in iTerm2, Alacritty, GNOME Terminal, Terminal.app

**Testing**:
- [ ] 255 existing tests pass (218 unit + 27 integration + 10 UI)
- [ ] Manual visual checklist completed (colors visible, correct contrast)
- [ ] No memory leaks (valgrind clean)

---

## All Needed Context

### Context Completeness Check

✅ **Validation**: This PRP includes:
- Exact file:line references for all 8 view renderers
- Specific ANSI 256-color codes to use (no guessing)
- Complete Cell structure with fg/bg fields already defined
- URLs to color standards and TUI design patterns
- Code snippets showing exact Cell creation syntax
- Gotchas with mitigation strategies (fmt.tprintf memory, color comparison)
- Testing strategy acknowledging screen_to_string() strips ANSI codes

### Documentation & References

```yaml
# MUST READ - ANSI Color Standards
- url: https://gist.github.com/fnky/458719343aabd01cfb17a3a4f7296797
  why: Comprehensive ANSI escape code reference (regularly updated)
  critical: Covers 256-color format (\x1b[38;5;Nm) and box-drawing characters

- url: https://www.ditig.com/256-colors-cheat-sheet
  why: Visual 256-color palette with RGB values
  critical: Use this to pick color numbers (e.g., 252 for light gray, 24 for dark blue)

- url: https://en.wikipedia.org/wiki/Box-drawing_character#Box_Drawing
  section: "Box Drawing" table with U+2500-U+257F range
  critical: Single-line characters ┌─┐│└┘ for borders

# MUST READ - TUI Design Patterns
- url: https://ratatui.rs/concepts/layout/
  why: Constraint-based layout system (for future enhancement)
  critical: Learn from Rust's leading TUI library

- url: https://k9scli.io/topics/skins/
  why: Production TUI color configuration examples
  critical: Shows semantic color usage (success=green, error=red, focus=blue)

# MUST READ - Accessibility
- url: https://dubbot.com/dubblog/2023/dark-mode-a11y.html
  why: WCAG contrast requirements for dark mode
  critical: Text needs 4.5:1 contrast ratio, avoid pure black (#000)

# MUST READ - Existing wayu Patterns
- file: /Users/kakurega/dev/projects/wayu/src/tui/tui_screen.odin
  why: Cell struct with fg/bg fields ALREADY DEFINED
  pattern: Lines 6-12 (Cell :: struct with fg, bg, bold, dim)
  critical: These fields exist but are NEVER SET in current code

- file: /Users/kakurega/dev/projects/wayu/src/tui/tui_render.odin
  why: screen_flush() ALREADY handles ANSI codes
  pattern: Lines 29-50 (applies fg/bg/bold/dim if fields are set)
  critical: No changes needed to rendering logic - it's ready for colors!

- file: /Users/kakurega/dev/projects/wayu/src/tui/tui_views.odin
  why: All 8 view renderers use identical pattern
  pattern: Lines 57-59 (PATH), 114-116 (Alias), 171-173 (Constants), etc.
  critical: All use Cell{char = ch} - need to add fg/bg/bold fields

- file: /Users/kakurega/dev/projects/wayu/src/colors.odin
  why: CLI color system with adaptive profiles
  pattern: Lines 67-82 (VIBRANT palette), 108-151 (detection), 170-200 (getters)
  gotcha: TUI package (wayu_tui) doesn't import main wayu package - can't use these directly

# MUST READ - Component Testing System
- file: /Users/kakurega/dev/projects/wayu/src/tui/tui_components.odin
  why: Headless rendering for golden file tests
  pattern: Lines 127-192 (render_component)
  gotcha: screen_to_string() strips ANSI codes - golden files are plain text only!

# Color Codes to Use (256-color palette)
semantic_colors:
  # Foreground
  TUI_FG_NORMAL:    "\x1b[38;5;252m"  # Light gray (252) - body text
  TUI_FG_SELECTED:  "\x1b[38;5;231m"  # White (231) - selected text
  TUI_FG_HIGHLIGHT: "\x1b[38;5;226m"  # Yellow (226) - headers
  TUI_FG_DIM:       "\x1b[38;5;243m"  # Dim gray (243) - footer
  TUI_FG_SUCCESS:   "\x1b[38;5;46m"   # Green (46) - success indicators
  TUI_FG_ERROR:     "\x1b[38;5;196m"  # Red (196) - error indicators

  # Background
  TUI_BG_NORMAL:    "\x1b[48;5;235m"  # Dark gray (235) - normal bg
  TUI_BG_SELECTED:  "\x1b[48;5;24m"   # Dark blue (24) - selection bg
  TUI_BG_HEADER:    "\x1b[48;5;237m"  # Slightly lighter gray (237)

  # Borders
  TUI_BORDER_NORMAL:  "\x1b[38;5;240m"  # Gray (240) - inactive
  TUI_BORDER_FOCUSED: "\x1b[38;5;33m"   # Blue (33) - active

  # Special
  TUI_RESET: "\x1b[0m"  # Reset all formatting

box_drawing_characters:
  corners: "┌ ┐ └ ┘"  # U+250C, U+2510, U+2514, U+2518
  lines:   "─ │"      # U+2500 (horizontal), U+2502 (vertical)
  t_junctions: "├ ┤ ┬ ┴"  # For split panels
```

### Current Codebase Tree

```bash
wayu/
├── src/
│   ├── tui/
│   │   ├── tui_screen.odin         # [READ] Cell struct (lines 6-12)
│   │   ├── tui_render.odin         # [MODIFY] Add styled rendering functions
│   │   ├── tui_views.odin          # [MODIFY] Update all 8 view renderers
│   │   ├── tui_main.odin           # [MODIFY] Update main menu renderer (lines 221-254)
│   │   ├── tui_colors.odin         # [CREATE] Color constants
│   │   ├── tui_panel.odin          # [CREATE] Panel layout system (optional, Phase 4+)
│   │   ├── tui_components.odin     # [READ] Component testing (lines 127-192)
│   │   └── tui_state.odin          # [NO CHANGE] State management
│   │
│   └── colors.odin                 # [READ] CLI color patterns (lines 67-82)
│
├── tests/
│   ├── unit/
│   │   └── test_tui_colors.odin    # [CREATE] Unit tests for color functions
│   │
│   └── ui/
│       └── test_tui_visual.odin    # [CREATE] Visual regression tests
│
└── docs/
    └── research/                   # [READ] Research reports from agents
        ├── TUI_RENDERING_RESEARCH.md
        ├── CLI_COLOR_SYSTEM_RESEARCH.md
        ├── ANSI_CODES_RESEARCH.md
        └── PANEL_LAYOUT_RESEARCH.md
```

### Known Gotchas & Patterns

```odin
// GOTCHA #1: fmt.tprintf() uses temp allocator
// Current pattern in all 8 views:
text := fmt.tprintf("> %s", entry)
render_text(screen, 2, y, text)
// DO NOT call delete(text) - it's temp-allocated!
// This is CORRECT - tprintf uses temporary allocator

// GOTCHA #2: Cell comparison for differential rendering
// screen_flush() at tui_render.odin:20 does:
if !force_full_render && curr == prev do continue
// This compares ALL Cell fields (char, fg, bg, bold, dim)
// Impact: Adding colors means more cells marked "changed" on first frame
// Mitigation: After first frame, only changed cells re-render (works correctly)

// GOTCHA #3: screen_to_string() strips ANSI codes
// File: tui_screen.odin:109-127
screen_to_string :: proc(screen: ^Screen) -> string {
    // Only outputs characters, NO ANSI codes
    // Used for golden file generation
}
// Impact: Cannot test colors with component test system
// Mitigation: Manual visual testing + unit tests for Cell fields

// GOTCHA #4: TUI package isolation
// wayu_tui package does NOT import main wayu package (avoids circular deps)
// Impact: Can't use colors.odin functions like get_primary()
// Mitigation: Define TUI-specific color constants in tui_colors.odin

// GOTCHA #5: Color strings are pointers, not allocations
// Cell fields fg/bg are strings pointing to constants:
cell := Cell{char = 'A', fg = TUI_FG_HIGHLIGHT}  // fg points to constant
// DO NOT delete cell.fg - it's not allocated!
// Memory: Only char (4 bytes) + pointers (16 bytes) + bools (2 bytes) = 22 bytes per Cell

// PATTERN: Current Cell creation (all 8 views use this)
Cell{char = ch}  // Only sets char field

// PATTERN: New Cell creation with colors
Cell{char = ch, fg = TUI_FG_NORMAL, bg = "", bold = false, dim = false}

// PATTERN: Selected item (with background color)
Cell{char = ch, fg = TUI_FG_SELECTED, bg = TUI_BG_SELECTED, bold = true, dim = false}

// PATTERN: Border rendering
Cell{char = '┌', fg = TUI_BORDER_NORMAL, bg = "", bold = false, dim = false}

// PATTERN: Always reset after colored section
// Not needed! screen_flush() handles this automatically by comparing prev/curr cells
// It only emits ANSI codes when fg/bg changes, and automatically resets
```

---

## Implementation Blueprint

### Data Models and Structure

```odin
// NEW FILE: src/tui/tui_colors.odin
// Color constants for TUI (256-color ANSI codes)

package wayu_tui

// Foreground colors (256-color palette)
TUI_FG_NORMAL    :: "\x1b[38;5;252m"  // Light gray (252) - readable on dark bg
TUI_FG_SELECTED  :: "\x1b[38;5;231m"  // White (231) - maximum contrast
TUI_FG_HIGHLIGHT :: "\x1b[38;5;226m"  // Yellow (226) - headers, attention
TUI_FG_DIM       :: "\x1b[38;5;243m"  // Dim gray (243) - secondary info
TUI_FG_SUCCESS   :: "\x1b[38;5;46m"   // Green (46) - positive indicators
TUI_FG_ERROR     :: "\x1b[38;5;196m"  // Red (196) - error indicators

// Background colors
TUI_BG_NORMAL    :: "\x1b[48;5;235m"  // Dark gray (235) - normal background
TUI_BG_SELECTED  :: "\x1b[48;5;24m"   // Dark blue (24) - selection background
TUI_BG_HEADER    :: "\x1b[48;5;237m"  // Slightly lighter gray (237) - headers

// Border colors
TUI_BORDER_NORMAL   :: "\x1b[38;5;240m"  // Gray (240) - inactive borders
TUI_BORDER_FOCUSED  :: "\x1b[38;5;33m"   // Blue (33) - active panel borders

// Special
TUI_RESET        :: "\x1b[0m"  // Reset all formatting (not needed in Cells, but useful)

// Box drawing characters
BOX_HORIZONTAL      :: '─'  // U+2500
BOX_VERTICAL        :: '│'  // U+2502
BOX_TOP_LEFT        :: '┌'  // U+250C
BOX_TOP_RIGHT       :: '┐'  // U+2510
BOX_BOTTOM_LEFT     :: '└'  // U+2514
BOX_BOTTOM_RIGHT    :: '┘'  // U+2518
BOX_LEFT_T          :: '├'  // U+251C
BOX_RIGHT_T         :: '┤'  // U+2524
BOX_TOP_T           :: '┬'  // U+252C
BOX_BOTTOM_T        :: '┴'  // U+2534
BOX_CROSS           :: '┼'  // U+253C
```

```odin
// EXISTING: src/tui/tui_screen.odin (NO CHANGES NEEDED)
// Cell struct ALREADY supports colors (lines 6-12)
Cell :: struct {
    char:  rune,
    fg:    string,  // ✅ Ready for ANSI codes
    bg:    string,  // ✅ Ready for ANSI codes
    bold:  bool,    // ✅ Ready for bold text
    dim:   bool,    // ✅ Ready for dim text
}

// Screen struct ALREADY supports differential rendering (lines 14-21)
Screen :: struct {
    buffer:      [][]Cell,      // Current frame
    prev_buffer: [][]Cell,      // Previous frame for diff
    width:       int,
    height:      int,
    cursor_x:    int,
    cursor_y:    int,
}

// screen_flush() ALREADY handles ANSI codes (tui_render.odin:29-50)
// It compares curr vs prev cells and only emits codes when fields change
```

```odin
// NEW: Enhanced rendering functions (add to tui_render.odin)

// Render text with styling
render_text_styled :: proc(screen: ^Screen, x, y: int, text: string,
                          fg: string = "", bg: string = "",
                          bold: bool = false, dim: bool = false) {
    current_x := x
    for ch in text {
        if current_x >= screen.width do break

        cell := Cell{
            char = ch,
            fg = fg,
            bg = bg,
            bold = bold,
            dim = dim,
        }
        screen_set_cell(screen, current_x, y, cell)
        current_x += 1
    }
}

// Render box with colored borders
render_box_styled :: proc(screen: ^Screen, x, y, width, height: int, border_color: string = "") {
    if width < 2 || height < 2 do return

    // Top border
    screen_set_cell(screen, x, y, Cell{char = BOX_TOP_LEFT, fg = border_color})
    for i in 1..<width-1 {
        screen_set_cell(screen, x+i, y, Cell{char = BOX_HORIZONTAL, fg = border_color})
    }
    screen_set_cell(screen, x+width-1, y, Cell{char = BOX_TOP_RIGHT, fg = border_color})

    // Sides
    for j in 1..<height-1 {
        screen_set_cell(screen, x, y+j, Cell{char = BOX_VERTICAL, fg = border_color})
        screen_set_cell(screen, x+width-1, y+j, Cell{char = BOX_VERTICAL, fg = border_color})
    }

    // Bottom border
    screen_set_cell(screen, x, y+height-1, Cell{char = BOX_BOTTOM_LEFT, fg = border_color})
    for i in 1..<width-1 {
        screen_set_cell(screen, x+i, y+height-1, Cell{char = BOX_HORIZONTAL, fg = border_color})
    }
    screen_set_cell(screen, x+width-1, y+height-1, Cell{char = BOX_BOTTOM_RIGHT, fg = border_color})
}
```

### Implementation Tasks (Ordered by Dependencies)

```yaml
PHASE 1: Color System Foundation (Priority: CRITICAL, Hours: 2-3)

Task 1.1: CREATE src/tui/tui_colors.odin
  - IMPLEMENT: Color constants (TUI_FG_*, TUI_BG_*, TUI_BORDER_*)
  - IMPLEMENT: Box drawing character constants (BOX_*)
  - NAMING: Use TUI_ prefix to distinguish from CLI colors
  - PLACEMENT: New file in src/tui/ directory
  - RUN: odin check src/tui/tui_colors.odin
  - EXPECTED: Compiles with zero errors

Task 1.2: MODIFY src/tui/tui_render.odin - Add styled rendering functions
  - FIND: After line 82 (end of render_text)
  - ADD: render_text_styled() function (from blueprint above)
  - ADD: render_box_styled() function (from blueprint above)
  - IMPORT: Import tui_colors constants
  - RUN: odin check src/tui/tui_render.odin
  - EXPECTED: Compiles, exports new functions

Task 1.3: MODIFY src/tui/tui_views.odin - Update PATH view (TEST CASE)
  - FIND: Lines 38-41 (PATH view header)
  - CURRENT:
    render_text(screen, 2, 1, "📂 PATH Configuration")
    count_text := fmt.tprintf("%d entries", len(items))
    render_text(screen, 2, 2, count_text)
  - REPLACE with:
    render_text_styled(screen, 2, 1, "📂 PATH Configuration",
                      TUI_FG_HIGHLIGHT, "", true)  // Yellow, bold
    count_text := fmt.tprintf("%d entries", len(items))
    render_text_styled(screen, 2, 2, count_text, TUI_FG_DIM)  // Dim gray
  - FIND: Lines 55-64 (PATH view list items)
  - CURRENT:
    if i == state.selected_index {
        text := fmt.tprintf("> %s", entry)
        render_text(screen, 2, y, text)
    } else {
        text := fmt.tprintf("  %s", entry)
        render_text(screen, 4, y, text)
    }
  - REPLACE with:
    if i == state.selected_index {
        text := fmt.tprintf("> %s", entry)
        render_text_styled(screen, 2, y, text,
                          TUI_FG_SELECTED, TUI_BG_SELECTED, true)  // White on blue
    } else {
        text := fmt.tprintf("  %s", entry)
        render_text_styled(screen, 4, y, text, TUI_FG_NORMAL)  // Light gray
    }
  - FIND: Lines 76-77 (PATH view footer)
  - REPLACE footer rendering with styled version using TUI_FG_DIM
  - RUN: task build-dev
  - TEST: ./bin/wayu --tui → Navigate to PATH view → Verify colors appear

PHASE 2: Apply Colors to Remaining Views (Priority: HIGH, Hours: 2-3)

Task 2.1: MODIFY render_alias_view (lines 85-135)
  - APPLY same color pattern as PATH view (header, items, footer)
  - Header: TUI_FG_HIGHLIGHT + bold
  - Selected: TUI_FG_SELECTED + TUI_BG_SELECTED + bold
  - Normal: TUI_FG_NORMAL
  - Footer: TUI_FG_DIM

Task 2.2: MODIFY render_constants_view (lines 142-192)
  - APPLY same pattern

Task 2.3: MODIFY render_backups_view (lines 215-265)
  - APPLY same pattern

Task 2.4: MODIFY render_main_menu in tui_main.odin (lines 221-254)
  - APPLY same pattern to menu

Task 2.5: MODIFY render_settings_view (lines 286-304)
  - APPLY colors to static settings display

Task 2.6: MODIFY render_completions_view, render_plugins_view (placeholders)
  - APPLY colors to header text

Task 2.7: BUILD and MANUAL TEST
  - RUN: task build-dev
  - TEST: Launch TUI, navigate through ALL 8 views
  - VERIFY: Colors appear correctly in every view
  - CHECK: No crashes, no visual glitches

PHASE 3: Add Panel Borders (Priority: MEDIUM, Hours: 2-3)

Task 3.1: MODIFY render_main_menu - Add centered border
  - CALCULATE: Center position (width-35)/2 for 35-char menu width
  - ADD: render_box_styled() call around menu items
  - USE: TUI_BORDER_FOCUSED (menu is always focused)

Task 3.2: MODIFY render_path_view - Add full-screen border
  - ADD: render_box_styled(screen, 0, 0, width, height, TUI_BORDER_NORMAL)
  - ADJUST: Content coordinates to avoid border overlap (x+1, y+1)

Task 3.3: REPEAT for other list views
  - Alias, Constants, Backups views get borders

Task 3.4: MANUAL TEST borders
  - VERIFY: Borders appear, no overlap with content
  - VERIFY: Content stays within borders

PHASE 4: Implement Split Layouts (Priority: MEDIUM, Hours: 3-4)

Task 4.1: CREATE split layout calculation function (tui_panel.odin)
  - NEW FILE: src/tui/tui_panel.odin
  - IMPLEMENT:
    calculate_split_layout :: proc(screen_width, screen_height: int) -> (
        list_x, list_y, list_w, list_h: int,
        preview_x, preview_y, preview_w, preview_h: int,
    ) {
        // 30/70 split
        split_x := screen_width * 30 / 100

        // Header takes line 0-2, footer takes last 2 lines
        content_start_y := 3
        content_height := screen_height - 5

        // List panel (left 30%)
        list_x = 0
        list_y = content_start_y
        list_w = split_x
        list_h = content_height

        // Preview panel (right 70%)
        preview_x = split_x + 1  // +1 for separator
        preview_y = content_start_y
        preview_w = screen_width - split_x - 1
        preview_h = content_height

        return
    }

Task 4.2: MODIFY render_path_view to use split layout
  - CALCULATE split dimensions
  - RENDER list panel on left with borders
  - RENDER preview panel on right with borders
  - IMPLEMENT preview content generation (selected PATH details)

Task 4.3: APPLY split layout to Alias view
  - Show alias definition in preview

Task 4.4: APPLY split layout to Constants view
  - Show constant value and type in preview

Task 4.5: MANUAL TEST split layouts
  - VERIFY: Panels don't overlap
  - VERIFY: Content stays in correct panel
  - VERIFY: Terminal resize updates correctly

PHASE 5: Polish & Testing (Priority: HIGH, Hours: 2-3)

Task 5.1: CREATE unit tests (tests/unit/test_tui_colors.odin)
  - TEST: Color constants are non-empty strings
  - TEST: render_text_styled sets Cell fields correctly
  - TEST: render_box_styled creates correct border cells

Task 5.2: MANUAL visual testing checklist
  - TEST: All 8 views in iTerm2
  - TEST: All 8 views in Alacritty
  - TEST: All 8 views in GNOME Terminal
  - TEST: Colors work on dark background
  - TEST: Colors work on light background

Task 5.3: Performance testing
  - TEST: Navigate PATH view with 1000+ entries
  - MEASURE: No noticeable lag
  - PROFILE: Memory usage (should be minimal increase)

Task 5.4: Regression testing
  - RUN: task test:all
  - VERIFY: 255 tests pass (218 unit + 27 integration + 10 UI)
  - VERIFY: Component tests still pass (plain text golden files)

Task 5.5: Documentation updates
  - UPDATE: CLAUDE.md with new TUI features
  - UPDATE: README.md with TUI screenshot
  - CREATE: docs/TUI_COLORS.md explaining color system
```

### Implementation Patterns & Key Details

```odin
// PATTERN 1: Simple color application (most common)
// Before:
render_text(screen, x, y, "Header Text")

// After:
render_text_styled(screen, x, y, "Header Text", TUI_FG_HIGHLIGHT, "", true)
//                                                ^^^^^^^^^^^^^ fg  ^^ bg  ^^^^ bold

// PATTERN 2: Selection highlighting (used in all list views)
// Before:
if i == state.selected_index {
    text := fmt.tprintf("> %s", entry)
    render_text(screen, 2, y, text)
}

// After:
if i == state.selected_index {
    text := fmt.tprintf("> %s", entry)
    render_text_styled(screen, 2, y, text, TUI_FG_SELECTED, TUI_BG_SELECTED, true)
    // ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^  ^^^^^^^^^^^^^^  ^^^^^^^^^^^^^^^^  ^^^^
    // Keep ">" prefix          White text    Blue background  Bold
}

// PATTERN 3: Bordered panel (used in all views after Phase 3)
// Add at START of view renderer (before content):
render_box_styled(screen, 0, 0, screen.width, screen.height, TUI_BORDER_NORMAL)
// Then render content inside border (coordinates +1)

// PATTERN 4: Split layout calculation (Phase 4)
list_x, list_y, list_w, list_h, preview_x, preview_y, preview_w, preview_h :=
    calculate_split_layout(screen.width, screen.height)

// Render left panel
render_box_styled(screen, list_x, list_y, list_w, list_h, TUI_BORDER_NORMAL)
// Render list content inside (coordinates +1 for padding)

// Render right panel
render_box_styled(screen, preview_x, preview_y, preview_w, preview_h, TUI_BORDER_NORMAL)
// Render preview content inside

// PATTERN 5: Memory management (NO CHANGES NEEDED)
// Cell fields are pointers to string constants (not allocated)
cell := Cell{char = 'A', fg = TUI_FG_HIGHLIGHT}  // fg is pointer, not allocation
// DO NOT delete cell.fg!
// Existing defer patterns continue to work unchanged
```

---

## Validation Loop

### Level 1: Syntax & Compilation (Immediate Feedback)

```bash
# After each file modification

# Compile new color file
odin check src/tui/tui_colors.odin
# Expected: Zero errors, color constants defined

# Compile modified render file
odin check src/tui/tui_render.odin
# Expected: Zero errors, new functions exported

# Compile modified views file
odin check src/tui/tui_views.odin
# Expected: Zero errors, render_text_styled calls valid

# Build entire project
task build-dev
# Expected: Compiles successfully with zero errors

# Check for warnings
odin build src/tui -out:bin/wayu_tui_test -warnings-as-errors
# Expected: Clean build, no warnings
```

### Level 2: Unit Tests (Component Validation)

```bash
# Run existing unit tests (must not break)
task test
# Expected: 218/218 tests pass (no regressions)

# Run new TUI color tests
odin test tests/unit/test_tui_colors.odin -file
# Expected: All color tests pass

# Test Cell field assignment
# Unit test should verify:
cell := Cell{char = 'A', fg = TUI_FG_HIGHLIGHT, bold = true}
assert(cell.fg == TUI_FG_HIGHLIGHT)
assert(cell.bold == true)
```

### Level 3: Manual Visual Testing (CRITICAL - Cannot be automated)

```bash
# CRITICAL: screen_to_string() strips ANSI codes, so colors can't be tested automatically!
# Manual testing is the ONLY way to verify colors work correctly

# Test in iTerm2 (macOS)
./bin/wayu --tui
# Navigate through all 8 views:
# - Main menu: Enter
# - PATH view: See yellow header, blue selection background
# - Back: Esc
# - Alias view: Same pattern
# - Constants view: Same pattern
# - Backups view: Same pattern
# - Settings view: Colored text
# - Help view: Colored text

# Test in Alacritty
alacritty -e ./bin/wayu --tui
# Repeat navigation, verify colors appear

# Test in GNOME Terminal (Linux)
./bin/wayu --tui
# Repeat navigation

# Test in Terminal.app (macOS)
./bin/wayu --tui
# Repeat navigation

# Visual Checklist:
# [ ] Headers are yellow/bright color
# [ ] Selected items have blue background
# [ ] Normal items are light gray text
# [ ] Footers are dimmed gray text
# [ ] Borders are visible (gray)
# [ ] No color bleeding (text after TUI is normal)
# [ ] Emojis are visible and bold
# [ ] No visual glitches or corruption

# Test terminal resize
# 1. Launch TUI
# 2. Resize terminal window (make smaller)
# 3. Verify layout updates correctly
# 4. Resize larger
# 5. Verify no visual corruption
```

### Level 4: Integration Testing (System Validation)

```bash
# Run all existing tests
task test:all
# Expected: 255 tests pass (218 unit + 27 integration + 10 UI)

# Verify component tests still work (they test layout, not colors)
task test:components
# Expected: All golden file tests pass (plain text comparison)

# Test TUI functionality with colors enabled
./bin/wayu --tui
# 1. Navigate to PATH view
# 2. Select an entry (arrow down)
# 3. Delete it (press 'd', confirm)
# 4. Verify entry removed
# 5. Exit TUI
# 6. Relaunch TUI
# 7. Verify deletion persisted

# Performance test with large dataset
# 1. Add 1000+ PATH entries (script)
# 2. Launch TUI
# 3. Navigate PATH view
# 4. Scroll through list (press 'j' repeatedly)
# 5. Verify no lag, smooth scrolling
# 6. Check memory usage (ps aux | grep wayu)

# Memory leak check (valgrind on Linux)
valgrind --leak-check=full ./bin/wayu --tui
# 1. Navigate all 8 views
# 2. Exit
# 3. Verify: "All heap blocks were freed"
```

---

## Final Validation Checklist

### Technical Validation

**Compilation:**
- [ ] tui_colors.odin compiles without errors
- [ ] tui_render.odin compiles with new functions
- [ ] All TUI files compile: `task build-dev`
- [ ] No compiler warnings: `odin build -warnings-as-errors`

**Testing:**
- [ ] All 218 unit tests pass: `task test`
- [ ] All 27 integration tests pass: `task test:integration`
- [ ] All 10 UI tests pass: `tests/ui/`
- [ ] New color unit tests pass
- [ ] NO test regressions: 255+ total tests passing

**Code Quality:**
- [ ] No memory leaks: `valgrind --leak-check=full`
- [ ] No use-after-free errors
- [ ] Cell fields set correctly (unit tested)
- [ ] screen_flush() handles colors (already implemented)

### Feature Validation

**Color System:**
- [ ] Headers use TUI_FG_HIGHLIGHT (yellow) and bold
- [ ] Selected items use TUI_BG_SELECTED (blue background)
- [ ] Normal text uses TUI_FG_NORMAL (light gray)
- [ ] Footers use TUI_FG_DIM (dim gray)
- [ ] Borders use TUI_BORDER_NORMAL (gray) or TUI_BORDER_FOCUSED (blue)

**All 8 Views Colored:**
- [ ] Main menu: Colored title, blue selection, gray footer
- [ ] PATH view: Yellow header, blue selection, dim footer
- [ ] Alias view: Colored header, selection, footer
- [ ] Constants view: Colored header, selection, footer
- [ ] Completions view: Colored header (placeholder)
- [ ] Backups view: Colored header, selection, footer
- [ ] Plugins view: Colored header (placeholder)
- [ ] Settings view: Colored text

**Panel Borders (Phase 3):**
- [ ] Main menu has centered bordered panel
- [ ] PATH view has full-screen border
- [ ] All list views have borders
- [ ] Borders don't overlap with content
- [ ] Content stays within border bounds

**Split Layouts (Phase 4):**
- [ ] PATH view shows list (left) + preview (right)
- [ ] Alias view shows list + definition preview
- [ ] Constants view shows list + value preview
- [ ] Panels don't overlap
- [ ] Content clips correctly to panel bounds

**Terminal Compatibility:**
- [ ] Colors work in iTerm2 (macOS)
- [ ] Colors work in Alacritty (cross-platform)
- [ ] Colors work in GNOME Terminal (Linux)
- [ ] Colors work in Terminal.app (macOS)
- [ ] Colors work on dark background
- [ ] Colors work on light background (test with light theme)

**Performance:**
- [ ] No lag with 100 items
- [ ] No lag with 1000+ items
- [ ] Scrolling is smooth (no dropped frames)
- [ ] Terminal resize is fast (<100ms)
- [ ] Memory usage stable (no leaks)

**Functionality (No Regressions):**
- [ ] Navigation works: ↑/↓, j/k, Enter, Esc
- [ ] Selection works: Items highlight on arrow keys
- [ ] Deletion works: 'd' key removes entries
- [ ] Data persists: Changes saved to config files
- [ ] TUI exits cleanly: Esc or 'q' to quit

---

## Anti-Patterns to Avoid

**Color System Anti-Patterns**:
- ❌ Don't hardcode ANSI codes in view files - use tui_colors constants
- ❌ Don't forget to set bg="" for normal text (avoid unintended backgrounds)
- ❌ Don't use pure white (#FFF) or pure black (#000) - causes halation
- ❌ Don't mix true color and 256-color codes - stick to 256 for compatibility

**Memory Management Anti-Patterns**:
- ❌ Don't delete Cell.fg or Cell.bg - they're pointers to constants
- ❌ Don't delete fmt.tprintf() results - they use temp allocator
- ❌ Don't forget defer delete() on manually allocated strings

**Testing Anti-Patterns**:
- ❌ Don't rely on golden files for color validation - they strip ANSI codes
- ❌ Don't skip manual visual testing - it's the ONLY way to verify colors
- ❌ Don't test only one terminal - verify in at least 3 different emulators
- ❌ Don't skip performance testing - colors add overhead

**Rendering Anti-Patterns**:
- ❌ Don't render borders after content - they'll overwrite text
- ❌ Don't forget to adjust content coordinates after adding borders (+1 padding)
- ❌ Don't use screen.width/height directly - account for borders
- ❌ Don't assume fixed terminal size - handle resize events

**Code Anti-Patterns**:
- ❌ Don't modify screen_flush() - it already handles colors correctly
- ❌ Don't modify Cell struct - it already has all needed fields
- ❌ Don't import wayu colors.odin in tui package - causes circular deps
- ❌ Don't leave debug print statements in final code

---

## Success Metrics

### Quantitative Targets

| Metric | Target | Measurement Method |
|--------|--------|-------------------|
| **Test Pass Rate** | 100% | `task test:all` - 255+ tests pass |
| **Views with Colors** | 8/8 (100%) | Manual inspection of all views |
| **Terminal Compatibility** | 4/4 | iTerm2, Alacritty, GNOME Terminal, Terminal.app |
| **Performance (1000 items)** | <16ms per frame | 60 FPS smooth scrolling |
| **Memory Overhead** | <100KB | Cell size increase (22 bytes → ~40 bytes with strings) |
| **Code Coverage** | 100% | All view renderers updated |

### Qualitative Targets

| Metric | Target | Measurement Method |
|--------|--------|-------------------|
| **Visual Hierarchy** | Excellent | Headers, content, footer clearly distinguished |
| **Selection Clarity** | High | Blue background makes selection obvious |
| **Professional Appearance** | Good | Comparable to lazygit/k9s visual quality |
| **Usability** | Improved | Faster navigation with visual feedback |
| **Accessibility** | Pass | 4.5:1 contrast ratio (WCAG AA) |

### User Experience Goals

| Goal | Target | Success Criteria |
|------|--------|------------------|
| **First Impression** | Modern and professional | New users say "wow" not "meh" |
| **Navigation Speed** | 2x faster | Users find entries quicker with colors |
| **Error Prevention** | Fewer mistakes | Preview panel prevents accidental deletions |
| **Satisfaction** | High | Users prefer TUI over CLI |

---

## Confidence Score

**8.5/10** - High Confidence for One-Pass Implementation Success

**Rationale**:
- ✅ **Architecture is ready**: Cell fields exist, screen_flush() handles ANSI codes
- ✅ **Simple change**: Just setting Cell fields, not refactoring rendering system
- ✅ **Clear research**: 4 agent reports with 122KB of documentation
- ✅ **Exact references**: File:line numbers for all 8 view renderers
- ✅ **Proven patterns**: Colors work in CLI, same ANSI codes for TUI
- ✅ **Comprehensive tests**: 255 existing tests as regression safety net
- ⚠️ **Manual testing required**: Cannot automate color validation (screen_to_string strips ANSI)
- ⚠️ **Layout complexity**: Split panels need careful calculation (but we start simple)

**Risk Factors** (mitigated):
- Colors can't be automatically tested → Manual checklist with multiple terminals
- Panel layouts might need iteration → Phased approach, start with borders only
- Performance with colors unknown → Test early with 1000+ items, profile if needed

**Why 8.5/10**:
- Same confidence as PRP-13 because change is simpler (no exit code refactoring)
- Extensive research reduces unknowns
- Clear implementation path with concrete examples
- Testing strategy accounts for limitations

---

## Next Steps

1. **Review This PRP**:
   - Verify all file:line references are accurate
   - Confirm ANSI color codes are correct (test in terminal)
   - Review phased approach makes sense

2. **Begin Implementation**:
   - Start with Phase 1 (Color System Foundation)
   - Follow task order strictly (dependencies matter)
   - Test after each phase before proceeding

3. **Continuous Validation**:
   - Compile after each file modification
   - Run unit tests after each phase
   - Manual visual test after Phase 1 (critical!)
   - Full test suite after Phase 5

4. **Documentation**:
   - Update CLAUDE.md with TUI color system
   - Take screenshots for README.md
   - Create TUI_COLORS.md explaining color constants

---

**Document Status**: ✅ READY FOR IMPLEMENTATION
**Confidence**: 8.5/10 for one-pass success
**Total Estimated Effort**: 12-16 hours over 3-5 days
**Blocking Issues**: None - all context provided
**Prerequisites**: wayu v2.1.0 codebase, Odin compiler, test suite, iTerm2/Alacritty for testing

---

**Document Metadata**:
- **Version**: 1.0.0
- **Created**: 2025-10-16
- **Author**: Claude (AI Assistant) via PRP Base Template
- **Research Agents**: 4 parallel agents (TUI rendering, CLI colors, ANSI standards, panel layouts)
- **Research Size**: 122 KB, 3,065 lines across 4 documents
- **Files Referenced**: 12 wayu TUI files with exact line numbers
- **External URLs**: 10+ authoritative sources with section anchors
- **Gotchas Documented**: 5 critical patterns with mitigation strategies
- **Implementation Tasks**: 25 ordered tasks with dependencies across 5 phases
