# PRP-13: Component Testing CLI

## Goal

**Feature Goal**: Create a CLI testing framework that allows isolated rendering and visual verification of TUI components through `wayu -c=<component>` commands, enabling developers to test component rendering, alignment, emoji handling, and responsive sizing without launching the full TUI.

**Deliverable**: A `wayu -c=<component> [args...]` command system with:
- Headless rendering for all TUI components
- Plain text output suitable for golden file testing
- Support for multiple component states and dimensions
- Integration with existing test infrastructure

**Success Definition**:
- All TUI components (box, list_item, header, footer, scroll_indicator, empty_state) are testable via CLI
- Components can be rendered with different states (selected/unselected, empty/populated, varying dimensions)
- Output is deterministic and suitable for regression testing with golden files
- Execution time < 100ms per component test
- Zero regressions in existing TUI functionality

## User Persona

**Target User**: wayu developers (internal)

**Use Case**: Visual regression testing and component development iteration

**User Journey**:
1. Developer modifies a TUI component (e.g., list item rendering)
2. Runs `wayu -c=list-item text="📂 Path" selected=true width=40` to see output
3. Verifies emoji alignment and selection indicator
4. Creates/updates golden file with `--snapshot`
5. Runs `--test` to catch regressions in CI

**Pain Points Addressed**:
- **Slow iteration**: Currently need to launch full TUI to see component changes
- **Missing visual testing**: No way to verify emoji alignment, text truncation, border rendering
- **Manual regression detection**: Visual bugs can slip through without systematic testing
- **Edge case coverage**: Hard to test extreme dimensions or long text without full TUI

## Why

- **Developer Velocity**: Fast component iteration without full TUI launch (< 100ms vs seconds)
- **Quality Assurance**: Catch visual regressions before merge through golden file testing
- **Edge Case Testing**: Systematically test components at various dimensions and states
- **Documentation**: Component tests serve as living documentation of expected rendering
- **Integration with CI**: Automated visual regression detection in pull requests

## What

A CLI mode that renders individual TUI components in isolation with headless (non-TTY) output.

### Core Functionality

**Component Registry:**
- box - Border box with unicode characters (┌─┐│└┘)
- list_item - Single list entry with selection state
- header - View header with emoji, title, and count
- footer - Footer with keyboard shortcuts
- scroll_indicator - Pagination info (Showing N-M of Total)
- empty_state - Empty/loading messages

**CLI Interface:**
```bash
# Render component
wayu -c=box width=20 height=5

# With state
wayu -c=list-item text="📂 /usr/bin" selected=true width=40

# Create golden file
wayu -c=header title="PATH" count=10 width=40 --snapshot

# Test against golden
wayu -c=box width=20 height=5 --test
```

**Output Format:**
- Plain text (no ANSI escape codes for diff compatibility)
- Exact visual representation as seen in TUI
- Deterministic (same input → same output)
- Newline-separated for easy diff

### Success Criteria

- [ ] All 6 component types renderable via `-c` flag
- [ ] Components accept state parameters (text, selected, width, height, etc.)
- [ ] Output matches TUI rendering exactly (character-for-character)
- [ ] `--snapshot` mode creates golden files in `tests/golden/`
- [ ] `--test` mode compares output with golden and shows diff on mismatch
- [ ] Component tests run in < 100ms each
- [ ] Integration with `task test:components` in Taskfile
- [ ] Zero regressions in existing TUI (all 37 tests still pass)

## All Needed Context

### Context Completeness Check

✅ **Validation Complete**: This PRP contains:
- Exact file paths for all patterns to follow
- Specific line numbers for key implementations
- Complete component catalog with all required states
- Golden file structure and location
- Validation commands verified in codebase

### Documentation & References

