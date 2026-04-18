// search.odin - Global fuzzy search across all configurations
//
// This module provides the search, find, and f commands that allow users
// to search across PATH entries, aliases, and constants simultaneously
// using fuzzy matching.

package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:slice"

// MatchedField indicates which field of an entry matched the query
MatchedField :: enum {
	NAME,   // Query matched the entry name
	VALUE,  // Query matched the entry value
}

// SearchResult represents a single match from any config type
SearchResult :: struct {
	spec_type:     ConfigEntryType,
	name:          string,
	value:         string,
	score:         int,
	match_type:    MatchType,
	matched_field: MatchedField,
}

// Internal wrapper for sorting entries with scores
SearchEntry :: struct {
	entry:         ConfigEntry,
	score:         int,
	match_type:    MatchType,
	matched_field: MatchedField,
}

// handle_search_command - Main entry point for search/find/f commands
handle_search_command :: proc(args: []string) {
	if len(args) == 0 {
		print_search_usage()
		os.exit(EXIT_USAGE)
	}

	query := args[0]
	if query == "--help" || query == "-h" || query == "help" {
		print_search_usage()
		os.exit(0)
	}
	if len(strings.trim_space(query)) == 0 {
		print_search_usage()
		os.exit(EXIT_USAGE)
	}

	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}

	// Search across all config types
	all_results := make([dynamic]SearchResult)
	defer {
		for r in all_results {
			delete(r.name)
			if r.value != "" {
				delete(r.value)
			}
		}
		delete(all_results)
	}

	// Search PATH entries from TOML
	path_entries_toml := read_toml_path_entries()
	defer {
		for entry in path_entries_toml {
			delete(entry.name)
			delete(entry.value)
			delete(entry.line)
		}
		delete(path_entries_toml)
	}
	path_search_results := search_toml_entries_by_name(path_entries_toml[:], query)
	defer {
		for se in path_search_results {
			cleanup_clone(se.entry)
		}
		delete(path_search_results)
	}
	for se in path_search_results {
		append(&all_results, SearchResult{
			spec_type      = .PATH,
			name           = strings.clone(se.entry.name),
			value          = "",
			score          = se.score,
			match_type     = se.match_type,
			matched_field  = se.matched_field,
		})
	}

	// Search aliases from TOML
	alias_entries_toml := read_toml_alias_entries()
	defer {
		for entry in alias_entries_toml {
			delete(entry.name)
			delete(entry.value)
			delete(entry.line)
		}
		delete(alias_entries_toml)
	}
	alias_search_results := search_toml_entries_by_name(alias_entries_toml[:], query)
	defer {
		for se in alias_search_results {
			cleanup_clone(se.entry)
		}
		delete(alias_search_results)
	}
	for se in alias_search_results {
		value := strings.clone(se.entry.value) if se.entry.value != "" else ""
		append(&all_results, SearchResult{
			spec_type      = .ALIAS,
			name           = strings.clone(se.entry.name),
			value          = value,
			score          = se.score,
			match_type     = se.match_type,
			matched_field  = se.matched_field,
		})
	}

	// Search constants from TOML
	const_entries_toml := read_wayu_toml_constants()
	defer {
		for entry in const_entries_toml {
			delete(entry.name)
			delete(entry.value)
			delete(entry.line)
		}
		delete(const_entries_toml)
	}
	const_search_results := search_toml_entries_by_name(const_entries_toml[:], query)
	defer {
		for se in const_search_results {
			cleanup_clone(se.entry)
		}
		delete(const_search_results)
	}
	for se in const_search_results {
		value := strings.clone(se.entry.value) if se.entry.value != "" else ""
		append(&all_results, SearchResult{
			spec_type      = .CONSTANT,
			name           = strings.clone(se.entry.name),
			value          = value,
			score          = se.score,
			match_type     = se.match_type,
			matched_field  = se.matched_field,
		})
	}

	// Sort all results by score (highest first)
	slice.sort_by(all_results[:], proc(a, b: SearchResult) -> bool {
		return a.score > b.score
	})

	// Display results grouped by type
	print_search_results(query, all_results[:])
}

