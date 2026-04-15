// fff_integration.odin - Complete fff.nvim integration for wayu
//
// This module provides fuzzy matching capabilities for wayu commands,
// particularly for GET operations that can now use fuzzy fallback.
//
// Features:
// - Global fff finder for wayu configuration
// - Fuzzy matching for constants, aliases, and path entries
// - Integration with both CLI and TUI modes
// - Automatic fallback when exact match not found

package wayu

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"
import "core:slice"
import "core:unicode"

// ============================================================================
// Configuration
// ============================================================================

FFF_INTEGRATION_ENABLED := true  // Can be disabled via env var
FFF_AUTO_FALLBACK := true       // Auto use fuzzy when exact match fails
FFF_INTERACTIVE_SELECT := true  // Show interactive selector for multiple matches

// Check if fff integration is enabled
fff_is_enabled :: proc() -> bool {
    if !FFF_INTEGRATION_ENABLED {
        return false
    }
    // Check env override
    env_val := os.get_env_alloc("WAYU_FFF_ENABLED", context.allocator)
    defer delete(env_val)
    if env_val == "0" || env_val == "false" {
        return false
    }
    return true
}

// ============================================================================
// Scoring and Matching (Pure Odin, no FFI required for basic fuzzy)
// ============================================================================

// Simple fuzzy score calculation (0 = no match, higher = better)
fuzzy_score :: proc(text: string, query: string) -> int {
    if len(query) == 0 {
        return 1
    }
    if len(text) == 0 {
        return 0
    }
    
    text_lower := strings.to_lower(text)
    defer delete(text_lower)
    query_lower := strings.to_lower(query)
    defer delete(query_lower)
    
    score := 0
    text_idx := 0
    consecutive_bonus := 0
    
    for query_char in query_lower {
        found := false
        for text_idx < len(text_lower) {
            if rune(text_lower[text_idx]) == query_char {
                score += 10 + consecutive_bonus
                consecutive_bonus += 5  // Bonus for consecutive matches
                text_idx += 1
                found = true
                break
            }
            text_idx += 1
            consecutive_bonus = 0  // Reset consecutive bonus
        }
        if !found {
            return 0
        }
    }
    
    // Bonus for exact substring match
    if strings.contains(text_lower, query_lower) {
        score += len(query) * 20
    }
    
    // Bonus for exact match at start
    if strings.has_prefix(text_lower, query_lower) {
        score += len(query) * 30
    }
    
    // Bonus for acronym match (e.g., "frwrks" matches "FIREWORKS")
    if is_acronym_match(text, query) {
        score += len(query) * 25
    }
    
    // Penalty for length difference
    length_diff := len(text) - len(query)
    if length_diff > 0 {
        score -= length_diff * 2
    }
    
    return score
}

// Check if query matches acronym of text
// e.g., text="FIREWORKS_AI_API_KEY", query="frwrks" → true
is_acronym_match :: proc(text: string, query: string) -> bool {
    // Build acronym from text (uppercase letters and underscores)
    acronym := make([dynamic]u8)
    defer delete(acronym)
    
    prev_was_sep := true  // Start true to capture first letter
    
    for c in text {
        is_sep := c == '_' || c == '-' || c == ' ' || c == '.' || (c >= '0' && c <= '9')
        
        if is_sep {
            prev_was_sep = true
        } else if prev_was_sep && unicode.is_upper(c) {
            append(&acronym, u8(unicode.to_lower(c)))
            prev_was_sep = false
        } else if prev_was_sep {
            append(&acronym, u8(unicode.to_lower(c)))
            prev_was_sep = false
        }
    }
    
    if len(acronym) == 0 {
        return false
    }
    
    acronym_str := string(acronym[:])
    query_lower := strings.to_lower(query)
    defer delete(query_lower)
    
    return strings.contains(acronym_str, query_lower)
}

// ============================================================================
// Fuzzy Match Result
// ============================================================================

FuzzyMatch :: struct {
    entry: ConfigEntry,
    score: int,
    match_type: MatchType,
}

MatchType :: enum {
    Exact,           // Match exacto
    Prefix,          // Prefijo exacto
    Substring,       // Substring
    Fuzzy,           // Fuzzy match general
    Acronym,         // Match por acrónimo
}