```yaml
# MUST READ - Core TUI Implementation
- file: src/tui/tui_render.odin
  why: Contains render_box() and render_text() - the primitive components
  pattern: Lines 74-107 show how to render to Screen buffer
  gotcha: tprintf() uses temp buffer - do NOT delete (see line 40 comment)

- file: src/tui/tui_screen.odin
  why: Screen and Cell struct definitions - foundation for headless rendering
  pattern: Lines 5-20 define Cell{char, fg, bg, bold, dim} and Screen{buffer, width, height}
  gotcha: Must call screen_destroy() to free buffer memory (lines 47-54)

- file: src/tui/tui_views.odin
  why: Complex component rendering (headers, footers, list items, scroll indicators)
  pattern: Lines 26-78 (render_path_view) show complete view rendering with all sub-components
  gotcha: Loading state check (line 28) - data_cache may be nil

# MUST READ - Testing Patterns
- file: tests/ui/test_render_box.odin
  why: Existing UI testing pattern with visual width verification
  pattern: Lines 34-69 (verify_box_alignment) show how to test unicode box rendering
  critical: strip_ansi() function (lines 15-31) - essential for comparing golden files

- file: tests/ui/test_render_box.odin
  why: Test execution pattern and pass/fail reporting
  pattern: Lines 71-213 show test structure: render → verify → report ✓/✗
  gotcha: Tests run with `odin run` -file flag, not through test framework

# MUST READ - CLI Argument Parsing
- file: src/main.odin
  why: Existing arg parsing with ParsedArgs struct and flag handling
  pattern: Lines 153-274 (parse_args) show command/action/flags parsing
  gotcha: Flag filtering happens first (lines 162-188), then command parsing
  critical: --tui flag pattern (lines 169-170) - use same approach for -c flag

# Core Library Functions
- url: https://pkg.odin-lang.org/core/strings/#Builder
  why: String building for buffer-to-string conversion
  critical: Must call strings.builder_destroy() to free memory

- url: https://pkg.odin-lang.org/core/fmt/#sbprintf
  why: String builder formatted printing (used extensively in TUI)
  critical: Different from tprintf() - sbprintf() appends to builder

# Golden File Testing Pattern
- url: https://github.com/golang/go/wiki/TableDrivenTests#golden-files
  why: Golden file testing methodology (adapted from Go testing)
  critical: Store expected output, compare byte-for-byte, show diff on mismatch
```

### Current Codebase Tree

```bash
wayu/
├── src/
│   ├── main.odin              # CLI entry point, arg parsing
│   ├── tui/
│   │   ├── tui_screen.odin    # Screen/Cell structs, buffer management
│   │   ├── tui_render.odin    # Primitive rendering (box, text)
│   │   ├── tui_views.odin     # Complex components (headers, footers, lists)
│   │   └── [other tui files]
│   └── [other source files]
├── tests/
│   ├── unit/                  # Unit tests (218 tests)
│   ├── ui/                    # UI tests (10 tests)
│   │   ├── test_render_box.odin  # Box alignment verification
│   │   └── [other UI tests]
│   └── integration/           # Integration tests (27 tests)
└── Taskfile.yml               # Task automation
```

### Desired Codebase Tree with New Files

```bash
wayu/
├── src/
│   ├── main.odin              # [MODIFY] Add -c flag parsing, component_test mode
│   ├── component_test.odin    # [CREATE] Component testing CLI implementation
│   ├── tui/
│   │   ├── tui_screen.odin    # [MODIFY] Add screen_to_string() for headless output
│   │   ├── tui_render.odin    # [NO CHANGE] Reuse existing functions
│   │   ├── tui_views.odin     # [NO CHANGE] Reuse existing functions
│   │   └── tui_components.odin # [CREATE] Component registry and args parsing
└── tests/
    ├── golden/                # [CREATE] Golden file storage directory
    │   ├── box_10x3.txt
    │   ├── list_item_selected_40.txt
    │   └── [component golden files]
    └── unit/
        └── test_components.odin  # [CREATE] Component testing unit tests
```

### Known Gotchas & Library Quirks

