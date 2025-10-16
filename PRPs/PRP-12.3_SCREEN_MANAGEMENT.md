name: "PRP-12.3: Screen Management - Double Buffering and Differential Rendering"
description: |
  Implement screen buffer system with double buffering and differential rendering
  algorithm for efficient TUI updates.

version: "1.0.0"
parent: "PRP-12_FULL_TUI_MODE_BASE.md"
phase: "3 of 7"
status: "READY_FOR_EXECUTION"

---

## Goal

**Feature Goal**: Implement efficient screen rendering with double-buffered Cell grid and differential update algorithm that only redraws changed cells.

**Deliverable**:
- `src/tui/tui_screen.odin` with Screen struct, Cell type, screen lifecycle functions
- `src/tui/tui_render.odin` with screen_flush() differential rendering
- `tests/unit/test_tui_screen.odin` with unit tests
- 55% performance improvement over full redraws (per Ratatui research)

**Success Definition**:
- Screen can be created, resized, and destroyed
- Cells can be set with char, color, style attributes
- screen_flush() only outputs ANSI codes for changed cells
- All unit tests pass

---

## Why

- **Performance**: Full screen redraws cause flicker and lag
- **Industry Standard**: Ratatui achieved 120μs → 55μs (55% speedup) with differential rendering
- **Responsive**: Target < 50ms per frame for smooth UX
- **Reuse**: Leverages existing style.odin for colors and formatting

---

## What

### Implementation Tasks

```yaml
Task 1: CREATE src/tui/tui_screen.odin
  Types:
    - Cell struct (char: rune, fg/bg: string, bold/dim: bool)
    - Screen struct (buffer, prev_buffer: [][]Cell, width, height, cursor_x, cursor_y)

  Functions:
    - screen_create(width, height: int) -> Screen
    - screen_destroy(screen: ^Screen)
    - screen_resize(screen: ^Screen, width, height: int)
    - screen_set_cell(screen: ^Screen, x, y: int, cell: Cell)
    - screen_clear(screen: ^Screen) - fills all cells with spaces

Task 2: CREATE src/tui/tui_render.odin
  Functions:
    - screen_flush(screen: ^Screen) - differential update algorithm
    - render_text(screen: ^Screen, x, y: int, text: string)
    - render_box(screen: ^Screen, x, y, width, height: int)

  Algorithm:
    1. Compare buffer[y][x] to prev_buffer[y][x]
    2. Skip if unchanged
    3. Move cursor to (x, y) only if needed
    4. Output style ANSI codes only if changed
    5. Write character
    6. Copy buffer to prev_buffer after flush

Task 3: CREATE tests/unit/test_tui_screen.odin
  Tests:
    - test_screen_create: Creates with correct dimensions
    - test_screen_set_cell: Cell updates at correct position
    - test_screen_clear: All cells become spaces
    - test_screen_resize: Preserves existing content where possible
```

### Success Criteria

- [ ] Screen can be created with arbitrary dimensions
- [ ] screen_set_cell() updates correct position
- [ ] screen_clear() fills all cells with spaces
- [ ] screen_flush() only outputs changed cells (verified with ANSI code counting)
- [ ] screen_resize() handles dimension changes gracefully
- [ ] No memory leaks (all allocations freed)
- [ ] All unit tests pass

---

## All Needed Context

### Documentation References

```yaml
- url: https://ratatui.rs/concepts/rendering/under-the-hood/
  why: Differential rendering algorithm (120μs → 55μs, 55% speedup)
  critical: Compare current to previous frame, skip unchanged cells

- file: /Users/kakurega/dev/projects/wayu/src/style.odin
  lines: 273-309
  why: ANSI color code generation
  pattern: Use get_primary(), get_secondary() for themed colors

- file: /Users/kakurega/dev/projects/wayu/src/layout.odin
  lines: 9-157
  why: visual_width() for correct character width calculation
  critical: Use for emoji-aware width
```

