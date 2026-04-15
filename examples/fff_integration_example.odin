// fff_integration_example.odin - Example of using fff.nvim FFI in wayu
//
// This example demonstrates:
// 1. Creating a file finder for wayu config
// 2. Searching files with fuzzy matching
// 3. Live grep in the indexed files
// 4. Integration with TUI fuzzy finder

package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// Import the fff module (in real wayu, this would be package wayu)
// For this example, we assume the fff.odin code is available

// ============================================================================
// Example 1: Basic File Search
// ============================================================================

example_basic_search :: proc() {
    fmt.println("\n=== Example 1: Basic File Search ===\n")
    
    // Create finder for home directory
    finder, ok := fff_create(os.get_env("HOME"), ai_mode = true)
    if !ok {
        fmt.eprintln("Failed to create file finder")
        return
    }
    defer fff_destroy_finder(&finder)
    
    // Start scan and wait for completion
    fmt.println("Scanning files...")
    fff_start_scan(finder)
    
    // Poll for progress
    for fff_is_scanning(finder) {
        progress, ok := fff_get_progress(finder)
        if ok {
            fmt.printf("\rScanned: %d/%d files", progress.scanned_files, progress.total_files)
        }
        time.sleep(100 * time.Millisecond)
    }
    fmt.println("\nScan complete!")
    
    // Search for files
    query := ".zshrc"
    fmt.printf("\nSearching for '%s'...\n", query)
    
    results, found := fff_fuzzy_search(finder, query, page_size = 10)
    if !found {
        fmt.println("No results found")
        return
    }
    defer fff_free_search_result(results)
    
    // Display results
    fmt.printf("Found %d results (total matched: %d):\n", results.count, results.total_matched)
    for i := 0; i < int(results.count) && i < 5; i += 1 {
        item := results.items[i]
        score := results.scores[i]
        
        fmt.printf("  %d. %s (score: %d)\n", i + 1, item.file_name, score.total)
        fmt.printf("     Path: %s\n", item.relative_path)
        fmt.printf("     Size: %d bytes, Modified: %d\n", item.size, item.modified)
        if item.git_status != "" {
            fmt.printf("     Git: %s\n", item.git_status)
        }
        fmt.println()
    }
}

// ============================================================================
// Example 2: Live Grep
// ============================================================================

example_live_grep :: proc() {
    fmt.println("\n=== Example 2: Live Grep ===\n")
    
    // Create finder for wayu source
    finder, ok := fff_create("./src", ai_mode = true)
    if !ok {
        fmt.eprintln("Failed to create file finder")
        return
    }
    defer fff_destroy_finder(&finder)
    
    // Wait for scan
    completed, _ := fff_wait_scan(finder, 10000)
    if !completed {
        fmt.println("Scan timed out or failed")
        return
    }
    
    // Grep for function definitions
    query := "proc fff_"
    fmt.printf("Grepping for '%s' (fuzzy mode)...\n", query)
    
    matches, found := fff_live_grep(finder, query, mode = .Fuzzy, max_results = 20)
    if !found {
        fmt.println("No matches found")
        return
    }
    defer fff_free_grep_result(matches)
    
    fmt.printf("Found %d matches:\n", matches.count)
    for i := 0; i < int(matches.count) && i < 5; i += 1 {
        match := matches.matches[i]
        fmt.printf("  %s:%d:%d\n", match.file_path, match.line_number, match.column)
        fmt.printf("    %s\n", match.match_text)
        
        if len(match.context_before) > 0 {
            fmt.println("    Context before:")
            for line in match.context_before {
                fmt.printf("      %s\n", line)
            }
        }
        fmt.println()
    }
}

// ============================================================================
// Example 3: TUI Integration Pattern
// ============================================================================

// This example shows how to integrate fff with wayu's TUI fuzzy finder

FffTuiState :: struct {
    finder: FileFinder,
    query: [dynamic]u8,
    results: FffSearchResult,
    selected_index: int,
    has_results: bool,
    is_scanning: bool,
}

// Initialize the fff-powered search view
fff_tui_init :: proc(state: ^FffTuiState, base_path: string) -> bool {
    finder, ok := fff_create(base_path, ai_mode = true)
    if !ok {
        return false
    }
    
    state.finder = finder
    state.query = make([dynamic]u8)
    state.selected_index = 0
    state.has_results = false
    state.is_scanning = true
    
    // Start background scan
    fff_start_scan(finder)
    
    return true
}