```odin
// CRITICAL: fmt.tprintf() uses temporary buffer - never delete()
text := fmt.tprintf("> %s", item)
// NO: defer delete(text)  ❌ This causes double-free
// YES: Just use it directly ✓

// CRITICAL: Screen buffer memory management
screen := screen_create(width, height)
defer screen_destroy(&screen)  // MUST call to free buffer memory
// Each row is allocated separately, must free all

// CRITICAL: String builder lifecycle
builder: strings.Builder
strings.builder_init(&builder)
defer strings.builder_destroy(&builder)  // MUST destroy to free
output := strings.to_string(builder)
// output is valid until builder destroyed

// GOTCHA: Cell struct has string fields (fg, bg)
Cell :: struct {
    char: rune,
    fg:   string,  // Empty string = no color
    bg:   string,  // Empty string = no color
    bold: bool,
    dim:  bool,
}
// For headless mode: leave fg/bg empty (plain text output)

// GOTCHA: ParsedArgs struct uses defer for cleanup
parsed := parse_args(os.args[1:])
defer if len(parsed.args) > 0 do delete(parsed.args)
// Only delete if args were allocated

// CRITICAL: Unicode box drawing characters are multi-byte
// Use rune type, not byte, for box characters
Cell{char = '┌'}  // Correct
// These are 3 bytes each in UTF-8: ┌ ─ ┐ │ └ ┘
```

## Implementation Blueprint

### Data Models and Structure

