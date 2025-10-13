# UI Alignment Tests

This directory contains automated tests for UI component alignment. These tests verify that terminal UI elements render correctly with proper visual width calculations.

## Running Tests

```bash
# Run via task (recommended)
task test:ui

# Or run directly
odin run tests/ui/test_render_box.odin -file
```

## Test Files

### test_render_box.odin

Automated alignment verification for preview boxes used in interactive forms. Tests include:

1. **Constants preview with warning symbol (⚠)** - Wide character at width 2
2. **Alias preview (no special chars)** - Baseline ASCII-only content
3. **Path preview with sparkles emoji (✨)** - Wide emoji character
4. **Long title** - Title truncation and padding
5. **Multiple wide characters** - Mixed wide characters in content

Each test verifies:
- Top border matches bottom border width
- All content lines match border width
- ANSI color codes are stripped for width calculation
- Wide characters (width 2) are counted correctly
- Regular characters (width 1) are counted correctly

Exit code: 0 if all tests pass, 1 if any test fails.

## Purpose

These automated tests ensure:
- Terminal rendering and alignment accuracy
- Correct handling of ANSI escape sequences
- Accurate visual width calculation for all character types
- No regressions in UI rendering

The tests use the same `get_string_visual_width()` function from `src/special_chars.odin` that's used in production, ensuring consistency between test and actual rendering.
