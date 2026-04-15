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

// SearchResult represents a single match from any config type
SearchResult :: struct {
	spec_type: ConfigEntryType,
	name:      string,
	value:     string,
	score:     int,
	match_type: MatchType,
}

// handle_search_command - Main entry point for search/find/f commands
handle_search_command :: proc(args: []string) {
	if len(args) == 0 {
		print_search_usage()
		os.exit(EXIT_USAGE)
	}

	query := args[0]
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

	// Search PATH entries
	path_results := search_config_entries(&PATH_SPEC, query)
	defer free_fuzzy_matches(path_results)
	for match in path_results {
		append(&all_results, SearchResult{
			spec_type  = .PATH,
			name       = strings.clone(match.entry.name),
			value       = "",
			score       = match.score,
			match_type  = match.match_type,
		})
	}

	// Search aliases
	alias_results := search_config_entries(&ALIAS_SPEC, query)
	defer free_fuzzy_matches(alias_results)
	for match in alias_results {
		value := strings.clone(match.entry.value) if match.entry.value != "" else ""
		append(&all_results, SearchResult{
			spec_type  = .ALIAS,
			name       = strings.clone(match.entry.name),
			value       = value,
			score       = match.score,
			match_type  = match.match_type,
		})
	}

	// Search constants
	constant_results := search_config_entries(&CONSTANTS_SPEC, query)
	defer free_fuzzy_matches(constant_results)
	for match in constant_results {
		value := strings.clone(match.entry.value) if match.entry.value != "" else ""
		append(&all_results, SearchResult{
			spec_type  = .CONSTANT,
			name       = strings.clone(match.entry.name),
			value       = value,
			score       = match.score,
			match_type  = match.match_type,
		})
	}

	// Sort all results by score (highest first)
	slice.sort_by(all_results[:], proc(a, b: SearchResult) -> bool {
		return a.score > b.score
	})

	// Display results grouped by type
	print_search_results(query, all_results[:])
}

// search_config_entries - Search entries in a specific config spec
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

	// Print name with type indicator
	fmt.printfln("  %s%s%s %s[%s]%s%s",
		get_primary(), result.name, RESET,
		get_muted(), type_indicator, RESET,
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