```odin
// src/tui/tui_components.odin

package wayu_tui

ComponentType :: enum {
    BOX,
    LIST_ITEM,
    HEADER,
    FOOTER,
    SCROLL_INDICATOR,
    EMPTY_STATE,
}

ComponentArgs :: struct {
    // Common args
    width:    int,
    height:   int,

    // Text content
    text:     string,
    title:    string,
    message:  string,

    // State
    selected: bool,

    // Numeric data
    count:    int,
    start:    int,  // For scroll indicator
    end:      int,
    total:    int,

    // Visual elements
    emoji:    string,
    shortcuts: string,  // Comma-separated "key=action" pairs
}

// Parse component type from string
parse_component_type :: proc(name: string) -> (ComponentType, bool) {
    switch name {
    case "box":
        return .BOX, true
    case "list-item", "list_item":
        return .LIST_ITEM, true
    case "header":
        return .HEADER, true
    case "footer":
        return .FOOTER, true
    case "scroll", "scroll-indicator", "scroll_indicator":
        return .SCROLL_INDICATOR, true
    case "empty", "empty-state", "empty_state":
        return .EMPTY_STATE, true
    case:
        return .BOX, false  // Default, but signal error
    }
}

// Parse component arguments from CLI
parse_component_args :: proc(args: []string) -> ComponentArgs {
    result := ComponentArgs{
        width = 80,   // Default terminal width
        height = 24,  // Default terminal height
        selected = false,
    }

    for arg in args {
        if !strings.contains(arg, "=") do continue

        parts := strings.split(arg, "=")
        defer delete(parts)

        if len(parts) != 2 do continue

        key := strings.trim_space(parts[0])
        value := strings.trim_space(parts[1])

        switch key {
        case "width":
            result.width, _ = strconv.parse_int(value)
        case "height":
            result.height, _ = strconv.parse_int(value)
        case "text":
            result.text = strings.clone(value)
        case "title":
            result.title = strings.clone(value)
        case "message":
            result.message = strings.clone(value)
        case "selected":
            result.selected = (value == "true" || value == "1")
        case "count":
            result.count, _ = strconv.parse_int(value)
        case "start":
            result.start, _ = strconv.parse_int(value)
        case "end":
            result.end, _ = strconv.parse_int(value)
        case "total":
            result.total, _ = strconv.parse_int(value)
        case "emoji":
            result.emoji = strings.clone(value)
        case "shortcuts":
            result.shortcuts = strings.clone(value)
        }
    }

    return result
}

// Free component args
component_args_destroy :: proc(args: ^ComponentArgs) {
    if args.text != "" do delete(args.text)
    if args.title != "" do delete(args.title)
    if args.message != "" do delete(args.message)
    if args.emoji != "" do delete(args.emoji)
    if args.shortcuts != "" do delete(args.shortcuts)
}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY src/tui/tui_screen.odin
  - IMPLEMENT: screen_to_string() procedure
  - PURPOSE: Convert Screen buffer to plain text string (no ANSI codes)
  - FOLLOW pattern: screen_flush() (lines 8-71) for buffer iteration
  - NAMING: screen_to_string(screen: ^Screen) -> string
  - PLACEMENT: After screen_clear() (line 98)
  - CRITICAL: Use strings.Builder, must call builder_destroy() in defer
  - RETURN: Plain text with newlines, no cursor codes, no colors

Task 2: CREATE src/tui/tui_components.odin
  - IMPLEMENT: ComponentType enum, ComponentArgs struct
  - IMPLEMENT: parse_component_type(), parse_component_args(), component_args_destroy()
  - IMPLEMENT: render_component() dispatcher
  - FOLLOW pattern: src/tui/tui_state.odin (lines 5-20) for enum/struct definitions
  - NAMING: snake_case for procs, CamelCase for types
  - DEPENDENCIES: Import "../tui" for Screen, render_box, render_text
  - PLACEMENT: New file in src/tui/ directory
  - VALIDATION: Each component type must map to existing render function

Task 3: CREATE src/component_test.odin
  - IMPLEMENT: Component test CLI mode entry point
  - IMPLEMENT: Golden file save/load/compare logic
  - FOLLOW pattern: src/main.odin (lines 88-151) for CLI structure
  - FOLLOW pattern: tests/ui/test_render_box.odin (lines 15-31) for strip_ansi()
  - NAMING: run_component_test(), save_golden(), compare_golden()
  - DEPENDENCIES: Import "tui" for component rendering
  - PLACEMENT: Root src/ directory (peer to main.odin)
  - CRITICAL: Must handle golden file not found gracefully

Task 4: MODIFY src/main.odin
  - INTEGRATE: Parse -c=<component> flag
  - INTEGRATE: Route to component test mode
  - FIND pattern: Lines 153-274 (parse_args function)
  - ADD: ComponentTest mode to ParsedArgs struct (after line 63)
  - ADD: -c flag parsing in parse_args (similar to --tui at line 169)
  - PRESERVE: All existing command/action parsing
  - CRITICAL: Component test must NOT conflict with existing commands

Task 5: CREATE tests/unit/test_components.odin
  - IMPLEMENT: Unit tests for component rendering
  - TEST: Each component type with multiple states
  - FOLLOW pattern: tests/unit/test_style.odin for test structure
  - NAMING: @(test) test_<component>_<state>
  - COVERAGE: All 6 component types with at least 2 states each
  - PLACEMENT: tests/unit/ directory

Task 6: MODIFY Taskfile.yml
  - INTEGRATE: Add test:components task
  - FIND pattern: Existing test tasks (lines with "test:")
  - ADD: test:components task that runs component tests
  - ADD: test:components:snapshot task for golden file creation
  - PRESERVE: All existing test tasks

Task 7: CREATE tests/golden/ directory structure
  - CREATE: tests/golden/ directory
  - CREATE: Initial golden files for each component
  - NAMING: <component>_<dimensions>.txt (e.g., box_10x3.txt)
  - ORGANIZATION: Flat structure (all golden files in single directory)
```

### Implementation Patterns & Key Details