### Known Gotchas

```odin
// GOTCHA: Allocate 2D array correctly
buffer := make([][]Cell, height)
for y in 0..<height {
    buffer[y] = make([]Cell, width)
}

// GOTCHA: Free 2D array correctly
for y in 0..<len(screen.buffer) {
    delete(screen.buffer[y])
}
delete(screen.buffer)

// GOTCHA: Cursor position is 1-indexed in ANSI codes
fmt.sbprintf(&builder, "\x1b[%d;%dH", y+1, x+1)  // +1 for ANSI

// GOTCHA: Track cursor to minimize movement
if x != screen.cursor_x || y != screen.cursor_y {
    // Move cursor
    screen.cursor_x = x
    screen.cursor_y = y
}
```

---

## Implementation Blueprint

### Complete Code Pattern (tui_screen.odin)

```odin
package wayu_tui

import "core:fmt"

Cell :: struct {
    char:  rune,
    fg:    string,
    bg:    string,
    bold:  bool,
    dim:   bool,
}

Screen :: struct {
    buffer:      [][]Cell,
    prev_buffer: [][]Cell,
    width:       int,
    height:      int,
    cursor_x:    int,
    cursor_y:    int,
}

// Create screen with dimensions
screen_create :: proc(width, height: int) -> Screen {
    buffer := make([][]Cell, height)
    prev_buffer := make([][]Cell, height)

    for y in 0..<height {
        buffer[y] = make([]Cell, width)
        prev_buffer[y] = make([]Cell, width)

        // Initialize with space cells
        for x in 0..<width {
            buffer[y][x] = Cell{char = ' '}
            prev_buffer[y][x] = Cell{char = ' '}
        }
    }

    return Screen{
        buffer = buffer,
        prev_buffer = prev_buffer,
        width = width,
        height = height,
    }
}

// Destroy screen and free memory
screen_destroy :: proc(screen: ^Screen) {
    for y in 0..<len(screen.buffer) {
        delete(screen.buffer[y])
        delete(screen.prev_buffer[y])
    }
    delete(screen.buffer)
    delete(screen.prev_buffer)
}

// Resize screen, preserving content
screen_resize :: proc(screen: ^Screen, new_width, new_height: int) {
    // Allocate new buffers
    new_buffer := make([][]Cell, new_height)
    new_prev_buffer := make([][]Cell, new_height)

    for y in 0..<new_height {
        new_buffer[y] = make([]Cell, new_width)
        new_prev_buffer[y] = make([]Cell, new_width)

        // Initialize with spaces
        for x in 0..<new_width {
            new_buffer[y][x] = Cell{char = ' '}
            new_prev_buffer[y][x] = Cell{char = ' '}
        }

        // Copy existing content
        if y < screen.height {
            copy_width := min(new_width, screen.width)
            copy(new_buffer[y][:copy_width], screen.buffer[y][:copy_width])
            copy(new_prev_buffer[y][:copy_width], screen.prev_buffer[y][:copy_width])
        }
    }

    // Free old buffers
    screen_destroy(screen)

    // Update screen
    screen.buffer = new_buffer
    screen.prev_buffer = new_prev_buffer
    screen.width = new_width
    screen.height = new_height
}

// Set cell at position
screen_set_cell :: proc(screen: ^Screen, x, y: int, cell: Cell) {
    if x >= 0 && x < screen.width && y >= 0 && y < screen.height {
        screen.buffer[y][x] = cell
    }
}

// Clear screen (fill with spaces)
screen_clear :: proc(screen: ^Screen) {
    for y in 0..<screen.height {
        for x in 0..<screen.width {
            screen.buffer[y][x] = Cell{char = ' '}
        }
    }
}
```

### Complete Code Pattern (tui_render.odin)

