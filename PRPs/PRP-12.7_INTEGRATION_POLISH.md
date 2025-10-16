name: "PRP-12.7: Integration & Polish - Testing, Optimization, Documentation"
description: |
  Final integration testing, performance optimization, error handling improvements,
  documentation updates, and production readiness validation.

version: "1.0.0"
parent: "PRP-12_FULL_TUI_MODE_BASE.md"
phase: "7 of 7"
status: "READY_FOR_EXECUTION"

---

## Goal

**Feature Goal**: Ensure TUI mode is production-ready with comprehensive testing, optimization, complete documentation, and zero CLI regressions.

**Deliverable**:
- Complete end-to-end testing of all TUI workflows
- Performance optimization (target < 50ms per frame)
- Updated documentation (README.md, CLAUDE.md)
- Integration tests for TUI mode
- Final validation checklist completed (50+ items)

**Success Definition**:
- All 255+ existing tests pass (zero CLI regression)
- TUI mode works flawlessly in all scenarios
- Performance meets targets (< 50ms per frame, < 100ms startup)
- Documentation is comprehensive and accurate
- All edge cases handled gracefully
- Production-ready quality

---

## Why

- **Quality Assurance**: Catch bugs before users encounter them
- **Performance**: Smooth UX requires < 50ms frame times
- **Documentation**: Users and contributors need clear guidance
- **Confidence**: Comprehensive testing proves stability
- **Maintenance**: Good documentation reduces future support burden

---

## What

### Implementation Tasks

```yaml
Task 1: END-TO-END TESTING
  Manual Testing Scenarios:
    - Fresh install workflow (init → configure → verify)
    - PATH management (add → list → remove → verify)
    - Alias management (add → edit → remove → verify)
    - Constants management (add → edit → remove → verify)
    - Backup workflow (create → list → restore → verify)
    - Terminal resize handling
    - Ctrl+C cleanup
    - Long lists (100+ items) with scrolling
    - Error scenarios (invalid input, permission errors)

  Test on Multiple Platforms:
    - macOS (primary platform)
    - Linux (if available, or via CI)

  Test Edge Cases:
    - Empty config files
    - Very long PATH entries (> 200 chars)
    - Special characters in aliases/constants
    - Rapid key presses (stress test input handling)
    - Small terminal size (80x24)
    - Large terminal size (200x60)

Task 2: PERFORMANCE OPTIMIZATION
  Profiling:
    - Measure frame render time with instrumentation
    - Identify bottlenecks (likely: string allocations, screen_flush)

  Optimizations:
    - Cache formatted strings where possible
    - Minimize allocations in hot paths
    - Batch ANSI codes in screen_flush()
    - Use string builders for concatenation

  Targets:
    - Frame render time: < 50ms (perceived as instant)
    - TUI startup time: < 100ms
    - Memory usage: < 10MB for typical usage

Task 3: ERROR HANDLING IMPROVEMENTS
  Graceful Degradation:
    - Handle missing config files (show empty list)
    - Handle permission errors (show error message)
    - Handle invalid terminal size (fallback to 80x24)
    - Handle rapid Ctrl+C (force cleanup)

  Error Messages:
    - Clear, actionable messages in status bar
    - Red color for errors
    - Suggestions for recovery

Task 4: DOCUMENTATION UPDATES
  README.md:
    - Add TUI mode section with screenshots (ASCII art)
    - Document --tui flag
    - Explain TUI keyboard shortcuts
    - Add troubleshooting section

  CLAUDE.md:
    - Document TUI architecture
    - Explain component organization
    - Add TUI testing instructions
    - Update file organization section

  Code Comments:
    - Add docstrings to all public procs
    - Explain complex algorithms (differential rendering)
    - Document known limitations

Task 5: INTEGRATION TESTS
  Create tests/integration/test_tui.rb:
    - Test TUI can launch without crash
    - Test --tui flag is recognized
    - Test TUI exits cleanly with timeout
    - Test CLI still works (no regression)

  Automated Testing:
    - Add to task test:all
    - Run in CI (if configured)

Task 6: FINAL VALIDATION
  Run Complete Checklist (50+ items):
    - All compilation checks pass
    - All unit tests pass (255+ tests)
    - All integration tests pass
    - Manual testing scenarios complete
    - Performance targets met
    - Documentation complete
    - Zero CLI regressions
```