```odin
// PATTERN: Headless screen rendering (Task 1)
// src/tui/tui_screen.odin - Add after screen_clear()

screen_to_string :: proc(screen: ^Screen) -> string {
    builder: strings.Builder
    strings.builder_init(&builder)
    defer strings.builder_destroy(&builder)

    for y in 0..<screen.height {
        for x in 0..<screen.width {
            cell := screen.buffer[y][x]
            // Write only the character, no ANSI codes
            fmt.sbprintf(&builder, "%c", cell.char)
        }
        // Add newline except for last line
        if y < screen.height - 1 {
            fmt.sbprintf(&builder, "\n")
        }
    }

    // Clone before builder destroyed
    return strings.clone(strings.to_string(builder))
}

// GOTCHA: Must clone output before builder destroyed
// GOTCHA: No newline after last line (matches terminal behavior)


// PATTERN: Component rendering dispatcher (Task 2)
// src/tui/tui_components.odin

render_component :: proc(type: ComponentType, args: ComponentArgs) -> string {
    // Create headless screen buffer
    screen := screen_create(args.width, args.height)
    defer screen_destroy(&screen)

    // Clear to spaces
    screen_clear(&screen)

    // Render based on component type
    switch type {
    case .BOX:
        // Render box filling entire screen
        render_box(&screen, 0, 0, args.width, args.height)

    case .LIST_ITEM:
        // Render list item with selection indicator
        prefix := args.selected ? "> " : "  "
        text := fmt.tprintf("%s%s", prefix, args.text)
        render_text(&screen, 0, 0, text)

    case .HEADER:
        // Render header with emoji and title
        header_line := args.emoji != "" ?
            fmt.tprintf("%s %s", args.emoji, args.title) :
            args.title
        render_text(&screen, 2, 0, header_line)

        // Render count if provided
        if args.count > 0 {
            count_line := fmt.tprintf("%d entries", args.count)
            render_text(&screen, 2, 1, count_line)
        }

    case .FOOTER:
        // Render footer at bottom
        render_text(&screen, 2, args.height - 1, args.shortcuts)

    case .SCROLL_INDICATOR:
        // Render scroll position
        scroll_text := fmt.tprintf("Showing %d-%d of %d",
            args.start, args.end, args.total)
        render_text(&screen, 2, 0, scroll_text)

    case .EMPTY_STATE:
        // Center message vertically
        y := args.height / 2
        x := (args.width - len(args.message)) / 2
        render_text(&screen, x, y, args.message)
    }

    // Convert to plain text
    output := screen_to_string(&screen)
    return output
}

// GOTCHA: Must defer screen_destroy() to prevent memory leak
// GOTCHA: tprintf() for formatting, but don't delete the result
// CRITICAL: All text uses render_text() which handles bounds checking


// PATTERN: Golden file comparison (Task 3)
// src/component_test.odin

GOLDEN_DIR :: "tests/golden"

compare_golden :: proc(component: string, args: ComponentArgs, output: string) -> bool {
    // Build golden file path
    filename := fmt.aprintf("%s/%s_%dx%d.txt",
        GOLDEN_DIR, component, args.width, args.height)
    defer delete(filename)

    // Check if golden file exists
    if !os.exists(filename) {
        fmt.eprintfln("ERROR: Golden file not found: %s", filename)
        fmt.eprintfln("Create it with: wayu -c=%s [args...] --snapshot", component)
        return false
    }

    // Read golden file
    golden_data, ok := os.read_entire_file_from_filename(filename)
    if !ok {
        fmt.eprintfln("ERROR: Failed to read golden file: %s", filename)
        return false
    }
    defer delete(golden_data)

    golden_str := string(golden_data)

    // Compare
    if output != golden_str {
        fmt.eprintfln("✗ MISMATCH: %s", filename)
        fmt.eprintln("\nExpected:")
        fmt.eprintln(golden_str)
        fmt.eprintln("\nGot:")
        fmt.eprintln(output)
        return false
    }

    fmt.printfln("✓ MATCH: %s", filename)
    return true
}

save_golden :: proc(component: string, args: ComponentArgs, output: string) -> bool {
    // Ensure directory exists
    os.make_directory(GOLDEN_DIR)

    // Build golden file path
    filename := fmt.aprintf("%s/%s_%dx%d.txt",
        GOLDEN_DIR, component, args.width, args.height)
    defer delete(filename)

    // Write golden file
    ok := os.write_entire_file(filename, transmute([]byte)output)
    if !ok {
        fmt.eprintfln("ERROR: Failed to write golden file: %s", filename)
        return false
    }

    fmt.printfln("✓ Saved golden file: %s", filename)
    return true
}

// CRITICAL: os.make_directory() is idempotent (safe to call multiple times)
// GOTCHA: transmute([]byte)string for os.write_entire_file()
// PATTERN: Diff output shows both expected and actual for easy debugging


// PATTERN: CLI integration (Task 4)
// src/main.odin - Add to ParsedArgs struct (after line 63)

ParsedArgs :: struct {
    command: Command,
    action:  Action,
    args:    []string,
    shell:   ShellType,
    tui:     bool,

    // Component testing (PRP-13)
    component_test: bool,
    component_name: string,
    component_snapshot: bool,
    component_verify: bool,
}

// Parse -c flag (in parse_args, similar to --tui at line 169)
} else if strings.has_prefix(arg, "-c=") {
    parsed.component_test = true
    parsed.component_name = strings.trim_prefix(arg, "-c=")
} else if arg == "--snapshot" {
    parsed.component_snapshot = true
} else if arg == "--test" {
    parsed.component_verify = true
}

// Route to component test mode (in main(), after TUI check at line 123)
if parsed.component_test {
    run_component_test(parsed.component_name, parsed.args,
        parsed.component_snapshot, parsed.component_verify)
    return
}

// GOTCHA: Must handle -c flag BEFORE command parsing
// GOTCHA: Component test is mutually exclusive with regular commands
```