// ============================================================================
// Fuzzy Search Functions
// ============================================================================

// Find fuzzy matches across all entries of a spec
fuzzy_find_entries :: proc(spec: ^ConfigEntrySpec, query: string, max_results := 10) -> []FuzzyMatch {
    if len(query) == 0 {
        return nil
    }
    
    entries := read_config_entries(spec)
    defer cleanup_entries(&entries)
    
    matches := make([dynamic]FuzzyMatch)
    defer if len(matches) == 0 {
        delete(matches)
    }
    
    query_lower := strings.to_lower(query)
    defer delete(query_lower)
    
    for entry in entries {
        score := 0
        match_type := MatchType.Fuzzy
        
        // Check for exact match
        if strings.equal_fold(entry.name, query) {
            score = 10000
            match_type = .Exact
        } else if strings.has_prefix(strings.to_lower(entry.name), query_lower) {
            // Prefix match
            score = 5000 + fuzzy_score(entry.name, query)
            match_type = .Prefix
        } else if strings.contains(strings.to_lower(entry.name), query_lower) {
            // Substring match
            score = 3000 + fuzzy_score(entry.name, query)
            match_type = .Substring
        } else if is_acronym_match(entry.name, query) {
            // Acronym match (e.g., frwrks → FIREWORKS)
            score = 2000 + fuzzy_score(entry.name, query)
            match_type = .Acronym
        } else {
            // General fuzzy match
            score = fuzzy_score(entry.name, query)
            match_type = .Fuzzy
        }
        
        if score > 0 {
            append(&matches, FuzzyMatch{
                entry = clone_entry(entry),
                score = score,
                match_type = match_type,
            })
        }
    }
    
    if len(matches) == 0 {
        return nil
    }
    
    // Sort by score descending
    slice.sort_by(matches[:], proc(a, b: FuzzyMatch) -> bool {
        return a.score > b.score
    })
    
    // Return top results
    result_count := min(max_results, len(matches))
    result := make([]FuzzyMatch, result_count)
    for i in 0..<result_count {
        result[i] = matches[i]
    }
    
    // Clean up remaining matches
    for i in result_count..<len(matches) {
        cleanup_clone(matches[i].entry)
    }
    delete(matches)
    
    return result
}

// Clone a config entry
clone_entry :: proc(entry: ConfigEntry) -> ConfigEntry {
    return ConfigEntry{
        type = entry.type,
        name = strings.clone(entry.name),
        value = strings.clone(entry.value),
        line = strings.clone(entry.line),
    }
}

// Helper to clean up cloned entries - takes entry by value and cleans it up
cleanup_clone :: proc(entry: ConfigEntry) {
    if entry.name != "" {
        delete(entry.name)
    }
    if entry.value != "" {
        delete(entry.value)
    }
    if entry.line != "" {
        delete(entry.line)
    }
}

// Free fuzzy matches
free_fuzzy_matches :: proc(matches: []FuzzyMatch) {
    for match in matches {
        cleanup_clone(match.entry)
    }
    delete(matches)
}

// ============================================================================
// Enhanced GET with Fuzzy Fallback
// ============================================================================

// Get entry with fuzzy fallback - main function for CLI GET
get_config_entry_fuzzy :: proc(spec: ^ConfigEntrySpec, query: string) -> (ConfigEntry, bool) {
    // First try exact match
    entries := read_config_entries(spec)
    defer cleanup_entries(&entries)
    
    for entry in entries {
        if entry.name == query {
            // Exact match found - return it
            return clone_entry(entry), true
        }
    }
    
    // No exact match - try fuzzy if enabled
    if !fff_is_enabled() || !FFF_AUTO_FALLBACK {
        return ConfigEntry{}, false
    }
    
    // Do fuzzy search
    matches := fuzzy_find_entries(spec, query, max_results = 10)
    if matches == nil || len(matches) == 0 {
        return ConfigEntry{}, false
    }
    defer free_fuzzy_matches(matches)
    
    // If we have a very strong match (exact, prefix, or acronym with high score), use it
    best_match := matches[0]
    if best_match.match_type == .Exact || 
       best_match.match_type == .Prefix ||
       (best_match.match_type == .Acronym && best_match.score > 1000) {
        return clone_entry(best_match.entry), true
    }
    
    // Multiple matches - if interactive, let user choose
    if FFF_INTERACTIVE_SELECT && is_stdin_tty() && len(matches) > 1 {
        selected := interactive_select_match(spec, matches, query)
        if selected.name != "" {
            return selected, true
        }
    }
    
    // Return best match if score is good enough
    if best_match.score >= 50 {
        return clone_entry(best_match.entry), true
    }
    
    return ConfigEntry{}, false
}