### Success Criteria

- [ ] All 255+ existing tests pass
- [ ] TUI launches without errors
- [ ] All 8 views render correctly
- [ ] All CRUD operations work
- [ ] Backups created automatically
- [ ] Terminal resize handled gracefully
- [ ] Ctrl+C exits cleanly
- [ ] Performance targets met (< 50ms per frame)
- [ ] Documentation updated
- [ ] README.md has TUI section
- [ ] CLAUDE.md has TUI architecture
- [ ] Integration tests pass
- [ ] No memory leaks
- [ ] Edge cases handled
- [ ] Error messages clear and helpful
- [ ] Code well-commented

---

## All Needed Context

### Documentation References

```yaml
- file: /Users/kakurega/dev/projects/wayu/README.md
  why: User-facing documentation to update
  pattern: Add TUI section with keyboard shortcuts

- file: /Users/kakurega/dev/projects/wayu/CLAUDE.md
  why: Developer documentation to update
  pattern: Add TUI architecture and testing sections

- file: /Users/kakurega/dev/projects/wayu/tests/integration/
  why: Integration test patterns
  pattern: Use same structure as test_path.rb, test_alias.rb

- url: https://ratatui.rs/concepts/rendering/under-the-hood/
  why: Performance benchmarks
  reference: 120μs → 55μs (55% speedup with differential rendering)
```

### Known Gotchas

```odin
// GOTCHA: Always run existing tests to catch regression
task test:all
# Expected: All 255+ tests pass

// GOTCHA: Profile before optimizing
@(instrumentation_enter)
render_frame :: proc() {
    start := time.now()
    defer {
        elapsed := time.since(start)
        if elapsed > 50 * time.Millisecond {
            fmt.printf("SLOW FRAME: %v\n", elapsed)
        }
    }

    // ... rendering logic
}

// GOTCHA: Test terminal cleanup even on panic
test_cleanup_on_panic :: proc() {
    // Capture terminal state before
    before := get_terminal_state()

    // Launch TUI and panic
    defer {
        // Verify terminal restored after panic
        after := get_terminal_state()
        assert(before == after)
    }

    // ... trigger panic scenario
}
```

---

## Implementation Blueprint

### Performance Profiling Pattern

```odin
package wayu_tui

import "core:time"
import "core:fmt"

// Profile frame rendering
@(instrumentation_enter)
profile_frame :: proc() {
    start := time.now()
    defer {
        elapsed := time.since(start)
        duration_ms := time.duration_milliseconds(elapsed)

        if duration_ms > 50 {
            fmt.printf("SLOW FRAME: %.2fms\n", duration_ms)
        }
    }
}

// Measure specific operations
profile_operation :: proc(name: string, operation: proc()) {
    start := time.now()
    operation()
    elapsed := time.since(start)
    fmt.printf("%s: %.2fms\n", name, time.duration_milliseconds(elapsed))
}

// Usage in tui_main.odin
tui_run :: proc() {
    // ... setup ...

    for state.running {
        profile_frame()

        if state.needs_refresh {
            profile_operation("render", proc() {
                tui_render(&state, &screen)
            })

            profile_operation("flush", proc() {
                screen_flush(&screen)
            })

            state.needs_refresh = false
        }

        // ... event handling ...
    }
}
```

### Integration Test Pattern