// search_toml_entries_by_name - Fuzzy search through TOML config entries
// Matches on both name and value fields. Returns scored entries for sorting and display.
search_toml_entries_by_name :: proc(entries: []ConfigEntry, query: string) -> [dynamic]SearchEntry {
	results := make([dynamic]SearchEntry)

	if len(query) == 0 {
		return results
	}

	query_lower := strings.to_lower(query)
	defer delete(query_lower)

	for entry in entries {
		name_score := 0
		name_match_type := MatchType.Fuzzy
		value_score := 0
		value_match_type := MatchType.Fuzzy
		matched_field := MatchedField.NAME

		// Score name field
		if strings.equal_fold(entry.name, query) {
			name_score = 10000
			name_match_type = .Exact
		} else if strings.has_prefix(strings.to_lower(entry.name), query_lower) {
			// Prefix match
			name_score = 5000 + fuzzy_score(entry.name, query)
			name_match_type = .Prefix
		} else if strings.contains(strings.to_lower(entry.name), query_lower) {
			// Substring match
			name_score = 3000 + fuzzy_score(entry.name, query)
			name_match_type = .Substring
		} else if is_acronym_match(entry.name, query) {
			// Acronym match (e.g., frwrks → FIREWORKS)
			name_score = 2000 + fuzzy_score(entry.name, query)
			name_match_type = .Acronym
		} else {
			// General fuzzy match
			name_score = fuzzy_score(entry.name, query)
			name_match_type = .Fuzzy
		}

		// Score value field (only if value is not empty)
		if entry.value != "" {
			if strings.equal_fold(entry.value, query) {
				value_score = 10000
				value_match_type = .Exact
			} else if strings.has_prefix(strings.to_lower(entry.value), query_lower) {
				// Prefix match
				value_score = 5000 + fuzzy_score(entry.value, query)
				value_match_type = .Prefix
			} else if strings.contains(strings.to_lower(entry.value), query_lower) {
				// Substring match
				value_score = 3000 + fuzzy_score(entry.value, query)
				value_match_type = .Substring
			} else if is_acronym_match(entry.value, query) {
				// Acronym match
				value_score = 2000 + fuzzy_score(entry.value, query)
				value_match_type = .Acronym
			} else {
				// General fuzzy match
				value_score = fuzzy_score(entry.value, query)
				value_match_type = .Fuzzy
			}
		}

		// Pick the higher score, prefer name on ties
		score := 0
		match_type := MatchType.Fuzzy
		if name_score >= value_score {
			score = name_score
			match_type = name_match_type
			matched_field = .NAME
		} else {
			score = value_score
			match_type = value_match_type
			matched_field = .VALUE
		}

		if score > 0 {
			append(&results, SearchEntry{
				entry          = clone_entry(entry),
				score          = score,
				match_type     = match_type,
				matched_field  = matched_field,
			})
		}
	}

	if len(results) == 0 {
		return results
	}

	// Sort by score descending
	slice.sort_by(results[:], proc(a, b: SearchEntry) -> bool {
		return a.score > b.score
	})

	// Limit to top 20 results if needed
	if len(results) > 20 {
		// Clean up unused results
		for i in 20..<len(results) {
			cleanup_clone(results[i].entry)
		}
		// Create new dynamic with only first 20
		limited := make([dynamic]SearchEntry)
		for i in 0..<20 {
			append(&limited, results[i])
		}
		delete(results)
		return limited
	}

	return results
}

// search_config_entries - Search entries in a specific config spec (legacy, unused)
search_config_entries :: proc(spec: ^ConfigEntrySpec, query: string) -> []FuzzyMatch {
	return fuzzy_find_entries(spec, query, max_results = 20)
}

// print_search_results - Display formatted search results
print_search_results :: proc(query: string, results: []SearchResult) {
	if len(results) == 0 {
		fmt.printfln("%sNo matches found for '%s'%s", get_warning(), query, RESET)
		return
	}

	print_header(fmt.tprintf("Search Results for '%s'", query), "🔍")
	fmt.println()

	// Group results by type
	paths: [dynamic]SearchResult
	aliases: [dynamic]SearchResult
	constants: [dynamic]SearchResult
	defer delete(paths)
	defer delete(aliases)
	defer delete(constants)

	for r in results {
		switch r.spec_type {
		case .PATH:     append(&paths, r)
		case .ALIAS:    append(&aliases, r)
		case .CONSTANT: append(&constants, r)
		}
	}

	total_found := 0

	// Print PATH results
	if len(paths) > 0 {
		print_section_header("PATH", "📂", len(paths))
		for r in paths {
			print_search_result_line(r, "path")
			total_found += 1
		}
		fmt.println()
	}

	// Print alias results
	if len(aliases) > 0 {
		print_section_header("Aliases", "🔑", len(aliases))
		for r in aliases {
			print_search_result_line(r, "alias")
			total_found += 1
		}
		fmt.println()
	}

	// Print constant results
	if len(constants) > 0 {
		print_section_header("Constants", "💾", len(constants))
		for r in constants {
			print_search_result_line(r, "const")
			total_found += 1
		}
		fmt.println()
	}

	// Print summary
	fmt.printfln("%sTotal: %d match(es) found%s", get_muted(), total_found, RESET)
	fmt.println()
	fmt.printfln("%sTip:%s Use 'wayu <type> get <name>' to see full details%s",
		get_secondary(), get_primary(), RESET)
}

