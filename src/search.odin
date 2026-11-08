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
		os.exit(EXIT_SUCCESS)
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
	// Names only: matching inside constant values turns search into a
	// secret oracle (`wayu f sk-` finding API keys). (OKAMI-208)
	const_search_results := search_toml_entries_by_name(const_entries_toml[:], query, match_values = false)
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

	if wayu.json_output {
		print_search_results_json(query, all_results[:])
		return
	}

	// Display results grouped by type
	print_search_results(query, all_results[:])
}

// print_search_results_json - `wayu search QUERY --json` (OKAMI-239).
// Shape: {"query": "...", "results": [{"type": "path|alias|constant",
// "name": ..., "value": ..., "match": "exact|prefix|...", "field":
// "name|value", "score": N}, ...], "count": N}. Results are in score
// order; constant values are masked like the text view.
print_search_results_json :: proc(query: string, results: []SearchResult) {
	query_j := json_escape(query); defer delete(query_j)
	fmt.println("{")
	fmt.printfln("  \"query\": \"%s\",", query_j)
	fmt.println(`  "results": [`)
	for r, i in results {
		if i > 0 { fmt.println(",") }
		type_str := "path"
		switch r.spec_type {
		case .PATH:     type_str = "path"
		case .ALIAS:    type_str = "alias"
		case .CONSTANT: type_str = "constant"
		}
		name_j  := json_escape(r.name);                           defer delete(name_j)
		value_j := json_escape(mask_secret_value(r.name, r.value)); defer delete(value_j)
		field   := "value" if r.matched_field == .VALUE else "name"
		// `{` is a struct-verb opener in Odin's fmt — emit via %c.
		fmt.printf("    %c\"type\": \"%s\", \"name\": \"%s\", \"value\": \"%s\", \"match\": \"%s\", \"field\": \"%s\", \"score\": %d%c",
			'{', type_str, name_j, value_j, match_type_to_string_short(r.match_type), field, r.score, '}')
	}
	if len(results) > 0 { fmt.println() }
	fmt.println("  ],")
	fmt.printfln("  \"count\": %d", len(results))
	fmt.println("}")
}

// search_toml_entries_by_name - Fuzzy search through TOML config entries
// Matches on the name and, when `match_values`, the value field. Returns
// scored entries for sorting and display.
search_toml_entries_by_name :: proc(entries: []ConfigEntry, query: string, match_values := true) -> [dynamic]SearchEntry {
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

		// Lower-case once per field (strings.to_lower allocates; the old
		// inline calls leaked one string per comparison).
		name_lower := strings.to_lower(entry.name)
		defer delete(name_lower)
		value_lower := strings.to_lower(entry.value)
		defer delete(value_lower)

		// Score name field
		if strings.equal_fold(entry.name, query) {
			name_score = 10000
			name_match_type = .Exact
		} else if strings.has_prefix(name_lower, query_lower) {
			// Prefix match
			name_score = 5000 + fuzzy_score(entry.name, query)
			name_match_type = .Prefix
		} else if strings.contains(name_lower, query_lower) {
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
		if match_values && entry.value != "" {
			if strings.equal_fold(entry.value, query) {
				value_score = 10000
				value_match_type = .Exact
			} else if strings.has_prefix(value_lower, query_lower) {
				// Prefix match
				value_score = 5000 + fuzzy_score(entry.value, query)
				value_match_type = .Prefix
			} else if strings.contains(value_lower, query_lower) {
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

	// Print value (truncated on a rune boundary so multi-byte UTF-8 is never
	// split; long values used to be hidden entirely). Secret-looking values
	// are masked (OKAMI-208); `wayu const get NAME` prints the real one.
	if result.value != "" {
		shown := mask_secret_value(result.name, result.value)
		fmt.printfln("      %s%s%s", get_muted(), truncate_display(shown, 50), RESET)
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
	fmt.println("  simultaneously using fuzzy matching. Constants match by name only;")
	fmt.println("  secret-looking values are shown as ********.")
	fmt.println()
	fmt.printfln("%sMATCH TYPES:%s", get_primary(), RESET)
	fmt.println("  exact     - Exact name match")
	fmt.println("  prefix    - Name starts with query")
	fmt.println("  substring - Name contains query")
	fmt.println("  acronym   - Query is in the first letters of the name's words (e.g., 'faak' → 'FIREWORKS_AI_API_KEY')")
	fmt.println("  fuzzy     - General fuzzy character matching")
	fmt.println()
	fmt.printfln("%sSCORE INDICATORS:%s", get_primary(), RESET)
	fmt.printfln("  %s★%s - High confidence match (score > 1000)", get_success(), RESET)
	fmt.printfln("  %s◆%s - Medium confidence match (score > 500)", get_warning(), RESET)
	fmt.println()
	fmt.printfln("%sEXAMPLES:%s", get_primary(), RESET)
	fmt.println("  wayu search git          # Find all entries containing 'git'")
	fmt.println("  wayu find faak           # Find FIREWORKS_AI_API_KEY by acronym")
	fmt.println("  wayu f api               # Short alias for search")
	fmt.println()
	fmt.printfln("%sSee also:%s wayu <command> get <name> for specific value lookup",
		get_muted(), RESET)
}