```bash
#!/usr/bin/env ruby
# tests/integration/test_tui.rb

require 'minitest/autorun'
require 'open3'
require 'timeout'

class TestTUI < Minitest::Test
  WAYU_BIN = './bin/wayu'
  TIMEOUT = 2  # seconds

  def test_tui_launches_without_crash
    # Launch TUI and send quit command
    stdout, stderr, status = Open3.capture3(
      WAYU_BIN, '--tui',
      stdin_data: "q\n",
      timeout: TIMEOUT
    )

    assert status.success?, "TUI should exit cleanly"
    assert_empty stderr, "No errors should be printed"
  end

  def test_tui_flag_recognized
    stdout, stderr, status = Open3.capture3(
      WAYU_BIN, '--help'
    )

    assert_match /--tui/, stdout, "Help should mention --tui flag"
  end

  def test_cli_still_works_without_tui_flag
    stdout, stderr, status = Open3.capture3(
      WAYU_BIN, 'path', 'list'
    )

    assert status.success?, "CLI should work without --tui"
  end

  def test_tui_exits_cleanly_on_ctrl_c
    # Launch TUI in background
    pid = spawn(WAYU_BIN, '--tui')

    sleep 0.5  # Let it start

    # Send SIGINT (Ctrl+C)
    Process.kill('INT', pid)

    # Wait for clean exit
    Timeout.timeout(TIMEOUT) do
      Process.wait(pid)
    end

    assert $?.success?, "TUI should exit cleanly on Ctrl+C"
  end
end
```

### Documentation Update Pattern

```markdown
# README.md additions

## TUI Mode (Interactive Terminal UI)

wayu now includes a full-featured Terminal User Interface (TUI) for interactive configuration management.

### Launching TUI Mode

```bash
wayu --tui
```

### TUI Features

- **Interactive Navigation**: Browse all configuration options visually
- **Keyboard Shortcuts**: Vim-style navigation (j/k or ↑/↓)
- **Live Preview**: See changes immediately
- **Safe Operations**: Automatic backups before modifications
- **Discoverable**: Help text displayed in each view

### Keyboard Shortcuts

**Global:**
- `Esc` - Go back / Exit from main menu
- `Ctrl+C` - Quit immediately
- `↑/↓` or `j/k` - Navigate list
- `Enter` - Select item

**View-Specific:**
- `a` - Add new item
- `d` or `x` - Delete selected item
- `e` - Edit selected item
- `r` - Restore backup (in Backups view)
- `c` - Cleanup old backups (in Backups view)

### TUI Architecture

```
┌─────────────────────────────────────────┐
│         Main Menu (8 options)           │
├─────────────────────────────────────────┤
│ 1. PATH Configuration                   │
│ 2. Aliases                              │
│ 3. Environment Constants                │
│ 4. Completions                          │
│ 5. Backups                              │
│ 6. Plugins                              │
│ 7. Settings                             │
│ 8. Exit                                 │
└─────────────────────────────────────────┘
```

### Troubleshooting

**TUI doesn't start:**
- Ensure terminal supports ANSI escape codes
- Try resizing terminal to at least 80x24
- Check terminal emulator compatibility

**Terminal left in raw mode:**
- Run `stty sane` to reset terminal
- This should never happen - please report as bug

**Performance issues:**
- Check terminal size (very large terminals may be slow)
- Reduce number of config entries if possible
```

---

## Validation Loop

### Level 1: Regression Testing

```bash
# Run ALL existing tests to ensure zero regression
task test:all
# Expected: All 255+ tests pass

# Specific test suites
task test           # Unit tests
task test:integration  # Integration tests
task test:path      # PATH command tests
task test:alias     # Alias command tests
task test:constants # Constants command tests
task test:backup    # Backup system tests
```

### Level 2: Performance Testing

```bash
# Build with profiling enabled
task build-debug

# Run TUI and measure frame times
./bin/wayu_debug --tui
# Expected: No "SLOW FRAME" warnings
# All frames < 50ms

# Measure startup time
time ./bin/wayu --tui <<EOF
q
EOF
# Expected: < 100ms total
```

### Level 3: Manual Testing