// Print fuzzy match suggestions for CLI
print_fuzzy_suggestions :: proc(spec: ^ConfigEntrySpec, query: string, matches: []FuzzyMatch) {
    fmt.printf("\n%s%s '%s' not found. Did you mean:%s\n", 
        YELLOW, spec.display_name, query, RESET)
    fmt.println()
    
    for match, i in matches {
        type_str := ""
        switch match.match_type {
        case .Exact: type_str = "exact"
        case .Prefix: type_str = "prefix"
        case .Substring: type_str = "substring"
        case .Fuzzy: type_str = "fuzzy"
        case .Acronym: type_str = "acronym"
        }
        
        score_indicator := ""
        if match.score > 1000 {
            score_indicator = fmt.tprintf(" %s★%s", GREEN, RESET)
        } else if match.score > 500 {
            score_indicator = fmt.tprintf(" %s◆%s", YELLOW, RESET)
        }
        
        fmt.printf("  %s%d.%s %s%s%s (%s)%s\n", 
            get_secondary(), i + 1, RESET,
            get_primary(), match.entry.name, RESET,
            type_str, score_indicator)
        
        if spec.fields_count > 1 && match.entry.value != "" {
            truncated := match.entry.value
            if len(truncated) > 50 {
                truncated = fmt.tprintf("%s...", truncated[:47])
            }
            fmt.printf("      %s%s%s\n", get_muted(), truncated, RESET)
        }
    }
    
    fmt.println()
    fmt.printf("%sUse: wayu %s get <name>%s\n", get_muted(), spec.file_name, RESET)
}

// Interactive selector for fuzzy matches using wayu's existing fuzzy finder
interactive_select_match :: proc(spec: ^ConfigEntrySpec, matches: []FuzzyMatch, query: string) -> ConfigEntry {
    // Convert items to simple strings for interactive_fuzzy_select
    item_strings := make([]string, len(matches))
    defer {
        for s in item_strings {
            delete(s)
        }
        delete(item_strings)
    }
    
    // Build display strings with match type indicators
    for match, i in matches {
        type_indicator := ""
        switch match.match_type {
        case .Exact: type_indicator = " [=]"
        case .Prefix: type_indicator = " [^]"
        case .Substring: type_indicator = " [~]"
        case .Acronym: type_indicator = " [@]"
        case .Fuzzy: type_indicator = " [*]"
        }
        
        item_strings[i] = fmt.tprintf("%s%s", match.entry.name, type_indicator)
    }
    
    // Use wayu's built-in fuzzy picker
    selected_display, ok := interactive_fuzzy_select(item_strings, 
        fmt.tprintf("Select %s matching '%s'", spec.display_name, query))
    
    if !ok || selected_display == "" {
        return ConfigEntry{}
    }
    
    // Extract just the name (remove type indicator)
    selected_name := selected_display
    if idx := strings.index(selected_display, " ["); idx != -1 {
        selected_name = selected_display[:idx]
    }
    defer if selected_name != selected_display {
        delete(selected_name)
    }
    
    // Find the matching entry
    for match in matches {
        if match.entry.name == selected_name {
            return clone_entry(match.entry)
        }
    }
    
    return ConfigEntry{}
}

// ============================================================================
// Search Across All Config Types
// ============================================================================

