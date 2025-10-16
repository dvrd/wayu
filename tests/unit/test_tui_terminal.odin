package test_wayu

import "core:testing"
import "core:fmt"
import tui "../../src/tui"

@(test)
test_terminal_size_detection :: proc(t: ^testing.T) {
    // Test that get_terminal_size returns positive dimensions
    width, height, ok := tui.get_terminal_size()

    // Should return positive values (even if using fallback)
    testing.expect(t, width > 0, fmt.tprintf("Width should be positive, got %d", width))
    testing.expect(t, height > 0, fmt.tprintf("Height should be positive, got %d", height))

    // Width should be reasonable (at least 1, usually >= 80)
    testing.expect(t, width >= 1, fmt.tprintf("Width should be at least 1, got %d", width))

    // Height should be reasonable (at least 1, usually >= 24)
    testing.expect(t, height >= 1, fmt.tprintf("Height should be at least 1, got %d", height))

    // Log the detected size for debugging
    if ok {
        fmt.printf("Terminal size detected: %dx%d\n", width, height)
    } else {
        fmt.printf("Using fallback size: %dx%d\n", width, height)
    }
}

@(test)
test_alt_screen_buffer :: proc(t: ^testing.T) {
    // Test that alternate screen buffer can be entered/exited without crashing
    // Note: We can't verify the visual effect in unit tests, only that it doesn't crash

    // Enter alternate screen
    tui.enter_alt_screen()

    // Exit alternate screen
    tui.exit_alt_screen()

    // If we got here without crashing, test passes
    testing.expect(t, true, "Alternate screen buffer operations completed without crash")
}

@(test)
test_signal_handler :: proc(t: ^testing.T) {
    // Test that setup_resize_handler doesn't crash
    // We can't easily trigger SIGWINCH in a unit test, but we can verify setup works

    tui.setup_resize_handler()

    // If we got here without crashing, test passes
    testing.expect(t, true, "Signal handler setup completed without crash")

    // Verify the global flag exists and can be accessed
    initial_state := tui.terminal_resized
    fmt.printf("Initial terminal_resized state: %v\n", initial_state)
}

@(test)
test_tui_lifecycle_init :: proc(t: ^testing.T) {
    // Test that TUI lifecycle init doesn't crash
    // Note: This will enter alternate screen, so we need to clean up

    tui.tui_lifecycle_init()
    defer tui.tui_lifecycle_cleanup()

    // If we got here without crashing, test passes
    testing.expect(t, true, "TUI lifecycle init completed without crash")
}

@(test)
test_tui_lifecycle_cleanup :: proc(t: ^testing.T) {
    // Test that TUI lifecycle cleanup doesn't crash

    tui.tui_lifecycle_cleanup()

    // If we got here without crashing, test passes
    testing.expect(t, true, "TUI lifecycle cleanup completed without crash")
}

@(test)
test_terminal_size_consistency :: proc(t: ^testing.T) {
    // Test that calling get_terminal_size multiple times returns consistent results

    width1, height1, ok1 := tui.get_terminal_size()
    width2, height2, ok2 := tui.get_terminal_size()

    testing.expect(t, width1 == width2,
        fmt.tprintf("Width should be consistent: %d vs %d", width1, width2))
    testing.expect(t, height1 == height2,
        fmt.tprintf("Height should be consistent: %d vs %d", height1, height2))
    testing.expect(t, ok1 == ok2,
        fmt.tprintf("OK status should be consistent: %v vs %v", ok1, ok2))
}

@(test)
test_fallback_dimensions :: proc(t: ^testing.T) {
    // Test that fallback dimensions are reasonable
    // Even if ioctl fails, we should get 80x24

    width, height, _ := tui.get_terminal_size()

    // Should be either detected size or fallback (80x24)
    // We can't force ioctl to fail in test, but we can verify the values are reasonable
    testing.expect(t, width >= 80 || width == 80,
        fmt.tprintf("Width should be >= 80 or exactly 80 (fallback), got %d", width))
    testing.expect(t, height >= 24 || height == 24,
        fmt.tprintf("Height should be >= 24 or exactly 24 (fallback), got %d", height))
}