### Integration Points

```yaml
TASKFILE:
  - add to: Taskfile.yml
  - task name: test:components
  - command: "odin run src/component_test.odin -file"
  - purpose: Run all component tests against golden files

TEST_DIRECTORY:
  - create: tests/golden/
  - purpose: Store expected component output for regression testing
  - organization: Flat directory structure, files named <component>_<dimensions>.txt

MAIN_CLI:
  - modify: src/main.odin
  - integration point: parse_args() function (lines 153-274)
  - add: -c flag parsing before command parsing
  - add: component test mode routing after TUI mode check
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after each file creation - fix before proceeding
odin check src/component_test.odin
odin check src/tui/tui_components.odin
odin check src/tui/tui_screen.odin  # For screen_to_string()

# Verify no syntax errors
# Expected: Zero errors. If errors exist, READ output and fix before proceeding.
```

### Level 2: Unit Tests (Component Validation)

```bash
# Test screen_to_string() implementation
odin test tests/unit/test_components.odin -file

# Test component rendering
odin run src/component_test.odin -file -- box width=10 height=3

# Test each component type
odin run src/component_test.odin -file -- list-item text="Test" selected=true width=40
odin run src/component_test.odin -file -- header title="Header" count=5 width=40
odin run src/component_test.odin -file -- footer shortcuts="Esc=Back" width=40
odin run src/component_test.odin -file -- scroll start=1 end=10 total=50 width=40
odin run src/component_test.odin -file -- empty message="No items" width=30 height=10

# Expected: All components render without crashing, output looks correct visually
```

### Level 3: Integration Testing (System Validation)

```bash
# Build main binary with component test support
odin build src -out:./bin/wayu -o:speed

# Test component CLI integration
./bin/wayu -c=box width=10 height=3
# Expected: Renders 10x3 box with unicode borders

# Test with emoji
./bin/wayu -c=list-item text="📂 /usr/bin" selected=true width=40
# Expected: Selected item with emoji properly aligned

# Create golden file
./bin/wayu -c=box width=10 height=3 --snapshot
# Expected: File created at tests/golden/box_10x3.txt

# Test against golden
./bin/wayu -c=box width=10 height=3 --test
# Expected: ✓ MATCH: tests/golden/box_10x3.txt

# Test mismatch detection (modify component slightly)
# Expected: ✗ MISMATCH with diff showing expected vs actual

# Verify TUI still works
./bin/wayu --tui
# Expected: TUI launches normally, all functionality intact

# Run existing test suite
task test
# Expected: All 37 tests pass (218 unit + 27 integration + 10 UI)
```

### Level 4: Golden File Regression Testing