// print_section_header - Print a section header for results
print_section_header :: proc(title: string, icon: string, count: int) {
	fmt.printfln("%s%s %s%s (%d found)%s",
		get_primary(), icon, title, RESET, count, RESET)
	fmt.printfln("%s%s%s",
		get_muted(), strings.repeat("─", 50), RESET)
}

// print_search_result_line - Print a single search result line
print_search_result_line :: proc(result: SearchResult, cmd_type: string) {
	// Build type indicator
	type_indicator := match_type_to_string_short(result.match_type)
	score_indicator := ""
	if result.score > 1000 {
		score_indicator = fmt.tprintf(" %s★%s", get_success(), RESET)
	} else if result.score > 500 {
		score_indicator = fmt.tprintf(" %s◆%s", get_warning(), RESET)
	}

	// Build field indicator (show [in value] for value matches)
	field_indicator := ""
	if result.matched_field == .VALUE {
		field_indicator = fmt.tprintf(" %s[in value]%s", get_muted(), RESET)
	}

	// Print name with type indicator
	fmt.printfln("  %s%s%s %s[%s]%s%s%s",
		get_primary(), result.name, RESET,
		get_muted(), type_indicator, RESET,
		field_indicator,
		score_indicator)

	// Print value if present and not too long
	if result.value != "" && len(result.value) < 60 {
		truncated := result.value
		if len(truncated) > 50 {
			truncated = fmt.tprintf("%s...", truncated[:47])
		}
		fmt.printfln("      %s%s%s", get_muted(), truncated, RESET)
	}
}

// match_type_to_string_short - Short string representation of match type
match_type_to_string_short :: proc(mt: MatchType) -> string {
	switch mt {
	case .Exact:     return "exact"
	case .Prefix:    return "prefix"
	case .Substring: return "substring"
	case .Acronym:   return "acronym"
	case .Fuzzy:     return "fuzzy"
	}
	return ""
}

// print_search_usage - Print usage help for search command
print_search_usage :: proc() {
	fmt.println()
	fmt.printfln("%swayu search - Global fuzzy search across all configurations%s", BOLD, RESET)
	fmt.println()
	fmt.printfln("%sUSAGE:%s", get_primary(), RESET)
	fmt.printfln("  wayu search <query>")
	fmt.printfln("  wayu find <query>")
	fmt.printfln("  wayu f <query>")
	fmt.println()
	fmt.printfln("%sDESCRIPTION:%s", get_primary(), RESET)
	fmt.println("  Searches across PATH entries, aliases, and environment constants")
	fmt.println("  simultaneously using fuzzy matching.")
	fmt.println()
	fmt.printfln("%sMATCH TYPES:%s", get_primary(), RESET)
	fmt.println("  exact     - Exact name match")
	fmt.println("  prefix    - Name starts with query")
	fmt.println("  substring - Name contains query")
	fmt.println("  acronym   - Query matches uppercase letters (e.g., 'frwrks' → 'FIREWORKS_AI_API_KEY')")
	fmt.println("  fuzzy     - General fuzzy character matching")
	fmt.println()
	fmt.printfln("%sSCORE INDICATORS:%s", get_primary(), RESET)
	fmt.printfln("  %s★%s - High confidence match (score > 1000)", get_success(), RESET)
	fmt.printfln("  %s◆%s - Medium confidence match (score > 500)", get_warning(), RESET)
	fmt.println()
	fmt.printfln("%sEXAMPLES:%s", get_primary(), RESET)
	fmt.println("  wayu search git          # Find all entries containing 'git'")
	fmt.println("  wayu find frwrks         # Find FIREWORKS_AI_API_KEY by acronym")
	fmt.println("  wayu f api               # Short alias for search")
	fmt.println()
	fmt.printfln("%sENVIRONMENT VARIABLES:%s", get_primary(), RESET)
	fmt.println("  WAYU_FFF_ENABLED=0        - Disable fuzzy features")
	fmt.println("  WAYU_FFF_AUTO_FALLBACK=0  - Disable auto fuzzy fallback")
	fmt.println()
	fmt.printfln("%sSee also:%s wayu <command> get <name> for specific value lookup",
		get_muted(), RESET)
}