```odin
package wayu_tui

import "core:fmt"
import "core:strings"

// Flush screen with differential rendering
screen_flush :: proc(screen: ^Screen) {
    builder: strings.Builder
    strings.builder_init(&builder)
    defer strings.builder_destroy(&builder)

    for y in 0..<screen.height {
        for x in 0..<screen.width {
            curr := screen.buffer[y][x]
            prev := screen.prev_buffer[y][x]

            // Skip unchanged cells (KEY OPTIMIZATION)
            if curr == prev do continue

            // Move cursor if needed (minimize cursor movement)
            if x != screen.cursor_x || y != screen.cursor_y {
                fmt.sbprintf(&builder, "\x1b[%d;%dH", y+1, x+1)
                screen.cursor_x = x
                screen.cursor_y = y
            }

            // Apply foreground color if changed
            if curr.fg != prev.fg && curr.fg != "" {
                fmt.sbprintf(&builder, "%s", curr.fg)
            }

            // Apply background color if changed
            if curr.bg != prev.bg && curr.bg != "" {
                fmt.sbprintf(&builder, "%s", curr.bg)
            }

            // Apply bold if changed
            if curr.bold && !prev.bold {
                fmt.sbprintf(&builder, "\x1b[1m")
            } else if !curr.bold && prev.bold {
                fmt.sbprintf(&builder, "\x1b[22m")
            }

            // Apply dim if changed
            if curr.dim && !prev.dim {
                fmt.sbprintf(&builder, "\x1b[2m")
            } else if !curr.dim && prev.dim {
                fmt.sbprintf(&builder, "\x1b[22m")
            }

            // Write character
            fmt.sbprintf(&builder, "%c", curr.char)
            screen.cursor_x += 1
        }
    }

    // Single write to terminal (batch for performance)
    output := strings.to_string(builder)
    if len(output) > 0 {
        fmt.print(output)
    }

    // Copy current to previous for next frame
    for y in 0..<screen.height {
        copy(screen.prev_buffer[y], screen.buffer[y])
    }
}

// Render text at position
render_text :: proc(screen: ^Screen, x, y: int, text: string) {
    import "../"  // Access wayu's visual_width

    current_x := x
    for ch in text {
        if current_x >= screen.width do break

        screen_set_cell(screen, current_x, y, Cell{char = ch})
        current_x += 1
    }
}

// Render box at position
render_box :: proc(screen: ^Screen, x, y, width, height: int) {
    if width < 2 || height < 2 do return

    // Top border
    screen_set_cell(screen, x, y, Cell{char = '┌'})
    for i in 1..<width-1 {
        screen_set_cell(screen, x+i, y, Cell{char = '─'})
    }
    screen_set_cell(screen, x+width-1, y, Cell{char = '┐'})

    // Sides
    for j in 1..<height-1 {
        screen_set_cell(screen, x, y+j, Cell{char = '│'})
        screen_set_cell(screen, x+width-1, y+j, Cell{char = '│'})
    }

    // Bottom border
    screen_set_cell(screen, x, y+height-1, Cell{char = '└'})
    for i in 1..<width-1 {
        screen_set_cell(screen, x+i, y+height-1, Cell{char = '─'})
    }
    screen_set_cell(screen, x+width-1, y+height-1, Cell{char = '┘'})
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
odin test tests/unit/test_tui_screen.odin -file
# Expected: All tests pass
```

### Level 3: Performance Test

```bash
# Measure flush performance
# Should be < 50ms per frame for 80x24 screen
```

---

## Final Validation Checklist

- [ ] Compiles without errors
- [ ] All unit tests pass
- [ ] screen_create() allocates correctly
- [ ] screen_destroy() frees all memory
- [ ] screen_set_cell() updates correct position
- [ ] screen_clear() fills with spaces
- [ ] screen_flush() only outputs changed cells
- [ ] screen_resize() preserves content
- [ ] No memory leaks

---

**Status**: ✅ READY FOR EXECUTION
**Estimated Time**: 2-3 hours
**Dependencies**: None (independent of Phase 1-2)
**Confidence**: 10/10