```bash
# Create golden files for all components
./bin/wayu -c=box width=10 height=3 --snapshot
./bin/wayu -c=box width=20 height=5 --snapshot
./bin/wayu -c=list-item text="Item" selected=false width=40 --snapshot
./bin/wayu -c=list-item text="Item" selected=true width=40 --snapshot
./bin/wayu -c=list-item text="📂 Path" selected=true width=40 --snapshot
./bin/wayu -c=header title="PATH" count=10 width=40 --snapshot
./bin/wayu -c=footer shortcuts="d=Delete,Esc=Back" width=60 --snapshot
./bin/wayu -c=scroll start=1 end=10 total=50 width=40 --snapshot
./bin/wayu -c=empty message="No items found" width=30 height=10 --snapshot

# Run all golden file tests
task test:components
# Expected: All component tests pass ✓

# Test with different dimensions
./bin/wayu -c=box width=5 height=2 --snapshot --test
# Expected: New golden file created and test passes

# Verify golden file content is human-readable
cat tests/golden/box_10x3.txt
# Expected: Plain text box visible, no ANSI codes

# Test emoji alignment consistency
./bin/wayu -c=list-item text="⚠️ Warning" selected=true width=40 --test
./bin/wayu -c=list-item text="✨ Success" selected=true width=40 --test
# Expected: All emoji tests pass with correct alignment
```

## Final Validation Checklist

### Technical Validation

- [ ] All validation levels (1-4) completed successfully
- [ ] All existing tests pass: `task test` (37 tests)
- [ ] No compilation errors: `odin check src/`
- [ ] Component tests pass: `task test:components`
- [ ] Screen memory properly freed (no leaks with -debug build)

### Feature Validation

- [ ] All 6 component types render correctly
- [ ] `wayu -c=box width=10 height=3` produces correct box
- [ ] `wayu -c=list-item text="📂 Path" selected=true width=40` shows selection and emoji
- [ ] `wayu -c=header title="PATH" count=10 width=40` displays header with count
- [ ] `wayu -c=footer shortcuts="d=Delete" width=60` renders shortcuts
- [ ] `wayu -c=scroll start=1 end=10 total=50 width=40` shows pagination
- [ ] `wayu -c=empty message="No items" width=30 height=10` centers message
- [ ] `--snapshot` creates golden files in tests/golden/
- [ ] `--test` compares output and shows diff on mismatch
- [ ] Golden files are plain text (no ANSI codes)
- [ ] Component output matches TUI rendering exactly

### Code Quality Validation

- [ ] Follows existing codebase patterns (Screen/Cell usage)
- [ ] Memory management correct (defer screen_destroy, builder_destroy)
- [ ] File placement matches desired codebase tree
- [ ] No tprintf() results deleted (gotcha avoided)
- [ ] All strings properly cloned when stored
- [ ] Component args properly freed with component_args_destroy()

### Documentation & Integration

- [ ] Golden files documented (tests/golden/README.md if needed)
- [ ] Taskfile updated with test:components task
- [ ] Component test CLI added to help output
- [ ] Golden file creation/testing workflow documented

---

## Anti-Patterns to Avoid

- ❌ Don't delete tprintf() results - causes double-free
- ❌ Don't include ANSI codes in screen_to_string() output - breaks golden file diffs
- ❌ Don't forget to call screen_destroy() - causes memory leaks
- ❌ Don't forget to call component_args_destroy() - causes memory leaks
- ❌ Don't create golden files without --snapshot flag - will fail in CI
- ❌ Don't test components without creating golden files first
- ❌ Don't hardcode dimensions - make them configurable via CLI args
- ❌ Don't break existing TUI functionality - verify with `task test`
- ❌ Don't forget newlines between lines in screen_to_string()
- ❌ Don't add newline after last line in screen_to_string() - matches terminal

---

**PRP Confidence Score**: 9/10

**Rationale**: This PRP provides:
- ✅ Complete component catalog with all states
- ✅ Exact file paths and line numbers for patterns
- ✅ Detailed gotcha warnings from existing codebase
- ✅ Clear validation steps at each level
- ✅ Golden file testing methodology
- ⚠️ Minor uncertainty: Emoji alignment edge cases may need iteration

**One-Pass Implementation Likelihood**: HIGH - Agent has all necessary context, patterns, and validation steps to implement successfully without additional clarification.