// Clean up fff TUI state
fff_tui_cleanup :: proc(state: ^FffTuiState) {
    if state.has_results {
        fff_free_search_result(state.results)
        state.has_results = false
    }
    delete(state.query)
    fff_destroy_finder(&state.finder)
}

// Update search query and refresh results (call this on keystroke)
fff_tui_update_query :: proc(state: ^FffTuiState, new_query: string) {
    // Clear previous results
    if state.has_results {
        fff_free_search_result(state.results)
        state.has_results = false
    }
    
    // Update query buffer
    clear(&state.query)
    for c in new_query {
        append(&state.query, u8(c))
    }
    
    // Perform search if query is not empty
    if len(new_query) > 0 {
        results, found := fff_fuzzy_search(state.finder, new_query, page_size = 20)
        if found {
            state.results = results
            state.has_results = true
            state.selected_index = 0
        }
    }
}

// Get selected item
fff_tui_get_selected :: proc(state: FffTuiState) -> (FffFileItem, bool) {
    if !state.has_results || len(state.results.items) == 0 {
        return FffFileItem{}, false
    }
    
    idx := state.selected_index
    if idx < 0 {
        idx = 0
    }
    if idx >= len(state.results.items) {
        idx = len(state.results.items) - 1
    }
    
    return state.results.items[idx], true
}

// Track selection (call when user confirms selection)
fff_tui_track_selection :: proc(state: FffTuiState) {
    item, ok := fff_tui_get_selected(state)
    if !ok {
        return
    }
    
    query := string(state.query[:])
    fff_track_selection(state.finder, query, item.path)
}

// Example usage of TUI integration
example_tui_integration :: proc() {
    fmt.println("\n=== Example 3: TUI Integration Pattern ===\n")
    
    state: FffTuiState
    if !fff_tui_init(&state, "./src") {
        fmt.eprintln("Failed to initialize")
        return
    }
    defer fff_tui_cleanup(&state)
    
    // Simulate user typing
    queries := []string{"search", "files", "finder", "fff"}
    
    for query in queries {
        fmt.printf("\nQuery: '%s'\n", query)
        
        // Wait for scan on first query
        if state.is_scanning {
            completed, _ := fff_wait_scan(state.finder, 5000)
            state.is_scanning = !completed
        }
        
        // Update search
        fff_tui_update_query(&state, query)
        
        // Show results
        if state.has_results {
            fmt.printf("Found %d results:\n", state.results.count)
            for i := 0; i < int(state.results.count) && i < 3; i += 1 {
                item := state.results.items[i]
                fmt.printf("  - %s (%s)\n", item.file_name, item.relative_path)
            }
        } else {
            fmt.println("No results")
        }
        
        // Simulate delay between keystrokes
        time.sleep(100 * time.Millisecond)
    }
}

// ============================================================================
// Example 4: Command Search for wayu
// ============================================================================

example_command_search :: proc() {
    fmt.println("\n=== Example 4: Command Search ===\n")
    
    // Create finder for commands
    finder, ok := fff_create_for_commands()
    if !ok {
        fmt.eprintln("Failed to create command finder")
        return
    }
    defer fff_destroy_finder(&finder)
    
    // Wait for scan
    fff_wait_scan(finder, 5000)
    
    // Search for wayu-related commands
    queries := []string{"wayu", "git", "zsh", "nvim"}
    
    for query in queries {
        fmt.printf("\nSearching for '%s':\n", query)
        
        results, found := fff_fuzzy_search(finder, query, page_size = 5)
        if !found {
            fmt.println("  No results")
            continue
        }
        
        for i := 0; i < int(results.count) && i < 3; i += 1 {
            item := results.items[i]
            fmt.printf("  - %s\n", item.file_name)
        }
        
        fff_free_search_result(results)
    }
}

// ============================================================================
// Main
// ============================================================================

main :: proc() {
    fmt.println("fff.nvim FFI Integration Examples for wayu")
    fmt.println("==========================================\n")
    
    // Check if fff library is available
    // In real implementation, this would check for libfff_c
    
    // Run examples
    example_basic_search()
    example_live_grep()
    example_tui_integration()
    example_command_search()
    
    fmt.println("\n=== All examples completed ===")
}