// Search across all config types (constants, aliases, path)
search_all_configs :: proc(query: string, max_results := 15) -> []ConfigSearchResult {
    results := make([dynamic]ConfigSearchResult)
    
    // Search constants
    const_matches := fuzzy_find_entries(&CONSTANTS_SPEC, query, max_results = 5)
    defer free_fuzzy_matches(const_matches)
    
    for match in const_matches {
        append(&results, ConfigSearchResult{
            entry = clone_entry(match.entry),
            spec_type = .CONSTANT,
            score = match.score,
            match_type = match.match_type,
        })
    }
    
    // Search aliases
    alias_matches := fuzzy_find_entries(&ALIAS_SPEC, query, max_results = 5)
    defer free_fuzzy_matches(alias_matches)
    
    for match in alias_matches {
        append(&results, ConfigSearchResult{
            entry = clone_entry(match.entry),
            spec_type = .ALIAS,
            score = match.score,
            match_type = match.match_type,
        })
    }
    
    // Search paths
    path_matches := fuzzy_find_entries(&PATH_SPEC, query, max_results = 5)
    defer free_fuzzy_matches(path_matches)
    
    for match in path_matches {
        append(&results, ConfigSearchResult{
            entry = clone_entry(match.entry),
            spec_type = .PATH,
            score = match.score,
            match_type = match.match_type,
        })
    }
    
    // Sort all results by score
    slice.sort_by(results[:], proc(a, b: ConfigSearchResult) -> bool {
        return a.score > b.score
    })
    
    // Return top results
    final_count := min(max_results, len(results))
    final := make([]ConfigSearchResult, final_count)
    for i in 0..<final_count {
        final[i] = results[i]
    }
    
    // Cleanup remaining
    for i in final_count..<len(results) {
        cleanup_clone(results[i].entry)
    }
    delete(results)
    
    return final
}

ConfigSearchResult :: struct {
    entry: ConfigEntry,
    spec_type: ConfigEntryType,
    score: int,
    match_type: MatchType,
}

// Free search results
free_config_search_results :: proc(results: []ConfigSearchResult) {
    for r in results {
        cleanup_clone(r.entry)
    }
    delete(results)
}

// ============================================================================
// Command Search (for wayu commands themselves)
// ============================================================================

// Get list of all available wayu commands for fuzzy search
get_wayu_commands :: proc() -> []string {
    commands := make([dynamic]string)
    defer delete(commands)
    
    append(&commands, "path add")
    append(&commands, "path rm")
    append(&commands, "path list")
    append(&commands, "path clean")
    append(&commands, "path dedup")
    
    append(&commands, "alias add")
    append(&commands, "alias rm")
    append(&commands, "alias list")
    
    append(&commands, "const add")
    append(&commands, "const rm")
    append(&commands, "const list")
    append(&commands, "const get")
    
    append(&commands, "backup list")
    append(&commands, "backup restore")
    append(&commands, "backup clean")
    
    append(&commands, "plugin add")
    append(&commands, "plugin rm")
    append(&commands, "plugin list")
    
    append(&commands, "init")
    append(&commands, "migrate")
    append(&commands, "completions")
    
    // Return as slice
    result := make([]string, len(commands))
    for cmd, i in commands {
        result[i] = strings.clone(cmd)
    }
    return result
}

// Free commands list
free_wayu_commands :: proc(commands: []string) {
    for cmd in commands {
        delete(cmd)
    }
    delete(commands)
}

// Fuzzy find wayu command
fuzzy_find_command :: proc(query: string) -> (string, bool) {
    commands := get_wayu_commands()
    defer free_wayu_commands(commands)
    
    best_cmd := ""
    best_score := 0
    
    for cmd in commands {
        score := fuzzy_score(cmd, query)
        if score > best_score {
            best_score = score
            best_cmd = cmd
        }
    }
    
    if best_score >= 30 {
        return best_cmd, true
    }
    
    return "", false
}

// ============================================================================
// Initialization
// ============================================================================

// Initialize fff integration
// Called automatically on first use, but can be called manually
fff_integration_init :: proc() -> bool {
    if !fff_is_enabled() {
        return false
    }
    
    // Check for environment overrides
    auto_fb := os.get_env_alloc("WAYU_FFF_AUTO_FALLBACK", context.allocator)
    defer delete(auto_fb)
    if auto_fb == "0" || auto_fb == "false" {
        FFF_AUTO_FALLBACK = false
    }
    
    interactive := os.get_env_alloc("WAYU_FFF_INTERACTIVE", context.allocator)
    defer delete(interactive)
    if interactive == "0" || interactive == "false" {
        FFF_INTERACTIVE_SELECT = false
    }
    
    return true
}

// Check if stdin is a TTY (for interactive selection)
is_stdin_tty :: proc() -> bool {
    // Check if we're running in a terminal
    return os.is_tty(os.stdin)
}