```bash
# Complete manual testing checklist
./bin/wayu --tui

# Test each view:
# 1. Main Menu: Navigate through all 7 options
# 2. PATH: Add entry, verify, delete, verify
# 3. Alias: Add alias, edit, delete
# 4. Constants: Add constant, edit, delete
# 5. Completions: List completions
# 6. Backups: List, restore, cleanup
# 7. Settings: View configuration

# Test edge cases:
# - Resize terminal while in TUI
# - Press Ctrl+C from different views
# - Scroll through long list (50+ items)
# - Rapid key presses
# - Invalid inputs in forms

# Expected: All operations work smoothly, no crashes
```

### Level 4: Integration Testing

```bash
# Run new TUI integration tests
ruby tests/integration/test_tui.rb
# Expected: All tests pass

# Add to main test suite
task test:all
# Expected: TUI tests included and passing
```

### Level 5: Documentation Review

```bash
# Check documentation completeness
grep -r "TUI" README.md
grep -r "tui_" CLAUDE.md

# Verify code comments
grep -r "@(doc)" src/tui/*.odin

# Expected: All components documented
```

---

## Final Validation Checklist

### Functionality (20 items)
- [ ] TUI launches with --tui flag
- [ ] Main menu displays 7 options
- [ ] Navigation works (↑/↓, j/k)
- [ ] PATH view: add, list, delete
- [ ] Alias view: add, list, delete, edit
- [ ] Constants view: add, list, delete, edit
- [ ] Completions view: list, add, delete
- [ ] Backups view: list, restore, cleanup
- [ ] Settings view: displays config
- [ ] Esc returns to previous view
- [ ] Esc from main menu exits
- [ ] Ctrl+C exits cleanly
- [ ] Terminal resize handled
- [ ] Scrolling works for long lists
- [ ] Selection highlighting visible
- [ ] Keyboard shortcuts work
- [ ] Forms accept input
- [ ] Error messages display
- [ ] Success messages display
- [ ] Backups created automatically

### Quality (15 items)
- [ ] Zero compiler warnings
- [ ] All 255+ existing tests pass
- [ ] TUI integration tests pass
- [ ] No memory leaks (verified with tools)
- [ ] Frame render time < 50ms
- [ ] Startup time < 100ms
- [ ] Works on macOS
- [ ] Terminal restored after exit
- [ ] Terminal restored after crash
- [ ] No flickering during render
- [ ] Smooth scrolling
- [ ] Responsive input
- [ ] Clean code (no commented-out blocks)
- [ ] Consistent naming conventions
- [ ] Proper error handling

### Documentation (10 items)
- [ ] README.md has TUI section
- [ ] CLAUDE.md has TUI architecture
- [ ] Keyboard shortcuts documented
- [ ] Troubleshooting section added
- [ ] Code has docstrings
- [ ] Complex algorithms explained
- [ ] Known limitations documented
- [ ] Testing instructions updated
- [ ] Examples provided
- [ ] ASCII art diagrams included

### Edge Cases (10 items)
- [ ] Empty config files handled
- [ ] Long PATH entries displayed correctly
- [ ] Special characters in aliases work
- [ ] Small terminal (80x24) works
- [ ] Large terminal (200x60) works
- [ ] Rapid key presses handled
- [ ] Invalid form inputs rejected
- [ ] Permission errors shown clearly
- [ ] Missing files handled gracefully
- [ ] Concurrent modifications detected

---

## Final Production Checklist

- [ ] All validation checklist items completed (55/55)
- [ ] Performance targets met
- [ ] Documentation complete
- [ ] Zero regressions in CLI mode
- [ ] Clean git history with descriptive commits
- [ ] CHANGELOG.md updated with TUI feature
- [ ] Version bumped appropriately (v3.0.0)
- [ ] Release notes prepared

---

**Status**: ✅ READY FOR EXECUTION
**Estimated Time**: 4-6 hours
**Dependencies**: Phases 1-6 MUST be complete
**Confidence**: 9/10

**Critical**: This phase validates production readiness. Do not skip manual testing.
