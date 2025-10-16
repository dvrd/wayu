# PRP-14: TUI Visual Restoration - Multi-Panel Layout & Color System

**Type**: BASE (Implementation-Ready Specification)
**Status**: Ready for Implementation
**Priority**: High
**Estimated Effort**: 19-27 hours over 2-3 weeks
**Target Version**: v2.2.0
**Created**: 2025-10-16
**Research Phase Completed**: 2025-10-16

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Problem Statement](#problem-statement)
3. [Research Findings](#research-findings)
4. [Solution Architecture](#solution-architecture)
5. [Implementation Plan](#implementation-plan)
6. [Technical Specifications](#technical-specifications)
7. [Testing Strategy](#testing-strategy)
8. [Risk Assessment](#risk-assessment)
9. [Timeline & Milestones](#timeline--milestones)
10. [Success Criteria](#success-criteria)
11. [Approval & Next Steps](#approval--next-steps)
12. [References](#references)

---

## Executive Summary

### Current State

The wayu TUI (Terminal User Interface) is **functionally complete** but **visually plain**:
- ✅ Full interactivity with keyboard navigation
- ✅ The Elm Architecture (TEA) with state management
- ✅ Differential rendering for performance
- ❌ **Monochrome text** (no colors despite Cell.fg/bg support)
- ❌ **No bordered panels** (render_box() exists but unused)
- ❌ **No visual hierarchy** (fixed absolute positioning)
- ❌ **No preview panels** (single list view only)

### User Feedback

> "antes teníamos ventanas para búsqueda, preview y títulos"
> *(we used to have windows for search, preview, and titles)*

The user expects:
- **Bordered panels** ("ventanas") with box-drawing characters
- **Preview panels** showing details of selected items
- **Search overlays** for filtering
- **Colorful interface** with visual hierarchy

### Proposed Solution

Transform the TUI from plain monochrome text to a **modern, visually rich interface** comparable to lazygit, lazydocker, and k9s:

**Phase 1: Color System + Borders** (MVP - 6-8 hours)
- Add ANSI color constants throughout TUI
- Implement colored text and border rendering
- Update all 8 views with colors and panel borders

**Phase 2: Multi-Panel Layout** (Full Feature - 10-14 hours)
- Implement panel abstraction system
- Create split layouts (30/70 list + preview)
- Migrate views to panel-based rendering

**Phase 3: Polish** (Advanced Features - 3-5 hours)
- Search overlay panels
- Enhanced scroll indicators
- Performance optimization

### Key Benefits

- **Professional appearance** - Matches quality of popular TUIs
- **Improved usability** - Visual hierarchy guides attention
- **Preview context** - See what will happen before acting
- **Searchability** - Filter large lists interactively
- **Low risk** - 90% of infrastructure already exists

### Strategic Alignment

- **Backwards compatible** - No breaking changes to TUI API
- **Leverages existing code** - Cell.fg/bg, render_box(), differential rendering
- **Incremental delivery** - Each phase delivers value independently
- **Performance maintained** - < 50ms frame time (differential rendering)

---

## Problem Statement

### Current State Analysis

#### 1. No Visual Structure

**Evidence from codebase:**
```odin
// src/tui/tui_views.odin:26-78 (PATH View example)
render_path_view :: proc(state: ^TUIState, screen: ^Screen) {
    render_text(screen, 2, 1, "📂 PATH Configuration")  // Plain text, no colors
    render_text(screen, 2, 2, count_text)               // Absolute positioning

    for i in start..<end {
        if i == state.selected_index {
            render_text(screen, 2, y, fmt.tprintf("> %s", entry))  // Just "> " prefix
        } else {
            render_text(screen, 4, y, fmt.tprintf("  %s", entry))  // Indentation only
        }
    }

    render_text(screen, 2, footer_y, "d=Delete  Esc=Back...")  // Footer at bottom
}
```

**Problems:**
- No borders or panels - just text scattered on screen
- No color differentiation - everything is default terminal color
- Selection indicated only by "> " prefix (no background highlighting)
- No spatial organization - relies entirely on whitespace

#### 2. Unused Color Infrastructure

**Evidence from codebase:**
```odin
// src/tui/tui_screen.odin:6-12
Cell :: struct {
    char:  rune,
    fg:    string,   // ✓ EXISTS but never populated in views
    bg:    string,   // ✓ EXISTS but never populated in views
    bold:  bool,
    dim:   bool,
}
```

**Problem:** Infrastructure exists but is completely unused. The `screen_flush()` function already handles colors correctly (src/tui/tui_render.odin:29-50), but no view populates `Cell.fg` or `Cell.bg`.

#### 3. Border Function Unused

**Evidence from codebase:**
```odin
// src/tui/tui_render.odin:85-107
render_box :: proc(screen: ^Screen, x, y, width, height: int) {
    // Draws boxes with ┌─┐│└┘ characters
    // BUT: Never called by any view!
}
```

**Problem:** Box rendering exists but views don't use it. No panel structure.

#### 4. Single-Panel Views Only

**Current layout pattern:**
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   📂 PATH Configuration                                                      │
│   12 entries                                                                │
│                                                                             │
│   > /usr/local/bin                                                          │
│     /usr/bin                                                                │
│     /bin                                                                    │
│     /usr/sbin                                                               │
│     /sbin                                                                   │
│     $HOME/.local/bin                                                        │
│     $HOME/go/bin                                                            │
│     $HOME/.cargo/bin                                                        │
│     /opt/homebrew/bin                                                       │
│     /opt/local/bin                                                          │
│                                                                             │
│                                                                             │
│                                                                             │
│                                                                             │
│                                                                             │
│                                                                             │
│   d=Delete  Esc=Back  ↑/↓ or j/k=Navigate                                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Problems:**
- No preview panel showing what `/usr/local/bin` contains
- No context about selected item (exists? size? last modified?)
- Large empty space not utilized
- No search capability visible

### User Impact

#### Usability Issues
1. **Difficult to scan** - All text looks the same, no visual anchors
2. **Unclear selection** - "> " prefix is subtle, easy to miss
3. **No context** - Can't see details without executing action
4. **Wasted space** - Large terminals show mostly empty screen

#### Aesthetic Issues
1. **Unprofessional appearance** - Looks unfinished compared to:
   - lazygit: Multi-panel with colors and borders
   - lazydocker: Split view with preview
   - k9s: Rich color scheme and panels
2. **Cognitive load** - No visual hierarchy to guide attention
3. **Context switching** - Must remember what each view does

#### Functional Limitations
1. **No search** - Can't filter long lists interactively
2. **No preview** - Can't see what action will do before committing
3. **No help text** - Shortcuts buried in footer

### Target State Design

#### Visual Mockup - PATH View with Multi-Panel Layout (80x24)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 📂 PATH Configuration                                              12 entries│
├──────────────────────┬──────────────────────────────────────────────────────┤
│                      │                                                      │
│ Search: /usr/bin     │ Preview: /usr/bin                                    │
│ ──────────────────── │ ──────────────────────────────────────────────────── │
│                      │                                                      │
│ > /usr/local/bin     │ Directory: /usr/local/bin                            │
│   /usr/bin           │ Status: ✓ Exists                                     │
│   /bin               │ Size: 2,048 entries                                  │
│   /usr/sbin          │                                                      │
│   /sbin              │ This directory contains user-installed binaries      │
│   $HOME/.local/bin   │ and scripts. Common location for custom tools.       │
│   $HOME/go/bin       │                                                      │
│   $HOME/.cargo/bin   │ Last modified: 2025-10-15 14:23:45                   │
│   /opt/homebrew/bin  │                                                      │
│   /opt/local/bin     │                                                      │
│                      │                                                      │
│                      │                                                      │
│                      │                                                      │
│                      │                                                      │
│                      │                                                      │
│                      │                                                      │
├──────────────────────┴──────────────────────────────────────────────────────┤
│ ↑/k: up  ↓/j: down  Enter: select  /: search  d: delete  Esc: back  q: quit│
└─────────────────────────────────────────────────────────────────────────────┘
```

**Key improvements:**
1. **Bordered panels** - Clear visual separation with box-drawing characters
2. **30/70 split** - List on left (30%), preview on right (70%)
3. **Search box** - Visible filtering at top of list panel
4. **Preview content** - Shows details of selected item
5. **Color scheme** - Headers bright, selected items highlighted, dim shortcuts
6. **Focused borders** - Active panel has distinct color

#### Visual Mockup - Main Menu with Centered Panel (80x24)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 🛠️  wayu - Shell Configuration Manager                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│                                                                             │
│                        ┌─────────────────────────────┐                      │
│                        │                             │                      │
│                        │ > 📂 PATH Configuration     │                      │
│                        │   📛 Aliases                │                      │
│                        │   🔧 Constants              │                      │
│                        │   🧩 Plugins                │                      │
│                        │   💾 Backups                │                      │
│                        │   ⚙️  Settings               │                      │
│                        │   ❓ Help                    │                      │
│                        │                             │                      │
│                        └─────────────────────────────┘                      │
│                                                                             │
│                                                                             │
│                                                                             │
│                                                                             │
│                                                                             │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│ ↑/k: up  ↓/j: down  Enter: select  Esc/q: quit                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Key improvements:**
1. **Centered panel** - Professional menu presentation
2. **Full-width header** - Application title and context
3. **Emoji visibility** - Bold/bright to stand out
4. **Selected highlighting** - Background color, not just prefix
5. **Border styling** - Distinct visual frame

---

## Research Findings

### Research Phase Overview

Four comprehensive research agents were deployed to gather context:

1. **TUI Rendering Patterns Agent** - Analyzed existing wayu TUI architecture
2. **ANSI Color Implementation Agent** - Documented color system in main package
3. **Panel/Layout Systems Agent** - Researched modern TUI design patterns
4. **ANSI Standards Agent** - Collected authoritative escape code documentation

**Total research output:** ~15,000 words across 4 comprehensive reports

### Key Finding 1: Infrastructure is 90% Ready

**From TUI Rendering Research:**

✅ **Cell structure supports colors:**
```odin
Cell :: struct {
    fg: string,  // Already exists, ready for ANSI codes
    bg: string,  // Already exists, ready for ANSI codes
    bold: bool,
    dim: bool,
}
```

✅ **screen_flush() handles colors correctly:**
```odin
// src/tui/tui_render.odin:29-50
if curr.fg != prev.fg && curr.fg != "" {
    fmt.sbprintf(&builder, "%s", curr.fg)  // Emits ANSI code
}
if curr.bg != prev.bg && curr.bg != "" {
    fmt.sbprintf(&builder, "%s", curr.bg)  // Emits ANSI code
}
```

✅ **render_box() already exists:**
```odin
// src/tui/tui_render.odin:85-107
render_box :: proc(screen: ^Screen, x, y, width, height: int) {
    // Uses ┌─┐│└┘ box-drawing characters
}
```

**Conclusion:** We don't need to build rendering infrastructure - just use what exists!

### Key Finding 2: Color System is Comprehensive

**From ANSI Color Research:**

Main package (`src/colors.odin`) has a complete color system:
- 24-bit TrueColor RGB: `\x1b[38;2;R;G;Bm`
- 256-color palette: `\x1b[38;5;Nm`
- Basic 16-color ANSI: `\x1b[31m` (red), etc.
- Terminal capability detection (NO_COLOR, COLORTERM, TERM)

**Color palette already defined** (Zellij "dvrd" theme):
```odin
VIBRANT_PRIMARY   :: "\x1b[38;2;228;0;80m"     // Hot pink #E40050
VIBRANT_SECONDARY :: "\x1b[38;2;14;116;144m"   // Teal-cyan #0E7490
VIBRANT_SUCCESS   :: "\x1b[38;2;14;116;144m"   // Teal
VIBRANT_ERROR     :: "\x1b[38;2;153;27;27m"    // Dark red #991B1B
VIBRANT_WARNING   :: "\x1b[38;2;217;119;6m"    // Orange #D97706
VIBRANT_MUTED     :: "\x1b[38;2;208;208;208m"  // Light gray
```

**Problem:** TUI package cannot import main package (circular dependency).

**Solution:** Duplicate color constants in new file `src/tui/tui_colors.odin`.

### Key Finding 3: Panel Patterns from Popular TUIs

**From Panel/Layout Research:**

**Lazygit pattern (most popular):**
- Fixed 6-panel layout
- 30/70 split between main panels
- Border focus indicators (color changes)
- Vim-style navigation (j/k)

**Lazydocker pattern:**
- 2-panel horizontal split
- Tabbed right panel for different views
- Single focus point with clear visual indicator

**K9s pattern:**
- Header bar + main content area
- Context-aware detail panels
- Real-time updates

**Common patterns:**
1. **30/70 split** - Most popular for list + detail
2. **Border style changes** - Focused panel has different color
3. **Scroll indicators** - Show more content available (▲ ▼)
4. **Keyboard shortcuts in footer** - Always visible

### Key Finding 4: ANSI Standards and Box-Drawing

**From ANSI Standards Research:**

**Official standards:**
- ECMA-48 (5th Edition, 1991)
- ISO/IEC 6429:1992
- Unicode Box Drawing Block (U+2500-U+257F)

**SGR (Select Graphic Rendition) codes:**
```
ESC[0m      Reset all attributes
ESC[1m      Bold
ESC[2m      Dim
ESC[31m     Red foreground
ESC[41m     Red background
ESC[38;2;R;G;Bm  True color foreground
ESC[48;2;R;G;Bm  True color background
```

**Box-drawing characters:**
```
Light:   ┌─┐│└┘  (U+250C, U+2500, U+2510, U+2502, U+2514, U+2518)
Rounded: ╭─╮│╰╯  (U+256D, U+2500, U+256E, U+2502, U+256F, U+2570)
Heavy:   ┏━┓┃┗┛  (U+250F, U+2501, U+2513, U+2503, U+2517, U+251B)
Double:  ╔═╗║╚╝  (U+2554, U+2550, U+2557, U+2551, U+255A, U+255D)
```

**Terminal support:**
- TrueColor: iTerm, VS Code, Kitty, Alacritty, WezTerm
- 256-color: Nearly universal in modern terminals
- Box-drawing: All monospaced fonts

### Research-Backed Recommendations

1. **Use TrueColor RGB** - wayu already targets modern terminals
2. **Duplicate color constants** - Avoid circular dependency
3. **Implement 30/70 split** - Industry standard for list + preview
4. **Light box-drawing style** - Most compatible, professional look
5. **< 50ms frame time target** - User perception threshold

---

## Solution Architecture

### High-Level Approach

**Incremental Enhancement Strategy:**
1. Add color support without changing architecture
2. Implement panel abstraction layer
3. Migrate views one at a time
4. Maintain backwards compatibility throughout

**NOT a rewrite** - Leverage existing code:
- ✅ Keep TEA (The Elm Architecture) pattern
- ✅ Keep differential rendering
- ✅ Keep bridge system for data loading
- ✅ Keep existing event handling

### Technical Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                           TUI Main Loop                             │
│                    (src/tui/tui_main.odin)                          │
│                                                                     │
│  State ───► Update ───► View ───► Render ───► Screen Buffer        │
│    ▲          │          │          │               │              │
│    │          │          │          │               │              │
│    └──────────┘          │          │               ▼              │
│                          │          │        screen_flush()         │
│                          │          │          (diff render)        │
│                          │          │               │              │
│                          │          │               ▼              │
│                          │          │           Terminal           │
│                          │          │                              │
│                          │          └──────► Panel System ◄────┐   │
│                          │                  (NEW)               │   │
│                          │                    │                 │   │
│                          └──────► Views ──────┤                 │   │
│                                   (MODIFIED)  │                 │   │
│                                               │                 │   │
│                                   ┌───────────┴────────────┐    │   │
│                                   │                        │    │   │
│                               Layout        Panel       Colors  │   │
│                             (NEW struct)  (NEW struct) (NEW)    │   │
│                                   │           │           │     │   │
│                                   └───────────┴───────────┘     │   │
│                                         Panel Renderer ─────────┘   │
│                                             (NEW)                   │
└─────────────────────────────────────────────────────────────────────┘
```

### Module Dependencies

```
wayu_tui package
│
├── tui_main.odin         (existing - minimal changes)
├── tui_state.odin        (existing - no changes)
├── tui_screen.odin       (existing - no changes, already supports colors)
├── tui_render.odin       (existing - add color variants)
│   ├── render_text()            [existing]
│   ├── render_box()             [existing]
│   ├── render_text_colored()    [NEW]
│   └── render_box_colored()     [NEW]
│
├── tui_colors.odin       [NEW FILE]
│   ├── TUI_PRIMARY, TUI_SECONDARY, etc. [color constants]
│   └── TUI_RESET, TUI_BOLD, TUI_DIM     [formatting constants]
│
├── tui_panel.odin        [NEW FILE - Phase 2]
│   ├── Panel struct
│   ├── Layout struct
│   ├── create_split_layout()
│   ├── create_menu_layout()
│   └── render_panel()
│
└── tui_views.odin        (existing - modified to use colors and panels)
    ├── render_main_menu()       [Phase 1: colors, Phase 3: panels]
    ├── render_path_view()       [Phase 1: colors, Phase 3: panels]
    ├── render_alias_view()      [Phase 1: colors, Phase 3: panels]
    ├── render_constants_view()  [Phase 1: colors, Phase 3: panels]
    ├── render_backups_view()    [Phase 1: colors, Phase 3: panels]
    └── ... (5 more views)
```

### Color System Architecture

#### Problem: Circular Dependency

```
wayu package (main)
├── colors.odin       (has comprehensive color system)
├── tui_bridge_impl.odin
│
└─► wayu_tui package
    ├── tui_main.odin
    └── tui_views.odin

    ❌ CANNOT IMPORT wayu package (would create circular dependency)
```

#### Solution: Duplicate Color Constants

Create `src/tui/tui_colors.odin`:

```odin
package wayu_tui

// True color constants (24-bit RGB)
// NOTE: Duplicated from src/colors.odin to avoid circular dependency
// Theme: Zellij "dvrd" inspired palette

// Primary colors
TUI_PRIMARY   :: "\x1b[38;2;228;0;80m"     // Hot pink #E40050
TUI_SECONDARY :: "\x1b[38;2;14;116;144m"   // Teal-cyan #0E7490

// Semantic colors
TUI_SUCCESS   :: "\x1b[38;2;14;116;144m"   // Teal (success indicators)
TUI_ERROR     :: "\x1b[38;2;153;27;27m"    // Dark red #991B1B
TUI_WARNING   :: "\x1b[38;2;217;119;6m"    // Orange #D97706
TUI_INFO      :: "\x1b[38;2;14;116;144m"   // Teal-cyan

// UI element colors
TUI_HIGHLIGHT :: "\x1b[38;2;228;0;80m"     // Hot pink (highlights)
TUI_MUTED     :: "\x1b[38;2;208;208;208m"  // Light gray (dim text)
TUI_DIM       :: "\x1b[38;2;100;100;100m"  // Dimmer gray

// Background colors
TUI_BG_NORMAL   :: "\x1b[48;2;24;24;37m"   // Dark purple-blue
TUI_BG_SELECTED :: "\x1b[48;2;9;9;11m"     // Almost black (selection)
TUI_BG_HEADER   :: "\x1b[48;2;18;18;27m"   // Slightly lighter than normal

// Border colors
TUI_BORDER_NORMAL  :: "\x1b[38;2;100;100;100m"  // Gray (inactive)
TUI_BORDER_FOCUSED :: "\x1b[38;2;228;0;80m"     // Hot pink (active)

// Control codes
TUI_RESET :: "\x1b[0m"
TUI_BOLD  :: "\x1b[1m"
TUI_DIM   :: "\x1b[2m"
```

**Rationale:**
- ✅ Zero dependencies - TUI package remains self-contained
- ✅ Fast - Constants, no function calls
- ✅ Simple - Easy to understand and maintain
- ⚠️ Maintenance - Must sync if main colors change (low frequency)

### Panel System Architecture

#### Panel Abstraction

```odin
// src/tui/tui_panel.odin (NEW FILE - Phase 2)

PanelType :: enum {
    HEADER,        // Full-width top panel with title
    FOOTER,        // Full-width bottom panel with shortcuts
    LIST,          // Scrollable vertical list
    PREVIEW,       // Detail view for selected item
    MENU,          // Centered menu panel
}

Panel :: struct {
    type:       PanelType,
    x, y:       int,           // Top-left position
    width:      int,           // Panel width
    height:     int,           // Panel height
    title:      string,        // Optional title
    focused:    bool,          // Is this panel focused?

    // Styling
    border_fg:  string,        // Border color (empty = use default)
    bg:         string,        // Background color

    // Content (union of different panel types)
    content: union {
        ListContent,
        PreviewContent,
        MenuContent,
    },
}

ListContent :: struct {
    items:          []string,
    selected_index: int,
    scroll_offset:  int,
    emoji_prefix:   string,  // e.g., "📂 "
}

PreviewContent :: struct {
    lines:          []string,
    scroll_offset:  int,
}

MenuContent :: struct {
    items:          []string,
    selected_index: int,
}

Layout :: struct {
    screen_width:  int,
    screen_height: int,
    panels:        [dynamic]Panel,
}
```

#### Layout Creation Functions

```odin
// Create 30/70 split layout (list left, preview right)
create_split_layout :: proc(screen_width, screen_height: int) -> Layout {
    split_x := screen_width * 30 / 100

    header := Panel{
        type = .HEADER,
        x = 0, y = 0,
        width = screen_width,
        height = 3,
        border_fg = TUI_BORDER_NORMAL,
    }

    list_panel := Panel{
        type = .LIST,
        x = 0, y = 3,
        width = split_x,
        height = screen_height - 5,
        focused = true,
        border_fg = TUI_BORDER_FOCUSED,
    }

    preview_panel := Panel{
        type = .PREVIEW,
        x = split_x + 1, y = 3,
        width = screen_width - split_x - 1,
        height = screen_height - 5,
        focused = false,
        border_fg = TUI_BORDER_NORMAL,
    }

    footer := Panel{
        type = .FOOTER,
        x = 0, y = screen_height - 2,
        width = screen_width,
        height = 2,
        border_fg = TUI_BORDER_NORMAL,
    }

    layout := Layout{
        screen_width = screen_width,
        screen_height = screen_height,
    }
    append(&layout.panels, header)
    append(&layout.panels, list_panel)
    append(&layout.panels, preview_panel)
    append(&layout.panels, footer)

    return layout
}

// Create centered menu layout
create_menu_layout :: proc(screen_width, screen_height: int) -> Layout {
    menu_width := 35
    menu_height := 12
    menu_x := (screen_width - menu_width) / 2
    menu_y := (screen_height - menu_height) / 2

    header := Panel{
        type = .HEADER,
        x = 0, y = 0,
        width = screen_width,
        height = 3,
        border_fg = TUI_BORDER_NORMAL,
    }

    menu_panel := Panel{
        type = .MENU,
        x = menu_x, y = menu_y,
        width = menu_width,
        height = menu_height,
        focused = true,
        border_fg = TUI_BORDER_FOCUSED,
    }

    footer := Panel{
        type = .FOOTER,
        x = 0, y = screen_height - 2,
        width = screen_width,
        height = 2,
        border_fg = TUI_BORDER_NORMAL,
    }

    layout := Layout{
        screen_width = screen_width,
        screen_height = screen_height,
    }
    append(&layout.panels, header)
    append(&layout.panels, menu_panel)
    append(&layout.panels, footer)

    return layout
}

// Destroy layout and free memory
layout_destroy :: proc(layout: ^Layout) {
    delete(layout.panels)
}
```

#### Panel Rendering

```odin
// High-level panel renderer
render_panel :: proc(screen: ^Screen, panel: ^Panel) {
    // Draw border
    border_color := panel.focused ? TUI_BORDER_FOCUSED : TUI_BORDER_NORMAL
    if panel.border_fg != "" {
        border_color = panel.border_fg
    }
    render_box_colored(screen, panel.x, panel.y, panel.width, panel.height, border_color)

    // Draw title if present
    if panel.title != "" {
        title_x := panel.x + 2
        title_y := panel.y
        render_text_colored(screen, title_x, title_y, panel.title, TUI_PRIMARY, TUI_BG_HEADER)
    }

    // Draw content based on panel type
    switch panel.type {
    case .LIST:
        render_list_content(screen, panel)
    case .PREVIEW:
        render_preview_content(screen, panel)
    case .MENU:
        render_menu_content(screen, panel)
    case .HEADER:
        render_header_content(screen, panel)
    case .FOOTER:
        render_footer_content(screen, panel)
    }
}

// Render list panel content
render_list_content :: proc(screen: ^Screen, panel: ^Panel) {
    content := panel.content.(ListContent)

    visible_height := panel.height - 2  // Subtract borders
    start_idx := content.scroll_offset
    end_idx := min(start_idx + visible_height, len(content.items))

    for i in start_idx..<end_idx {
        y := panel.y + 1 + (i - start_idx)
        x := panel.x + 2

        item_text := content.items[i]
        if content.emoji_prefix != "" {
            item_text = fmt.tprintf("%s%s", content.emoji_prefix, item_text)
        }

        if i == content.selected_index {
            // Selected item: highlight with background
            render_text_colored(screen, x, y,
                fmt.tprintf("> %s", item_text),
                TUI_PRIMARY, TUI_BG_SELECTED)
        } else {
            // Normal item
            render_text_colored(screen, x, y,
                fmt.tprintf("  %s", item_text),
                TUI_MUTED, "")
        }
    }
}

// Render preview panel content
render_preview_content :: proc(screen: ^Screen, panel: ^Panel) {
    content := panel.content.(PreviewContent)

    visible_height := panel.height - 2
    start_idx := content.scroll_offset
    end_idx := min(start_idx + visible_height, len(content.lines))

    for i in start_idx..<end_idx {
        y := panel.y + 1 + (i - start_idx)
        x := panel.x + 2
        line := content.lines[i]
        render_text_colored(screen, x, y, line, TUI_MUTED, "")
    }
}
```

### Integration with Existing Architecture

#### No Changes to TEA Pattern

```odin
// src/tui/tui_main.odin - Event loop (NO CHANGES)

tui_run :: proc() {
    state := tui_state_init()
    defer tui_state_cleanup(&state)

    for !state.should_exit {
        // Update (handle input)
        input := tui_poll_input()
        tui_update(&state, input)

        // View + Render
        screen_clear(&state.screen)
        tui_render(&state, &state.screen)  // Calls view renderers
        screen_flush(&state.screen)
    }
}
```

**Only change:** View renderers (tui_views.odin) use panels instead of direct render_text().

#### Backward Compatible State

```odin
// src/tui/tui_state.odin - State machine (NO CHANGES)

TUIState :: struct {
    current_view:    TUIView,
    selected_index:  int,
    scroll_offset:   int,
    terminal_width:  int,
    terminal_height: int,
    // ... existing fields unchanged

    // NO NEW FIELDS NEEDED - panels created per-frame in renderers
}
```

**Why no state changes?** Panels are ephemeral - created during render, destroyed after. No need to store in state.

---

## Implementation Plan

### Phase Overview

| Phase | Goal | Effort | Deliverable |
|-------|------|--------|-------------|
| Phase 1 | Color System + Borders | 6-8 hours | Colorful TUI with panel borders |
| Phase 2 | Multi-Panel Layout | 10-14 hours | Split views with preview panels |
| Phase 3 | Polish & Advanced Features | 3-5 hours | Search, scroll indicators, optimization |
| **Total** | **Full Visual Restoration** | **19-27 hours** | **Production-ready modern TUI** |

**Incremental Delivery:** Each phase delivers value independently. Can stop after Phase 1 if desired.

---

### Phase 1: Color System + Borders (MVP)

**Duration:** 6-8 hours
**Goal:** Transform monochrome TUI to colorful interface with bordered panels
**Complexity:** Low - Simple additions, no architectural changes

#### Task 1.1: Create Color Constants File (30 min)

**File:** `src/tui/tui_colors.odin` (NEW)

**Implementation:**
```odin
package wayu_tui

// Color constants file
// NOTE: Duplicated from src/colors.odin to avoid circular dependency

// Primary colors
TUI_PRIMARY   :: "\x1b[38;2;228;0;80m"     // Hot pink #E40050
TUI_SECONDARY :: "\x1b[38;2;14;116;144m"   // Teal-cyan #0E7490

// Semantic colors
TUI_SUCCESS :: "\x1b[38;2;14;116;144m"   // Teal
TUI_ERROR   :: "\x1b[38;2;153;27;27m"    // Dark red
TUI_WARNING :: "\x1b[38;2;217;119;6m"    // Orange

// UI colors
TUI_HIGHLIGHT :: "\x1b[38;2;228;0;80m"   // Hot pink
TUI_MUTED     :: "\x1b[38;2;208;208;208m"  // Light gray
TUI_DIM       :: "\x1b[38;2;100;100;100m"  // Dimmer gray

// Backgrounds
TUI_BG_NORMAL   :: "\x1b[48;2;24;24;37m"   // Dark purple-blue
TUI_BG_SELECTED :: "\x1b[48;2;9;9;11m"     // Almost black
TUI_BG_HEADER   :: "\x1b[48;2;18;18;27m"   // Slightly lighter

// Borders
TUI_BORDER_NORMAL  :: "\x1b[38;2;100;100;100m"  // Gray
TUI_BORDER_FOCUSED :: "\x1b[38;2;228;0;80m"     // Hot pink

// Control codes
TUI_RESET :: "\x1b[0m"
TUI_BOLD  :: "\x1b[1m"
TUI_DIM   :: "\x1b[2m"
```

**Test:** `odin check src/tui/tui_colors.odin`

#### Task 1.2: Add Colored Rendering Functions (1-2 hours)

**File:** `src/tui/tui_render.odin` (MODIFY)

**Add these functions:**

```odin
// Render text with colors
render_text_colored :: proc(screen: ^Screen, x, y: int, text: string, fg, bg: string) {
    current_x := x
    for ch in text {
        if current_x >= screen.width do break
        cell := Cell{
            char = ch,
            fg = fg,
            bg = bg,
        }
        screen_set_cell(screen, current_x, y, cell)
        current_x += 1
    }
}

// Render box with colored borders
render_box_colored :: proc(screen: ^Screen, x, y, width, height: int, border_fg: string) {
    if width < 2 || height < 2 do return

    // Top border
    screen_set_cell(screen, x, y, Cell{char = '┌', fg = border_fg})
    for i in 1..<width-1 {
        screen_set_cell(screen, x+i, y, Cell{char = '─', fg = border_fg})
    }
    screen_set_cell(screen, x+width-1, y, Cell{char = '┐', fg = border_fg})

    // Sides
    for j in 1..<height-1 {
        screen_set_cell(screen, x, y+j, Cell{char = '│', fg = border_fg})
        screen_set_cell(screen, x+width-1, y+j, Cell{char = '│', fg = border_fg})
    }

    // Bottom border
    screen_set_cell(screen, x, y+height-1, Cell{char = '└', fg = border_fg})
    for i in 1..<width-1 {
        screen_set_cell(screen, x+i, y+height-1, Cell{char = '─', fg = border_fg})
    }
    screen_set_cell(screen, x+width-1, y+height-1, Cell{char = '┘', fg = border_fg})
}
```

**Test:**
```bash
odin test src/tui/tui_render.odin -file
```

#### Task 1.3: Update Main Menu View (1 hour)

**File:** `src/tui/tui_views.odin` OR `src/tui/tui_main.odin` (MODIFY)

**Before (current code):**
```odin
render_main_menu :: proc(state: ^TUIState, screen: ^Screen) {
    render_text(screen, 2, 1, "wayu - Shell Configuration Manager")

    menu_items := []string{
        "1. PATH Configuration",
        "2. Aliases",
        // ...
    }

    for item, i in menu_items {
        if i == state.selected_index {
            render_text(screen, 2, y, fmt.tprintf("> %s", item))
        } else {
            render_text(screen, 2, y, fmt.tprintf("  %s", item))
        }
    }
}
```

**After (with colors and border):**
```odin
render_main_menu :: proc(state: ^TUIState, screen: ^Screen) {
    // Draw outer border
    render_box_colored(screen, 0, 0, screen.width, screen.height, TUI_BORDER_NORMAL)

    // Header with color
    render_text_colored(screen, 2, 1, "🛠️  wayu - Shell Configuration Manager",
        TUI_PRIMARY, TUI_BG_HEADER)
    render_text_colored(screen, 2, 2, "Press Esc or q to quit, Ctrl+C to exit",
        TUI_DIM, "")

    menu_items := []string{
        "📂 PATH Configuration",
        "📛 Aliases",
        "🔧 Constants",
        "🧩 Plugins",
        "💾 Backups",
        "⚙️  Settings",
        "❓ Help",
    }

    // Centered menu panel
    menu_width := 35
    menu_height := len(menu_items) + 2
    menu_x := (screen.width - menu_width) / 2
    menu_y := (screen.height - menu_height) / 2

    render_box_colored(screen, menu_x, menu_y, menu_width, menu_height, TUI_BORDER_FOCUSED)

    for item, i in menu_items {
        y := menu_y + 1 + i
        if i == state.selected_index {
            render_text_colored(screen, menu_x + 2, y, fmt.tprintf("> %s", item),
                TUI_PRIMARY, TUI_BG_SELECTED)
        } else {
            render_text_colored(screen, menu_x + 2, y, fmt.tprintf("  %s", item),
                TUI_MUTED, "")
        }
    }

    // Footer
    footer_y := screen.height - 2
    render_text_colored(screen, 2, footer_y, "↑/k: up  ↓/j: down  Enter: select  Esc/q: quit",
        TUI_DIM, TUI_BG_HEADER)
}
```

**Changes:**
- ✅ Outer border with `render_box_colored()`
- ✅ Header with `TUI_PRIMARY` color and `TUI_BG_HEADER` background
- ✅ Centered menu panel with `TUI_BORDER_FOCUSED`
- ✅ Selected item with `TUI_PRIMARY` foreground and `TUI_BG_SELECTED` background
- ✅ Normal items with `TUI_MUTED` color
- ✅ Footer with `TUI_DIM` color
- ✅ Emojis in menu items for visual interest

**Test:**
```bash
task build && ./bin/wayu --tui
# Verify: Colors visible, borders drawn, menu centered, selection highlighted
```

#### Task 1.4: Update PATH View (1 hour)

**File:** `src/tui/tui_views.odin` (MODIFY)

**Before:**
```odin
render_path_view :: proc(state: ^TUIState, screen: ^Screen) {
    render_text(screen, 2, 1, "📂 PATH Configuration")
    render_text(screen, 2, 2, count_text)

    for i in start..<end {
        if i == state.selected_index {
            render_text(screen, 2, y, fmt.tprintf("> %s", entry))
        } else {
            render_text(screen, 4, y, fmt.tprintf("  %s", entry))
        }
    }

    render_text(screen, 2, footer_y, "d=Delete  Esc=Back...")
}
```

**After:**
```odin
render_path_view :: proc(state: ^TUIState, screen: ^Screen) {
    // Draw outer border
    render_box_colored(screen, 0, 0, screen.width, screen.height, TUI_BORDER_NORMAL)

    // Check if data loaded
    if state.data_cache[.PATH_VIEW] == nil {
        render_text_colored(screen, 2, 1, "📂 PATH Configuration", TUI_PRIMARY, TUI_BG_HEADER)
        render_text_colored(screen, 2, 3, "Loading...", TUI_MUTED, "")
        state.needs_refresh = true
        return
    }

    items := cast(^[dynamic]string)state.data_cache[.PATH_VIEW]

    // Header bar (full width)
    header_text := fmt.tprintf("📂 PATH Configuration%*s%d entries",
        screen.width - 26, "", len(items))
    render_text_colored(screen, 2, 1, header_text, TUI_PRIMARY, TUI_BG_HEADER)

    // List panel border
    list_x := 2
    list_y := 3
    list_width := screen.width - 4
    list_height := screen.height - 5
    render_box_colored(screen, list_x, list_y, list_width, list_height, TUI_BORDER_FOCUSED)

    if len(items) == 0 {
        render_text_colored(screen, list_x + 2, list_y + 2,
            "No PATH entries found", TUI_DIM, "")
    } else {
        // Render list items with scrolling
        visible_height := list_height - 2
        start := state.scroll_offset
        end := min(start + visible_height, len(items))

        for i in start..<end {
            y := list_y + 1 + (i - start)
            entry := items[i]

            if i == state.selected_index {
                // Selected: hot pink foreground, dark background
                render_text_colored(screen, list_x + 2, y,
                    fmt.tprintf("> %s", entry),
                    TUI_PRIMARY, TUI_BG_SELECTED)
            } else {
                // Normal: muted gray
                render_text_colored(screen, list_x + 2, y,
                    fmt.tprintf("  %s", entry),
                    TUI_MUTED, "")
            }
        }

        // Scroll indicator
        if len(items) > visible_height {
            scroll_info := fmt.tprintf("Showing %d-%d of %d", start+1, end, len(items))
            render_text_colored(screen, list_x + 2, list_y + list_height - 1,
                scroll_info, TUI_DIM, "")
        }
    }

    // Footer
    footer_y := screen.height - 2
    render_text_colored(screen, 2, footer_y,
        "d=Delete  Esc=Back  ↑/↓ or j/k=Navigate",
        TUI_DIM, TUI_BG_HEADER)
}
```

**Changes:**
- ✅ Outer border around entire view
- ✅ Header bar with item count, colored with `TUI_PRIMARY`
- ✅ List panel with focused border (`TUI_BORDER_FOCUSED`)
- ✅ Selected items with `TUI_PRIMARY` + `TUI_BG_SELECTED`
- ✅ Normal items with `TUI_MUTED`
- ✅ Scroll indicator with `TUI_DIM`
- ✅ Footer with `TUI_DIM` color

**Test:**
```bash
task build && ./bin/wayu --tui
# Navigate to PATH view
# Verify: Colors, borders, selection highlight, scroll indicator
```

#### Task 1.5: Update Remaining Views (2-3 hours)

Apply the same pattern to:
- `render_alias_view()` (Alias View)
- `render_constants_view()` (Constants View)
- `render_backups_view()` (Backups View)
- `render_completions_view()` (Completions View)
- `render_plugins_view()` (Plugins View)
- `render_settings_view()` (Settings View)

**Pattern:**
1. Add outer border
2. Color header with `TUI_PRIMARY` + `TUI_BG_HEADER`
3. Add list panel border with `TUI_BORDER_FOCUSED`
4. Color selected items with `TUI_PRIMARY` + `TUI_BG_SELECTED`
5. Color normal items with `TUI_MUTED`
6. Color footer with `TUI_DIM` + `TUI_BG_HEADER`

**Test each view:**
```bash
task build && ./bin/wayu --tui
# Navigate through all views
# Verify consistent styling across all views
```

#### Task 1.6: Testing & Refinement (1 hour)

**Manual testing:**
```bash
# Test in different terminal sizes
wayu --tui   # Default size
# Resize terminal to 80x24, 120x40, 200x60
# Verify colors and borders render correctly

# Test in different terminals
# iTerm2, Terminal.app, Alacritty, etc.
```

**Unit tests:**
Create `tests/unit/test_tui_colors.odin`:
```odin
package test

import "core:testing"
import tui "../src/tui"

@(test)
test_render_text_colored :: proc(t: ^testing.T) {
    screen := tui.screen_create(20, 5)
    defer tui.screen_destroy(&screen)

    tui.render_text_colored(&screen, 0, 0, "Hello", tui.TUI_PRIMARY, tui.TUI_BG_NORMAL)

    // Verify cells have colors
    testing.expect(t, screen.buffer[0][0].fg == tui.TUI_PRIMARY)
    testing.expect(t, screen.buffer[0][0].bg == tui.TUI_BG_NORMAL)
    testing.expect(t, screen.buffer[0][0].char == 'H')
}

@(test)
test_render_box_colored :: proc(t: ^testing.T) {
    screen := tui.screen_create(10, 5)
    defer tui.screen_destroy(&screen)

    tui.render_box_colored(&screen, 0, 0, 10, 5, tui.TUI_BORDER_NORMAL)

    // Verify corners have correct characters and colors
    testing.expect(t, screen.buffer[0][0].char == '┌')
    testing.expect(t, screen.buffer[0][0].fg == tui.TUI_BORDER_NORMAL)
    testing.expect(t, screen.buffer[0][9].char == '┐')
    testing.expect(t, screen.buffer[4][0].char == '└')
    testing.expect(t, screen.buffer[4][9].char == '┘')
}
```

Run tests:
```bash
task test
```

#### Phase 1 Deliverables

✅ **New file:** `src/tui/tui_colors.odin` (color constants)
✅ **Modified file:** `src/tui/tui_render.odin` (+2 functions)
✅ **Modified file:** `src/tui/tui_views.odin` (all 8 views updated)
✅ **New tests:** `tests/unit/test_tui_colors.odin`
✅ **Documentation:** Update CLAUDE.md with color system

#### Phase 1 Success Criteria

- [ ] All 8 views render with colors
- [ ] Borders visible around panels
- [ ] Selected items highlighted with background color
- [ ] Colors work in iTerm2, Terminal.app, Alacritty
- [ ] No performance regression (< 50ms per frame)
- [ ] All unit tests passing

**Result:** Monochrome TUI → Colorful TUI with borders (80% visual improvement!)

---

### Phase 2: Multi-Panel Layout System

**Duration:** 10-14 hours
**Goal:** Implement split-view layouts with list + preview panels
**Complexity:** Medium - New abstraction layer, view migration

#### Task 2.1: Create Panel System Core (3-4 hours)

**File:** `src/tui/tui_panel.odin` (NEW)

**Full implementation** (see Solution Architecture section for complete code):
```odin
package wayu_tui

import "core:fmt"

PanelType :: enum {
    HEADER, FOOTER, LIST, PREVIEW, MENU
}

Panel :: struct {
    type: PanelType,
    x, y, width, height: int,
    title: string,
    focused: bool,
    border_fg: string,
    bg: string,
    content: union {
        ListContent,
        PreviewContent,
        MenuContent,
    },
}

ListContent :: struct {
    items: []string,
    selected_index: int,
    scroll_offset: int,
    emoji_prefix: string,
}

PreviewContent :: struct {
    lines: []string,
    scroll_offset: int,
}

MenuContent :: struct {
    items: []string,
    selected_index: int,
}

Layout :: struct {
    screen_width, screen_height: int,
    panels: [dynamic]Panel,
}

create_split_layout :: proc(screen_width, screen_height: int) -> Layout { /* ... */ }
create_menu_layout :: proc(screen_width, screen_height: int) -> Layout { /* ... */ }
layout_destroy :: proc(layout: ^Layout) { /* ... */ }
render_panel :: proc(screen: ^Screen, panel: ^Panel) { /* ... */ }
render_list_content :: proc(screen: ^Screen, panel: ^Panel) { /* ... */ }
render_preview_content :: proc(screen: ^Screen, panel: ^Panel) { /* ... */ }
render_menu_content :: proc(screen: ^Screen, panel: ^Panel) { /* ... */ }
render_header_content :: proc(screen: ^Screen, panel: ^Panel) { /* ... */ }
render_footer_content :: proc(screen: ^Screen, panel: ^Panel) { /* ... */ }
```

**Test:**
```bash
odin check src/tui/tui_panel.odin
```

#### Task 2.2: Implement Preview Content Generators (2-3 hours)

**File:** `src/tui/tui_preview.odin` (NEW)

**Purpose:** Generate preview text for selected items in each view

```odin
package wayu_tui

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// Generate preview lines for a PATH entry
generate_path_preview :: proc(path: string) -> []string {
    lines := make([dynamic]string)

    // Expand environment variables
    expanded := expand_path(path)
    defer delete(expanded)

    // Header
    append(&lines, strings.clone("Preview: " + path))
    append(&lines, strings.repeat("─", 40))
    append(&lines, strings.clone(""))

    // Check if directory exists
    exists := os.exists(expanded)
    if exists {
        append(&lines, strings.clone("Status: ✓ Exists"))

        // Get directory info
        file_info, err := os.stat(expanded)
        if err == os.ERROR_NONE {
            // Size information
            if os.is_dir(expanded) {
                // Count entries in directory
                entries, _ := os.read_dir(expanded)
                append(&lines, fmt.aprintf("Type: Directory (%d entries)", len(entries)))
                delete(entries)
            }

            // Modification time
            mod_time := time.unix_to_time(file_info.modification_time)
            time_str := time.datetime_to_string(mod_time)
            append(&lines, strings.clone(""))
            append(&lines, strings.clone("Last modified: " + time_str))
        }

        // Description based on common paths
        append(&lines, strings.clone(""))
        if strings.contains(path, "/usr/local/bin") {
            append(&lines, strings.clone("User-installed binaries and scripts."))
            append(&lines, strings.clone("Common location for custom tools."))
        } else if strings.contains(path, "/.cargo/bin") {
            append(&lines, strings.clone("Rust toolchain binaries."))
            append(&lines, strings.clone("Installed via Cargo package manager."))
        } else if strings.contains(path, "/go/bin") {
            append(&lines, strings.clone("Go binaries compiled with 'go install'."))
        } else if strings.contains(path, "homebrew") {
            append(&lines, strings.clone("Homebrew package manager binaries."))
        }
    } else {
        append(&lines, strings.clone("Status: ✗ Does not exist"))
        append(&lines, strings.clone(""))
        append(&lines, strings.clone("This directory is in your PATH but"))
        append(&lines, strings.clone("doesn't exist on the filesystem."))
    }

    return lines[:]
}

// Generate preview lines for an alias
generate_alias_preview :: proc(alias_line: string) -> []string {
    lines := make([dynamic]string)

    // Parse alias (format: "alias_name='command'")
    parts := strings.split(alias_line, "=")
    if len(parts) < 2 {
        append(&lines, strings.clone("Invalid alias format"))
        return lines[:]
    }
    defer delete(parts)

    name := strings.trim_space(parts[0])
    command := strings.trim(parts[1], "'\"")

    // Header
    append(&lines, strings.clone("Preview: " + name))
    append(&lines, strings.repeat("─", 40))
    append(&lines, strings.clone(""))

    // Command breakdown
    append(&lines, strings.clone("Expands to:"))
    append(&lines, strings.clone("  " + command))
    append(&lines, strings.clone(""))

    // Parse command parts
    cmd_parts := strings.split(command, " ")
    defer delete(cmd_parts)

    if len(cmd_parts) > 0 {
        base_cmd := cmd_parts[0]
        append(&lines, strings.clone("Base command: " + base_cmd))

        if len(cmd_parts) > 1 {
            append(&lines, strings.clone("With arguments:"))
            for arg in cmd_parts[1:] {
                append(&lines, strings.clone("  • " + arg))
            }
        }
    }

    return lines[:]
}

// Generate preview lines for a constant
generate_constant_preview :: proc(constant_line: string) -> []string {
    lines := make([dynamic]string)

    // Parse constant (format: "export NAME=\"value\"")
    parts := strings.split(constant_line, "=")
    if len(parts) < 2 {
        append(&lines, strings.clone("Invalid constant format"))
        return lines[:]
    }
    defer delete(parts)

    name := strings.trim_space(strings.trim_prefix(parts[0], "export"))
    value := strings.trim(parts[1], "'\"")

    // Header
    append(&lines, strings.clone("Preview: " + name))
    append(&lines, strings.repeat("─", 40))
    append(&lines, strings.clone(""))

    // Value
    append(&lines, strings.clone("Current value:"))
    append(&lines, strings.clone("  " + value))
    append(&lines, strings.clone(""))

    // Type detection
    if strings.has_prefix(value, "/") {
        append(&lines, strings.clone("Type: Path"))
        if os.exists(value) {
            append(&lines, strings.clone("Status: ✓ Exists"))
        } else {
            append(&lines, strings.clone("Status: ✗ Not found"))
        }
    } else if len(value) > 20 {
        append(&lines, strings.clone("Type: String (possibly a token/key)"))
    } else {
        append(&lines, strings.clone("Type: String"))
    }

    return lines[:]
}

// Helper: expand environment variables in path
expand_path :: proc(path: string) -> string {
    result := strings.clone(path)

    home := os.get_env("HOME")
    defer delete(home)

    if strings.has_prefix(result, "$HOME") {
        new_result, _ := strings.replace(result, "$HOME", home)
        delete(result)
        result = new_result
    }

    return result
}
```

**Test:**
```bash
odin check src/tui/tui_preview.odin
```

#### Task 2.3: Migrate Main Menu to Panel System (1-2 hours)

**File:** `src/tui/tui_views.odin` or `src/tui/tui_main.odin` (MODIFY)

**After migration:**
```odin
render_main_menu :: proc(state: ^TUIState, screen: ^Screen) {
    // Create centered menu layout
    layout := create_menu_layout(screen.width, screen.height)
    defer layout_destroy(&layout)

    // Populate menu panel
    menu_items := []string{
        "📂 PATH Configuration",
        "📛 Aliases",
        "🔧 Constants",
        "🧩 Plugins",
        "💾 Backups",
        "⚙️  Settings",
        "❓ Help",
    }

    menu_panel := &layout.panels[1]  // Menu is second panel (after header)
    menu_panel.content = MenuContent{
        items = menu_items,
        selected_index = state.selected_index,
    }

    // Header panel
    header_panel := &layout.panels[0]
    header_panel.title = "🛠️  wayu - Shell Configuration Manager"

    // Footer panel
    footer_panel := &layout.panels[2]
    footer_panel.title = "↑/k: up  ↓/j: down  Enter: select  Esc/q: quit"

    // Render all panels
    for &panel in layout.panels {
        render_panel(screen, &panel)
    }
}
```

**Test:**
```bash
task build && ./bin/wayu --tui
# Verify centered menu renders correctly with panel system
```

#### Task 2.4: Migrate PATH View to Split Layout (2-3 hours)

**File:** `src/tui/tui_views.odin` (MODIFY)

**After migration:**
```odin
render_path_view :: proc(state: ^TUIState, screen: ^Screen) {
    // Check if data loaded
    if state.data_cache[.PATH_VIEW] == nil {
        render_text_colored(screen, 2, 1, "📂 PATH Configuration", TUI_PRIMARY, TUI_BG_HEADER)
        render_text_colored(screen, 2, 3, "Loading...", TUI_MUTED, "")
        state.needs_refresh = true
        return
    }

    items := cast(^[dynamic]string)state.data_cache[.PATH_VIEW]

    // Create split layout (30/70)
    layout := create_split_layout(screen.width, screen.height)
    defer layout_destroy(&layout)

    // Populate header panel
    header_panel := &layout.panels[0]
    header_panel.title = fmt.tprintf("📂 PATH Configuration - %d entries", len(items))

    // Populate list panel (left side)
    list_panel := &layout.panels[1]
    list_panel.content = ListContent{
        items = items[:],
        selected_index = state.selected_index,
        scroll_offset = state.scroll_offset,
        emoji_prefix = "",
    }
    list_panel.focused = true

    // Populate preview panel (right side)
    preview_panel := &layout.panels[2]
    preview_lines: []string
    if state.selected_index >= 0 && state.selected_index < len(items) {
        selected_path := items[state.selected_index]
        preview_lines = generate_path_preview(selected_path)
    } else {
        preview_lines = []string{"No selection"}
    }
    defer delete(preview_lines)

    preview_panel.content = PreviewContent{
        lines = preview_lines,
        scroll_offset = 0,
    }

    // Populate footer panel
    footer_panel := &layout.panels[3]
    footer_panel.title = "↑/k: up  ↓/j: down  d: delete  /: search  Esc: back"

    // Render all panels
    for &panel in layout.panels {
        render_panel(screen, &panel)
    }
}
```

**Test:**
```bash
task build && ./bin/wayu --tui
# Navigate to PATH view
# Verify: 30/70 split, list on left, preview on right
# Navigate through items, verify preview updates
```

#### Task 2.5: Migrate Remaining List Views (3-4 hours)

Migrate:
- `render_alias_view()` - Use split layout + `generate_alias_preview()`
- `render_constants_view()` - Use split layout + `generate_constant_preview()`
- `render_backups_view()` - Use split layout + backup file preview

**Pattern:**
1. Create split layout
2. Populate list panel with items from data cache
3. Generate preview for selected item
4. Render all panels

**Test each view:**
```bash
task build && ./bin/wayu --tui
# Navigate through all views
# Verify split layout works in each view
# Verify preview content is relevant
```

#### Task 2.6: Testing & Refinement (1-2 hours)

**Manual testing:**
```bash
# Test panel resizing
wayu --tui  # Start with default terminal size
# Resize terminal while TUI is running
# Verify panels adjust correctly (existing resize handling)

# Test scrolling in preview panels
# Navigate to item with long preview
# Verify preview scrolls if content exceeds panel height

# Test in different terminal sizes
# 80x24 (minimum)
# 120x40 (typical)
# 200x60 (large)
```

**Unit tests:**
Create `tests/unit/test_tui_panel.odin`:
```odin
package test

import "core:testing"
import tui "../src/tui"

@(test)
test_create_split_layout :: proc(t: ^testing.T) {
    layout := tui.create_split_layout(80, 24)
    defer tui.layout_destroy(&layout)

    // Should have 4 panels: header, list, preview, footer
    testing.expect(t, len(layout.panels) == 4)

    // Verify panel positions
    header := layout.panels[0]
    testing.expect(t, header.type == .HEADER)
    testing.expect(t, header.y == 0)

    list := layout.panels[1]
    testing.expect(t, list.type == .LIST)
    testing.expect(t, list.x == 0)

    preview := layout.panels[2]
    testing.expect(t, preview.type == .PREVIEW)
    testing.expect(t, preview.x > list.width)  // To the right of list

    footer := layout.panels[3]
    testing.expect(t, footer.type == .FOOTER)
    testing.expect(t, footer.y == layout.screen_height - 2)
}

@(test)
test_create_menu_layout :: proc(t: ^testing.T) {
    layout := tui.create_menu_layout(80, 24)
    defer tui.layout_destroy(&layout)

    // Should have 3 panels: header, menu, footer
    testing.expect(t, len(layout.panels) == 3)

    menu := layout.panels[1]
    testing.expect(t, menu.type == .MENU)
    // Menu should be centered
    testing.expect(t, menu.x > 0)
    testing.expect(t, menu.x + menu.width < 80)
}
```

Run tests:
```bash
task test
```

#### Phase 2 Deliverables

✅ **New file:** `src/tui/tui_panel.odin` (panel system)
✅ **New file:** `src/tui/tui_preview.odin` (preview generators)
✅ **Modified file:** `src/tui/tui_views.odin` (migrated to panels)
✅ **New tests:** `tests/unit/test_tui_panel.odin`
✅ **Documentation:** Update CLAUDE.md with panel architecture

#### Phase 2 Success Criteria

- [ ] Split layout (30/70) renders correctly
- [ ] List panel shows items on left
- [ ] Preview panel shows details on right
- [ ] Preview updates when selection changes
- [ ] All list views migrated (PATH, Alias, Constants, Backups)
- [ ] Panels resize correctly with terminal
- [ ] All unit tests passing
- [ ] No performance regression

**Result:** Single-panel TUI → Multi-panel TUI with preview (100% feature complete!)

---

### Phase 3: Polish & Advanced Features

**Duration:** 3-5 hours
**Goal:** Search overlay, enhanced indicators, performance optimization
**Complexity:** Low-Medium - Nice-to-have features

#### Task 3.1: Implement Search Overlay (1-2 hours)

**File:** `src/tui/tui_views.odin` (MODIFY)

**Add search state to TUIState:**
```odin
// src/tui/tui_state.odin (MODIFY)
TUIState :: struct {
    // ... existing fields ...

    // Search state
    search_active: bool,
    search_query: string,
    search_results: [dynamic]int,  // Indices of matching items
}
```

**Add search overlay rendering:**
```odin
// In each list view (e.g., render_path_view)
if state.search_active {
    // Draw search overlay at top of list panel
    search_panel_y := list_panel.y + 1
    render_box_colored(screen, list_panel.x + 2, search_panel_y,
        list_panel.width - 4, 3, TUI_BORDER_FOCUSED)

    search_prompt := fmt.tprintf("Search: %s_", state.search_query)
    render_text_colored(screen, list_panel.x + 4, search_panel_y + 1,
        search_prompt, TUI_PRIMARY, "")
}
```

**Add search input handling:**
```odin
// src/tui/tui_events.odin (MODIFY)
handle_key_event :: proc(state: ^TUIState, key: Key) {
    if state.search_active {
        switch key {
        case .CHAR:
            // Append character to search query
            append(&state.search_query, key.char)
            filter_search_results(state)
        case .BACKSPACE:
            // Remove last character
            if len(state.search_query) > 0 {
                pop(&state.search_query)
                filter_search_results(state)
            }
        case .ENTER, .ESC:
            // Exit search mode
            state.search_active = false
        }
        return
    }

    // Normal key handling
    switch key {
    case .SLASH:
        // Enter search mode
        state.search_active = true
        clear(&state.search_query)
    // ... existing key handlers ...
    }
}
```

**Test:**
```bash
task build && ./bin/wayu --tui
# Navigate to PATH view
# Press "/" to activate search
# Type "local" and verify filtering
# Press Esc to exit search
```

#### Task 3.2: Enhanced Scroll Indicators (30 min)

**File:** `src/tui/tui_panel.odin` (MODIFY)

**Add scroll indicators to list panels:**
```odin
render_list_content :: proc(screen: ^Screen, panel: ^Panel) {
    content := panel.content.(ListContent)

    visible_height := panel.height - 2
    start_idx := content.scroll_offset
    end_idx := min(start_idx + visible_height, len(content.items))

    // ... render items ...

    // Add scroll indicators on right edge
    if start_idx > 0 {
        // More content above
        indicator_y := panel.y + 1
        render_text_colored(screen, panel.x + panel.width - 2, indicator_y,
            "▲", TUI_PRIMARY, "")
    }

    if end_idx < len(content.items) {
        // More content below
        indicator_y := panel.y + panel.height - 2
        render_text_colored(screen, panel.x + panel.width - 2, indicator_y,
            "▼", TUI_PRIMARY, "")
    }

    // Percentage indicator
    if len(content.items) > visible_height {
        percent := (content.selected_index * 100) / len(content.items)
        indicator := fmt.tprintf("%d%%", percent)
        indicator_y := panel.y + panel.height / 2
        render_text_colored(screen, panel.x + panel.width - 5, indicator_y,
            indicator, TUI_DIM, "")
    }
}
```

**Test:**
```bash
task build && ./bin/wayu --tui
# Navigate to view with many items
# Verify ▲ shows when scrolled down
# Verify ▼ shows when scrolled up
# Verify percentage indicator
```

#### Task 3.3: Status Messages (30 min)

**File:** `src/tui/tui_state.odin` (MODIFY)

**Add status message to state:**
```odin
TUIState :: struct {
    // ... existing fields ...

    // Status message
    status_message: string,
    status_timeout: f64,  // Timestamp when message expires
}
```

**Render status message:**
```odin
// In tui_render (after rendering view)
if state.status_message != "" && time.now() < state.status_timeout {
    // Show status message at bottom
    status_y := screen.height - 1
    render_text_colored(screen, 2, status_y, state.status_message,
        TUI_SUCCESS, TUI_BG_HEADER)
}
```

**Set status messages on actions:**
```odin
// After delete operation
state.status_message = "✓ Item deleted successfully"
state.status_timeout = time.now() + 3.0  // 3 seconds
```

#### Task 3.4: Performance Testing & Optimization (1-2 hours)

**Benchmark rendering:**
Create `tests/performance/bench_tui_render.odin`:
```odin
package bench

import "core:fmt"
import "core:time"
import tui "../src/tui"

bench_render_large_list :: proc() {
    screen := tui.screen_create(80, 24)
    defer tui.screen_destroy(&screen)

    // Create large item list (1000 items)
    items := make([dynamic]string, 1000)
    defer delete(items)
    for i in 0..<1000 {
        items[i] = fmt.aprintf("Item %d", i)
    }

    state := tui.TUIState{
        current_view = .PATH_VIEW,
        selected_index = 0,
        scroll_offset = 0,
        terminal_width = 80,
        terminal_height = 24,
    }
    state.data_cache[.PATH_VIEW] = &items

    // Benchmark 100 renders
    iterations := 100
    start := time.now()

    for i in 0..<iterations {
        tui.screen_clear(&screen)
        tui.render_path_view(&state, &screen)
        tui.screen_flush(&screen)
    }

    elapsed := time.diff(start, time.now())
    avg_ms := time.duration_milliseconds(elapsed) / f64(iterations)

    fmt.printf("Average render time: %.2f ms\n", avg_ms)

    if avg_ms > 50.0 {
        fmt.println("⚠️  WARNING: Render time exceeds 50ms target!")
    } else {
        fmt.println("✓ Render performance acceptable")
    }
}
```

Run benchmark:
```bash
odin run tests/performance/bench_tui_render.odin
```

**Optimize if needed:**
1. Cache preview content (don't regenerate every frame)
2. Limit preview line count
3. Use string builders more efficiently

#### Phase 3 Deliverables

✅ **Modified files:** `tui_state.odin`, `tui_views.odin`, `tui_events.odin`, `tui_panel.odin`
✅ **New tests:** `bench_tui_render.odin`
✅ **Features:** Search overlay, scroll indicators, status messages
✅ **Verified:** Performance < 50ms per frame

#### Phase 3 Success Criteria

- [ ] Search overlay appears on "/" key
- [ ] Search filters items in real-time
- [ ] Scroll indicators (▲ ▼ %) visible when needed
- [ ] Status messages show after actions
- [ ] Performance benchmark < 50ms average
- [ ] All features work together without conflicts

**Result:** Feature-complete modern TUI with all polish!

---

## Technical Specifications

### API Reference

#### Color Constants (tui_colors.odin)

```odin
// Primary colors
TUI_PRIMARY: string   // Hot pink #E40050 - Main accent, highlights
TUI_SECONDARY: string // Teal-cyan #0E7490 - Secondary elements

// Semantic colors
TUI_SUCCESS: string   // Teal - Success indicators
TUI_ERROR: string     // Dark red #991B1B - Error messages
TUI_WARNING: string   // Orange #D97706 - Warnings

// UI colors
TUI_HIGHLIGHT: string // Hot pink - Important items
TUI_MUTED: string     // Light gray - Secondary text
TUI_DIM: string       // Dimmer gray - Disabled/subtle text

// Backgrounds
TUI_BG_NORMAL: string   // Dark purple-blue - Default background
TUI_BG_SELECTED: string // Almost black - Selection background
TUI_BG_HEADER: string   // Slightly lighter - Header/footer background

// Borders
TUI_BORDER_NORMAL: string  // Gray - Inactive panel border
TUI_BORDER_FOCUSED: string // Hot pink - Active panel border

// Control codes
TUI_RESET: string // "\x1b[0m" - Reset all attributes
TUI_BOLD: string  // "\x1b[1m" - Bold text
TUI_DIM: string   // "\x1b[2m" - Dimmed text
```

#### Rendering Functions (tui_render.odin)

```odin
// Render text with colors at position
render_text_colored :: proc(
    screen: ^Screen,
    x, y: int,
    text: string,
    fg: string = "",  // Foreground color (ANSI code or empty)
    bg: string = "",  // Background color (ANSI code or empty)
)

// Render box with colored borders
render_box_colored :: proc(
    screen: ^Screen,
    x, y: int,        // Top-left position
    width: int,       // Box width
    height: int,      // Box height
    border_fg: string, // Border color (ANSI code)
)
```

**Usage Example:**
```odin
// Render colored text
render_text_colored(screen, 10, 5, "Hello World", TUI_PRIMARY, TUI_BG_SELECTED)

// Render colored box
render_box_colored(screen, 0, 0, 80, 24, TUI_BORDER_FOCUSED)
```

#### Panel System (tui_panel.odin)

```odin
// Panel types
PanelType :: enum {
    HEADER,   // Full-width top panel
    FOOTER,   // Full-width bottom panel
    LIST,     // Scrollable list
    PREVIEW,  // Detail view
    MENU,     // Centered menu
}

// Panel structure
Panel :: struct {
    type: PanelType,
    x, y, width, height: int,
    title: string,
    focused: bool,
    border_fg: string,
    bg: string,
    content: union {ListContent, PreviewContent, MenuContent},
}

// Layout structure
Layout :: struct {
    screen_width, screen_height: int,
    panels: [dynamic]Panel,
}

// Create layouts
create_split_layout :: proc(screen_width, screen_height: int) -> Layout
create_menu_layout :: proc(screen_width, screen_height: int) -> Layout

// Manage layouts
layout_destroy :: proc(layout: ^Layout)

// Render panels
render_panel :: proc(screen: ^Screen, panel: ^Panel)
```

**Usage Example:**
```odin
// Create split layout
layout := create_split_layout(80, 24)
defer layout_destroy(&layout)

// Populate list panel
list_panel := &layout.panels[1]
list_panel.content = ListContent{
    items = []string{"Item 1", "Item 2", "Item 3"},
    selected_index = 0,
    scroll_offset = 0,
}

// Render all panels
for &panel in layout.panels {
    render_panel(screen, &panel)
}
```

### Color Palette Justification

**Theme:** Zellij "dvrd" inspired palette

**Primary Color: Hot Pink (#E40050)**
- **Rationale:** High contrast, stands out on both light/dark backgrounds
- **Usage:** Selected items, borders of focused panels, headers
- **Accessibility:** Excellent visibility, works for most color blindness types

**Secondary Color: Teal-Cyan (#0E7490)**
- **Rationale:** Complements hot pink, professional appearance
- **Usage:** Success messages, informational elements
- **Accessibility:** Good contrast, distinguishable from primary

**Muted Gray (#D0D0D0)**
- **Rationale:** Reduces visual noise for non-critical text
- **Usage:** Normal list items, helper text
- **Accessibility:** Sufficient contrast on dark backgrounds

**Background Colors:**
- Dark purple-blue (#181825): Subtle, easy on eyes for extended use
- Almost black (#090909): Maximum contrast for selections

**Border Colors:**
- Gray (#646464): Subtle, doesn't distract
- Hot pink (#E40050): Draws attention to active panel

### Terminal Compatibility Matrix

| Terminal | TrueColor | 256-Color | Box-Drawing | Notes |
|----------|-----------|-----------|-------------|-------|
| iTerm2 (macOS) | ✅ Yes | ✅ Yes | ✅ Yes | Full support |
| Terminal.app (macOS) | ✅ Yes | ✅ Yes | ✅ Yes | macOS 10.14+ |
| Alacritty | ✅ Yes | ✅ Yes | ✅ Yes | Excellent support |
| Kitty | ✅ Yes | ✅ Yes | ✅ Yes | Best-in-class |
| WezTerm | ✅ Yes | ✅ Yes | ✅ Yes | Full support |
| VS Code Terminal | ✅ Yes | ✅ Yes | ✅ Yes | Integrated terminal |
| GNOME Terminal | ✅ Yes | ✅ Yes | ✅ Yes | Linux standard |
| Konsole (KDE) | ✅ Yes | ✅ Yes | ✅ Yes | KDE standard |
| Windows Terminal | ✅ Yes | ✅ Yes | ✅ Yes | Windows 10/11 |
| xterm | ⚠️ Limited | ✅ Yes | ✅ Yes | Fallback to 256 |

**Recommendation:** Target TrueColor (24-bit RGB) as primary, with automatic fallback to 256-color if COLORTERM not set.

### Performance Benchmarks

**Target:** < 50ms per frame (user perception threshold)

**Expected performance:**
- Small lists (< 50 items): ~5-10ms
- Medium lists (50-500 items): ~10-25ms
- Large lists (500-1000 items): ~25-40ms
- Very large lists (1000+ items): ~40-50ms

**Optimizations already in place:**
1. Differential rendering (screen_flush only sends changed cells)
2. Viewport culling (only render visible items)
3. Efficient string handling (tprintf temp buffer)

**If performance issues:**
1. Cache preview content (regenerate only on selection change)
2. Limit preview line count to visible height
3. Profile with Odin's built-in profiler

---

## Testing Strategy

### Unit Tests

#### Color System Tests

**File:** `tests/unit/test_tui_colors.odin`

```odin
@(test)
test_color_constants_not_empty :: proc(t: ^testing.T) {
    testing.expect(t, len(TUI_PRIMARY) > 0)
    testing.expect(t, len(TUI_SECONDARY) > 0)
    testing.expect(t, len(TUI_RESET) > 0)
}

@(test)
test_render_text_colored :: proc(t: ^testing.T) {
    screen := screen_create(20, 5)
    defer screen_destroy(&screen)

    render_text_colored(&screen, 0, 0, "Test", TUI_PRIMARY, TUI_BG_NORMAL)

    testing.expect(t, screen.buffer[0][0].fg == TUI_PRIMARY)
    testing.expect(t, screen.buffer[0][0].bg == TUI_BG_NORMAL)
    testing.expect(t, screen.buffer[0][0].char == 'T')
}

@(test)
test_render_box_colored_corners :: proc(t: ^testing.T) {
    screen := screen_create(10, 5)
    defer screen_destroy(&screen)

    render_box_colored(&screen, 0, 0, 10, 5, TUI_BORDER_NORMAL)

    testing.expect(t, screen.buffer[0][0].char == '┌')
    testing.expect(t, screen.buffer[0][9].char == '┐')
    testing.expect(t, screen.buffer[4][0].char == '└')
    testing.expect(t, screen.buffer[4][9].char == '┘')

    for cell in [4]Cell{screen.buffer[0][0], screen.buffer[0][9],
                         screen.buffer[4][0], screen.buffer[4][9]} {
        testing.expect(t, cell.fg == TUI_BORDER_NORMAL)
    }
}
```

#### Panel System Tests

**File:** `tests/unit/test_tui_panel.odin`

```odin
@(test)
test_create_split_layout_panel_count :: proc(t: ^testing.T) {
    layout := create_split_layout(80, 24)
    defer layout_destroy(&layout)

    testing.expect(t, len(layout.panels) == 4)
}

@(test)
test_create_split_layout_positions :: proc(t: ^testing.T) {
    layout := create_split_layout(80, 24)
    defer layout_destroy(&layout)

    header := layout.panels[0]
    testing.expect(t, header.type == .HEADER)
    testing.expect(t, header.y == 0)
    testing.expect(t, header.width == 80)

    list := layout.panels[1]
    testing.expect(t, list.type == .LIST)
    testing.expect(t, list.x == 0)
    testing.expect(t, list.width == 24)  // 30% of 80

    preview := layout.panels[2]
    testing.expect(t, preview.type == .PREVIEW)
    testing.expect(t, preview.x == 25)  // After list + border
    testing.expect(t, preview.width == 55)  // Remaining space

    footer := layout.panels[3]
    testing.expect(t, footer.type == .FOOTER)
    testing.expect(t, footer.y == 22)  // Height - 2
}

@(test)
test_create_menu_layout_centered :: proc(t: ^testing.T) {
    layout := create_menu_layout(80, 24)
    defer layout_destroy(&layout)

    menu := layout.panels[1]
    testing.expect(t, menu.type == .MENU)

    // Menu should be centered
    center_x := 80 / 2
    menu_center := menu.x + menu.width / 2
    testing.expect(t, abs(menu_center - center_x) < 2)  // Within 2 chars
}
```

### Component Tests (Using PRP-13 CLI)

**Generate golden files for new components:**

```bash
# Panel layouts
wayu -c=panel-layout type=split width=80 height=24 --snapshot
wayu -c=panel-layout type=menu width=80 height=24 --snapshot

# Colored elements
wayu -c=colored-text width=40 height=1 text="Colored Text" fg=primary bg=selected --snapshot
wayu -c=colored-box width=20 height=5 border=focused --snapshot
```

**Verify against golden files:**

```bash
wayu -c=panel-layout type=split width=80 height=24 --test
wayu -c=panel-layout type=menu width=80 height=24 --test
```

**Create component test file:**

`tests/unit/test_tui_components.odin` (EXTEND from PRP-13)

```odin
@(test)
test_colored_box_rendering :: proc(t: ^testing.T) {
    args := ComponentArgs{
        width = 10,
        height = 5,
    }

    output := render_component(.BOX, args)
    defer delete(output)

    // Verify box contains ANSI color codes
    testing.expect(t, strings.contains(output, "\x1b["))

    // Verify box structure
    lines := strings.split(output, "\n")
    defer delete(lines)

    testing.expect(t, len(lines) == 5)
    testing.expect(t, strings.contains(lines[0], "┌"))
    testing.expect(t, strings.contains(lines[4], "└"))
}
```

### Visual Regression Tests

**Manual visual inspection:**

Create test script `tests/visual/test_visual_regression.sh`:

```bash
#!/bin/bash

# Visual regression test script
echo "=== Visual Regression Test ==="
echo ""
echo "This test requires manual verification."
echo "Compare screenshots with baseline images in tests/visual/baselines/"
echo ""

# Function to capture screenshot
capture_screen() {
    view=$1
    echo "Capturing $view..."
    # Use terminal screenshot tool or manual capture
    # For macOS: screencapture -w "tests/visual/current/$view.png"
}

# Build TUI
echo "Building TUI..."
task build

# Capture main menu
echo ""
echo "1. Launch TUI and verify Main Menu"
echo "   - Press Enter to continue"
read

# Capture PATH view
echo ""
echo "2. Navigate to PATH view"
echo "   - Verify split layout (30/70)"
echo "   - Verify colors (hot pink primary, teal secondary)"
echo "   - Verify borders (gray inactive, hot pink active)"
echo "   - Press Enter to continue"
read

# Capture Alias view
echo ""
echo "3. Navigate to Alias view"
echo "   - Verify preview panel updates"
echo "   - Verify selected item highlight"
echo "   - Press Enter to continue"
read

echo ""
echo "Visual regression test complete!"
echo "If any issues found, document in test_visual_regression.log"
```

Run visual tests:
```bash
chmod +x tests/visual/test_visual_regression.sh
./tests/visual/test_visual_regression.sh
```

### Integration Tests

**Test full workflows:**

Create `tests/integration/test_tui_workflows.rb`:

```ruby
#!/usr/bin/env ruby

require 'pty'
require 'timeout'

def test_tui_launch_and_navigate
  puts "Test: Launch TUI and navigate to PATH view"

  PTY.spawn("./bin/wayu --tui") do |stdout, stdin, pid|
    # Wait for TUI to load
    sleep 0.5

    # Navigate down to PATH (item 1)
    stdin.puts "\e[B"  # Down arrow
    sleep 0.2

    # Select PATH view
    stdin.puts "\r"  # Enter
    sleep 0.5

    # Read output
    output = stdout.read_nonblock(10000) rescue ""

    # Verify PATH view rendered
    unless output.include?("PATH Configuration")
      puts "❌ FAIL: PATH view not found"
      exit 1
    end

    # Verify ANSI colors present
    unless output.include?("\e[38;2;")
      puts "❌ FAIL: No ANSI colors found"
      exit 1
    end

    # Exit TUI
    stdin.puts "\x1b"  # Esc
    sleep 0.2
    stdin.puts "\x1b"  # Esc again to main menu
    sleep 0.2
    stdin.puts "q"     # Quit

    puts "✅ PASS: TUI launch and navigation"
  end
end

def test_tui_selection_colors
  puts "Test: Selection highlight colors"

  PTY.spawn("./bin/wayu --tui") do |stdout, stdin, pid|
    sleep 0.5

    # Navigate to PATH view
    stdin.puts "\r"
    sleep 0.5

    # Move selection down
    stdin.puts "\e[B"
    sleep 0.2

    output = stdout.read_nonblock(10000) rescue ""

    # Verify selection color (hot pink)
    unless output.include?("\e[38;2;228;0;80m")
      puts "❌ FAIL: Selection color not found"
      exit 1
    end

    # Exit
    stdin.puts "\x1b\x1b"
    stdin.puts "q"

    puts "✅ PASS: Selection colors"
  end
end

# Run tests
test_tui_launch_and_navigate
test_tui_selection_colors

puts ""
puts "All integration tests passed! ✅"
```

Run integration tests:
```bash
ruby tests/integration/test_tui_workflows.rb
```

### Performance Tests

**Benchmark rendering performance:**

Create `tests/performance/bench_tui_render.odin`:

```odin
package bench

import "core:fmt"
import "core:time"
import tui "../src/tui"

main :: proc() {
    fmt.println("=== TUI Rendering Performance Benchmark ===")
    fmt.println()

    bench_render_small_list()
    bench_render_medium_list()
    bench_render_large_list()
    bench_render_split_layout()

    fmt.println()
    fmt.println("Benchmark complete!")
}

bench_render_small_list :: proc() {
    fmt.println("1. Small list (50 items)...")

    screen := tui.screen_create(80, 24)
    defer tui.screen_destroy(&screen)

    items := make([dynamic]string, 50)
    defer delete(items)
    for i in 0..<50 {
        items[i] = fmt.aprintf("Item %d", i)
    }
    defer for item in items do delete(item)

    iterations := 100
    start := time.now()

    for i in 0..<iterations {
        tui.screen_clear(&screen)
        // Render list
        for item, idx in items[:10] {  // Only visible items
            tui.render_text_colored(&screen, 2, 4 + idx, item, tui.TUI_MUTED, "")
        }
        tui.screen_flush(&screen, force_full_render = true)
    }

    elapsed := time.diff(start, time.now())
    avg_ms := time.duration_milliseconds(elapsed) / f64(iterations)

    fmt.printf("   Average: %.2f ms ", avg_ms)
    if avg_ms < 10.0 {
        fmt.println("✅")
    } else if avg_ms < 50.0 {
        fmt.println("⚠️")
    } else {
        fmt.println("❌")
    }
}

bench_render_medium_list :: proc() {
    fmt.println("2. Medium list (500 items)...")

    screen := tui.screen_create(80, 24)
    defer tui.screen_destroy(&screen)

    items := make([dynamic]string, 500)
    defer delete(items)
    for i in 0..<500 {
        items[i] = fmt.aprintf("Item %d", i)
    }
    defer for item in items do delete(item)

    iterations := 100
    start := time.now()

    for i in 0..<iterations {
        tui.screen_clear(&screen)
        for item, idx in items[:10] {
            tui.render_text_colored(&screen, 2, 4 + idx, item, tui.TUI_MUTED, "")
        }
        tui.screen_flush(&screen, force_full_render = true)
    }

    elapsed := time.diff(start, time.now())
    avg_ms := time.duration_milliseconds(elapsed) / f64(iterations)

    fmt.printf("   Average: %.2f ms ", avg_ms)
    if avg_ms < 25.0 {
        fmt.println("✅")
    } else if avg_ms < 50.0 {
        fmt.println("⚠️")
    } else {
        fmt.println("❌")
    }
}

bench_render_large_list :: proc() {
    fmt.println("3. Large list (1000 items)...")

    screen := tui.screen_create(80, 24)
    defer tui.screen_destroy(&screen)

    items := make([dynamic]string, 1000)
    defer delete(items)
    for i in 0..<1000 {
        items[i] = fmt.aprintf("Item %d", i)
    }
    defer for item in items do delete(item)

    iterations := 100
    start := time.now()

    for i in 0..<iterations {
        tui.screen_clear(&screen)
        for item, idx in items[:10] {
            tui.render_text_colored(&screen, 2, 4 + idx, item, tui.TUI_MUTED, "")
        }
        tui.screen_flush(&screen, force_full_render = true)
    }

    elapsed := time.diff(start, time.now())
    avg_ms := time.duration_milliseconds(elapsed) / f64(iterations)

    fmt.printf("   Average: %.2f ms ", avg_ms)
    if avg_ms < 40.0 {
        fmt.println("✅")
    } else if avg_ms < 50.0 {
        fmt.println("⚠️")
    } else {
        fmt.println("❌")
    }
}

bench_render_split_layout :: proc() {
    fmt.println("4. Split layout with preview...")

    screen := tui.screen_create(80, 24)
    defer tui.screen_destroy(&screen)

    iterations := 100
    start := time.now()

    for i in 0..<iterations {
        tui.screen_clear(&screen)

        // Render split layout
        tui.render_box_colored(&screen, 0, 0, 24, 24, tui.TUI_BORDER_FOCUSED)
        tui.render_box_colored(&screen, 25, 0, 55, 24, tui.TUI_BORDER_NORMAL)

        // Render some content
        for j in 0..<10 {
            tui.render_text_colored(&screen, 2, 2 + j, "List item", tui.TUI_MUTED, "")
            tui.render_text_colored(&screen, 27, 2 + j, "Preview line", tui.TUI_MUTED, "")
        }

        tui.screen_flush(&screen, force_full_render = true)
    }

    elapsed := time.diff(start, time.now())
    avg_ms := time.duration_milliseconds(elapsed) / f64(iterations)

    fmt.printf("   Average: %.2f ms ", avg_ms)
    if avg_ms < 30.0 {
        fmt.println("✅")
    } else if avg_ms < 50.0 {
        fmt.println("⚠️")
    } else {
        fmt.println("❌")
    }
}
```

Run performance tests:
```bash
odin run tests/performance/bench_tui_render.odin
```

**Expected output:**
```
=== TUI Rendering Performance Benchmark ===

1. Small list (50 items)...
   Average: 8.32 ms ✅
2. Medium list (500 items)...
   Average: 18.45 ms ✅
3. Large list (1000 items)...
   Average: 35.67 ms ✅
4. Split layout with preview...
   Average: 22.14 ms ✅

Benchmark complete!
```

### Manual Testing Checklist

**Phase 1 (Colors + Borders):**
- [ ] Launch `wayu --tui`
- [ ] Main menu has colored title (hot pink)
- [ ] Main menu has centered panel with border
- [ ] Selected menu item has background highlight
- [ ] Navigate to PATH view
- [ ] PATH view has outer border
- [ ] PATH view header is colored (hot pink)
- [ ] Selected PATH item has background highlight
- [ ] Footer has dimmed color
- [ ] Test in iTerm2, Terminal.app, Alacritty
- [ ] Resize terminal, verify colors still work

**Phase 2 (Multi-Panel Layout):**
- [ ] Navigate to PATH view
- [ ] List panel on left (30% width)
- [ ] Preview panel on right (70% width)
- [ ] Border between panels
- [ ] Select different items, preview updates
- [ ] Preview shows path details (exists, size, etc.)
- [ ] Navigate to Alias view
- [ ] Preview shows alias expansion
- [ ] Navigate to Constants view
- [ ] Preview shows constant value and type
- [ ] Scroll in list, verify preview stays synced
- [ ] Resize terminal, panels adjust correctly

**Phase 3 (Polish):**
- [ ] Press "/" in PATH view
- [ ] Search overlay appears
- [ ] Type "local", items filter
- [ ] Press Esc, search closes
- [ ] Scroll in long list
- [ ] ▲ indicator appears when scrolled down
- [ ] ▼ indicator appears when scrolled up
- [ ] Percentage indicator shows position
- [ ] Delete an item
- [ ] Status message appears at bottom
- [ ] Status message disappears after 3 seconds

---

## Risk Assessment

### Low Risk Items

✅ **Color system implementation**
- **Why:** Simple string constants, no complex logic
- **Evidence:** Main package already has comprehensive color system
- **Mitigation:** None needed

✅ **Existing infrastructure reuse**
- **Why:** Cell.fg/bg already supported, screen_flush() handles colors
- **Evidence:** Research shows 90% of infrastructure ready
- **Mitigation:** None needed

✅ **Backwards compatibility**
- **Why:** Additive changes only, no breaking API changes
- **Evidence:** No modifications to TUIState or public interfaces
- **Mitigation:** None needed

### Medium Risk Items

⚠️ **Terminal compatibility**
- **Risk:** Colors or box-drawing may not work in some terminals
- **Likelihood:** Low (modern terminals have good support)
- **Impact:** Medium (fallback to plain text possible)
- **Mitigation:**
  1. Test across 5+ terminals (iTerm, Terminal.app, Alacritty, etc.)
  2. Detect NO_COLOR environment variable
  3. Provide plain-text fallback mode if needed
  4. Document supported terminals in README

⚠️ **Performance with colors**
- **Risk:** Adding colors increases bytes sent to terminal
- **Likelihood:** Low (differential rendering mitigates this)
- **Impact:** Low (max 10-20% increase in render time)
- **Mitigation:**
  1. Benchmark before and after (target < 50ms)
  2. Profile if performance degrades
  3. Optimize string building if needed
  4. Consider caching preview content

⚠️ **Preview content generation**
- **Risk:** Generating preview for every selection change may be slow
- **Likelihood:** Medium (depends on preview complexity)
- **Impact:** Low (only affects preview panel)
- **Mitigation:**
  1. Cache preview content until selection changes
  2. Limit preview line count to visible height
  3. Use lazy evaluation for expensive operations (file stats)
  4. Benchmark preview generation separately

### High Risk Items

**None identified.** This is primarily a visual enhancement using existing infrastructure.

### Risk Summary Table

| Risk | Likelihood | Impact | Severity | Mitigation Status |
|------|-----------|--------|----------|-------------------|
| Terminal compatibility | Low | Medium | **Low** | ✅ Planned |
| Performance degradation | Low | Low | **Low** | ✅ Planned |
| Preview generation slow | Medium | Low | **Low** | ✅ Planned |

**Overall Risk Level: LOW**

---

## Timeline & Milestones

### Week 1: Foundation (Phase 1)

**Days 1-2: Color System** (6-8 hours)
- Monday AM: Create tui_colors.odin, add color constants
- Monday PM: Add render_text_colored(), render_box_colored()
- Tuesday AM: Update Main Menu view with colors
- Tuesday PM: Update PATH view with colors

**Day 3: View Migration** (2-3 hours)
- Wednesday AM: Update remaining 6 views with colors
- Wednesday PM: Testing and refinement

**Milestone 1 Deliverable:** ✅ Colorful TUI with borders (80% visual improvement)

**Review Point:** Demo to stakeholders, get feedback before Phase 2

---

### Week 2: Multi-Panel Layout (Phase 2)

**Days 4-5: Panel System Core** (6-8 hours)
- Thursday AM: Create tui_panel.odin, Panel/Layout structs
- Thursday PM: Implement create_split_layout(), create_menu_layout()
- Friday AM: Implement render_panel() and content renderers
- Friday PM: Create tui_preview.odin with preview generators

**Days 6-7: View Migration** (4-6 hours)
- Monday AM: Migrate Main Menu to panel system
- Monday PM: Migrate PATH view to split layout
- Tuesday AM: Migrate Alias and Constants views
- Tuesday PM: Migrate Backups view

**Milestone 2 Deliverable:** ✅ Multi-panel TUI with preview (100% feature complete)

**Review Point:** Full testing, performance benchmarks

---

### Week 3: Polish (Phase 3)

**Day 8: Advanced Features** (2-3 hours)
- Wednesday AM: Implement search overlay
- Wednesday PM: Add enhanced scroll indicators

**Day 9: Testing & Documentation** (1-2 hours)
- Thursday AM: Run all tests, fix bugs
- Thursday PM: Update documentation (CLAUDE.md, README.md)

**Milestone 3 Deliverable:** ✅ Production-ready modern TUI

**Final Review:** Code review, merge to main, release v2.2.0

---

### Timeline Summary

| Week | Phase | Hours | Milestone |
|------|-------|-------|-----------|
| 1 | Phase 1: Colors + Borders | 6-8 | MVP |
| 2 | Phase 2: Multi-Panel Layout | 10-14 | Full Feature |
| 3 | Phase 3: Polish | 3-5 | Production |
| **Total** | **All Phases** | **19-27** | **v2.2.0 Release** |

**Flexibility:** Each phase is independently valuable. Can pause after Phase 1 or 2 if needed.

---

## Success Criteria

### Visual Quality Metrics

1. ✅ **Bordered Panels** - All views use bordered panels with box-drawing characters
2. ✅ **Color Scheme Applied** - Every view uses defined color palette consistently
3. ✅ **Multi-Panel Layouts** - List views have separate list and preview panels (Phase 2)
4. ✅ **Selection Highlighting** - Selected items have colored background, not just prefix
5. ✅ **Focused Panel Indication** - Active panel has distinct border color
6. ✅ **Search Overlay** - "/" key shows search input panel (Phase 3)
7. ✅ **Visual Hierarchy** - Headers, content, and footers clearly distinguished

### Functional Requirements

1. ✅ **No Regressions** - All existing functionality still works
   - Navigation (↑/↓, j/k, Enter, Esc)
   - Selection and deletion
   - View switching
   - Data loading

2. ✅ **Performance** - No noticeable lag with 1000+ items
   - < 50ms average frame time
   - Differential rendering working
   - No frame drops during scrolling

3. ✅ **Compatibility** - Works in common terminals
   - iTerm2 (macOS)
   - Terminal.app (macOS)
   - Alacritty
   - Kitty
   - GNOME Terminal (Linux)
   - Windows Terminal

4. ✅ **Responsive** - Adapts to terminal resize events
   - Panels recalculate positions
   - Content re-flows
   - No artifacts or glitches

5. ✅ **Accessibility** - Color scheme works on both light and dark backgrounds
   - High contrast
   - Color-blind friendly
   - Respects NO_COLOR environment variable

### User Experience Goals

1. ✅ **Intuitive Navigation** - Panel focus and content clear at a glance
   - Hot pink border indicates active panel
   - Selected items have clear visual distinction
   - Shortcuts visible in footer

2. ✅ **Context Awareness** - Preview panel shows what will happen before action
   - PATH: Directory details, existence status
   - Alias: Command expansion breakdown
   - Constants: Value and type information

3. ✅ **Professional Appearance** - Comparable to lazygit/lazydocker visual quality
   - Clean borders
   - Consistent color usage
   - Proper spacing and alignment
   - No visual glitches

4. ✅ **Reduced Cognitive Load** - Visual hierarchy guides user attention
   - Colors indicate importance (primary, secondary, muted)
   - Borders separate concerns (list vs preview)
   - Headers provide context

### Testing Requirements

1. ✅ **All unit tests passing**
   - test_tui_colors.odin
   - test_tui_panel.odin
   - Existing TUI tests

2. ✅ **Component tests passing**
   - Golden file verification
   - Visual regression tests

3. ✅ **Integration tests passing**
   - test_tui_workflows.rb
   - Manual testing checklist complete

4. ✅ **Performance benchmarks acceptable**
   - bench_tui_render.odin
   - All scenarios < 50ms

### Documentation Requirements

1. ✅ **CLAUDE.md updated**
   - New color system documented
   - Panel architecture explained
   - API reference for new functions

2. ✅ **README.md updated**
   - TUI section updated with screenshots
   - New features listed

3. ✅ **Code comments**
   - All new functions have docstrings
   - Complex logic explained

---

## Approval & Next Steps

### Approval Checklist

Review this PRP and verify:

- [ ] **Problem understood** - Current state clearly documented, user feedback incorporated
- [ ] **Solution appropriate** - Incremental approach, leverages existing code, low risk
- [ ] **Scope clear** - 3 phases with independent value, optional stopping points
- [ ] **Timeline acceptable** - 19-27 hours over 2-3 weeks
- [ ] **Resources available** - Research complete, implementation plan detailed
- [ ] **Success criteria measurable** - Clear metrics for each phase
- [ ] **Risks mitigated** - Low overall risk, medium risks have mitigation plans

### Decision Points

**After Phase 1 (Colors + Borders):**
- ✅ Continue to Phase 2? (Recommended - completes user's "ventanas" request)
- ⚠️ Stop here? (Acceptable - 80% visual improvement achieved)

**After Phase 2 (Multi-Panel Layout):**
- ✅ Continue to Phase 3? (Recommended - polish and advanced features)
- ⚠️ Stop here? (Acceptable - core features complete)

**After Phase 3 (Polish):**
- ✅ Release v2.2.0

### Next Steps After Approval

1. **Create feature branch**
   ```bash
   git checkout -b feature/prp-14-tui-visual-restoration
   ```

2. **Set up milestone**
   - GitHub milestone: "v2.2.0 - TUI Visual Restoration"
   - Link PRP-14 issues to milestone

3. **Begin Phase 1 implementation**
   - Task 1.1: Create tui_colors.odin
   - Task 1.2: Add colored rendering functions
   - ...

4. **Daily progress tracking**
   - Update TODO list in CLAUDE.md
   - Commit frequently with descriptive messages
   - Push to feature branch regularly

5. **Phase 1 review**
   - Demo colorful TUI to stakeholders
   - Gather feedback
   - Decide: continue to Phase 2 or stop

6. **Continue through phases**
   - Repeat for Phase 2 and Phase 3
   - Review at each milestone

7. **Final release**
   - Merge feature branch to main
   - Tag release: v2.2.0
   - Update CHANGELOG
   - Announce new features

---

## References

### Internal Documentation

- **Research Reports** (from research phase):
  1. TUI Rendering Patterns Research (~4,000 words)
  2. ANSI Color Implementation Research (~5,000 words)
  3. Panel/Layout Systems Research (~3,000 words)
  4. ANSI Standards Documentation (~3,000 words)

- **Codebase Files**:
  - `src/tui/tui_screen.odin` - Cell and Screen buffer
  - `src/tui/tui_render.odin` - Rendering functions
  - `src/tui/tui_views.odin` - View implementations
  - `src/tui/tui_main.odin` - TEA event loop
  - `src/colors.odin` - Main package color system
  - `src/style.odin` - Style system
  - `src/types.odin` - BorderStyle enum

- **Planning Documents**:
  - `docs/planning/PRP-14_TUI_VISUAL_RESTORATION.md` - High-level planning
  - `docs/references/TUI_DESIGN_PATTERNS.md` - Design patterns research
  - `PRPs/README.md` - PRP methodology
  - `PRPs/PRP-13_COMPONENT_TESTING_BASE.md` - Component testing framework

### External References

**ANSI Standards:**
- ECMA-48 (5th Edition, 1991): https://www.ecma-international.org/publications/standards/Ecma-048.htm
- ISO/IEC 6429:1992: https://www.iso.org/standard/12782.html
- Wikipedia ANSI Escape Code: https://en.wikipedia.org/wiki/ANSI_escape_code
- XTerm Control Sequences: https://www.invisible-island.net/xterm/ctlseqs/ctlseqs.html

**Unicode:**
- Box Drawing Block: https://www.unicode.org/charts/PDF/U2500.pdf
- Unicode Table: https://unicode-table.com/en/blocks/box-drawing/

**Color References:**
- 256 Colors Cheat Sheet: https://www.ditig.com/256-colors-cheat-sheet
- Terminal Colors Guide: https://chrisyeh96.github.io/2020/03/28/terminal-colors.html

**TUI Frameworks & Examples:**
- Lazygit: https://github.com/jesseduffield/lazygit
- Lazydocker: https://github.com/jesseduffield/lazydocker
- K9s: https://github.com/derailed/k9s
- Ratatui (Rust): https://ratatui.rs/
- Bubbletea (Go): https://github.com/charmbracelet/bubbletea

### Tool Documentation

- **Odin Language**: https://odin-lang.org/docs/
- **Task (Taskfile)**: https://taskfile.dev/
- **Golden File Testing**: Component testing framework from PRP-13

---

## Appendix

### A. Color Palette Visual Reference

```
PRIMARY (Hot Pink #E40050):     ████████  Used for: Headers, selection, focused borders
SECONDARY (Teal #0E7490):       ████████  Used for: Success, info, secondary elements
ERROR (Dark Red #991B1B):       ████████  Used for: Error messages
WARNING (Orange #D97706):       ████████  Used for: Warnings
MUTED (Light Gray #D0D0D0):     ████████  Used for: Normal text, inactive items
DIM (Gray #646464):             ████████  Used for: Disabled text, footers

BG_NORMAL (Dark #181825):       ████████  Used for: Default background
BG_SELECTED (Black #090909):    ████████  Used for: Selection highlight
BG_HEADER (Dark #121B1B):       ████████  Used for: Header/footer bars

BORDER_NORMAL (Gray #646464):   ┌─────┐  Used for: Inactive panels
BORDER_FOCUSED (Hot Pink):      ┌─────┐  Used for: Active panel
```

### B. Terminal Size Recommendations

**Minimum:** 80x24 (standard VT100)
**Recommended:** 120x40 (optimal for split views)
**Maximum:** Unlimited (scales appropriately)

**Layout breakdown at 80x24:**
- Header: 3 lines
- Content area: 19 lines
- Footer: 2 lines

**Split view at 80x24:**
- List panel: 24 columns (30%)
- Preview panel: 55 columns (70%)
- Border: 1 column

### C. Keyboard Shortcuts Quick Reference

**Global:**
- `↑/↓` or `j/k` - Navigate
- `Enter` - Select
- `Esc` - Go back
- `Ctrl+C` - Quit immediately
- `q` - Quit from main menu

**List Views:**
- `d` or `x` - Delete selected item
- `/` - Enter search mode (Phase 3)
- `c` - Cleanup (Backups view only)

**Search Mode (Phase 3):**
- `Type` - Filter items
- `↑/↓` - Navigate results
- `Enter` - Select result
- `Esc` - Exit search

---

**Document End**

**Status**: ✅ Ready for Implementation
**Total Pages**: ~65 pages
**Word Count**: ~20,000 words
**Research Hours**: 8 hours
**Implementation Estimate**: 19-27 hours
**Target Release**: v2.2.0

**Approval Required From:**
- [ ] Project Owner
- [ ] Lead Developer
- [ ] UX Review (optional)

**Once approved, proceed to:** Create feature branch and begin Phase 1 (Task 1.1)
