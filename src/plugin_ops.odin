package wayu
import "core:fmt"
import "core:os"
import "core:strings"
import "core:slice"
import "core:sync"
import "core:strconv"
import "core:encoding/json"
import "core:path/filepath"
git_clone :: proc(url: string, dest: string) -> bool {
	if wayu.dry_run {
		print_info("[DRY RUN] Would execute: git clone --depth=1 --quiet %s %s", url, dest)
		return true
	}

	return run_command([]string{"git", "clone", "--depth=1", "--quiet", url, dest})
}

// Update plugin (git pull)
git_update :: proc(plugin_dir: string) -> bool {
	if wayu.dry_run {
		print_info("[DRY RUN] Would execute: git -C %s pull --quiet", plugin_dir)
		return true
	}

	return run_command([]string{"git", "-C", plugin_dir, "pull", "--quiet"})
}

// Check if directory is git repo
is_git_repo :: proc(dir: string) -> bool {
	git_dir := fmt.aprintf("%s/.git", dir)
	defer delete(git_dir)

	return os.exists(git_dir)
}

// Plugin file detection

// Detect plugin entry file to source.
// Fish plugins don't usually have a single entry file — they rely on
// conf.d/*.fish and functions/*.fish. This helper still returns the most
// canonical single file when one exists (useful for the one-file-plugin
// case) — full discovery happens in get_plugin_files_to_source.
detect_plugin_file :: proc(plugin_dir: string, plugin_name: string, shell: ShellType) -> (string, bool) {
	ext := get_shell_extension(shell)

	// 1. Standard plugin file: {name}.plugin.{zsh,bash,fish}
	plugin_file := fmt.aprintf("%s/%s.plugin.%s", plugin_dir, plugin_name, ext)
	if os.exists(plugin_file) {
		return plugin_file, true
	}
	delete(plugin_file)

	// 2. Simple naming: {name}.{zsh,bash,fish}
	simple_file := fmt.aprintf("%s/%s.%s", plugin_dir, plugin_name, ext)
	if os.exists(simple_file) {
		return simple_file, true
	}
	delete(simple_file)

	// 3. Init file: init.{zsh,bash,fish}
	init_file := fmt.aprintf("%s/init.%s", plugin_dir, ext)
	if os.exists(init_file) {
		return init_file, true
	}
	delete(init_file)

	// 4. Fish-specific: conf.d/ directory is the canonical fish layout.
	//    Report it as "found" (even though it's a dir) so callers know the
	//    plugin has loadable content — full file expansion happens in
	//    get_plugin_files_to_source.
	if shell == .FISH {
		conf_d := fmt.aprintf("%s/conf.d", plugin_dir)
		if os.is_dir(conf_d) {
			return conf_d, true
		}
		delete(conf_d)
	}

	// 5. Fallback: directory-wide source
	return "", false
}

// URL validation
is_valid_git_url :: proc(url: string) -> bool {
	// Basic validation - check if it looks like a git URL
	if strings.has_prefix(url, "http://") ||
	   strings.has_prefix(url, "https://") ||
	   strings.has_prefix(url, "git@") {
		return is_safe_shell_arg(url)
	}
	return false
}

// Extract plugin name from URL.
// Trailing slashes and a ".git" suffix are stripped before taking the last
// path component ("https://h/u/repo.git/" -> "repo"). For scp-style URLs
// without a slash ("git@host:repo") the part after the last ':' is used.
// Returns an ALLOCATED string (possibly empty) — caller must delete. Callers
// must still run is_valid_plugin_name on the result.
extract_plugin_name_from_url :: proc(url: string) -> string {
	url_clean := strings.trim_right(url, "/")
	url_clean = strings.trim_suffix(url_clean, ".git")
	url_clean = strings.trim_right(url_clean, "/")

	name := url_clean
	if idx := strings.last_index_byte(name, '/'); idx >= 0 {
		name = name[idx + 1:]
	}
	if idx := strings.last_index_byte(name, ':'); idx >= 0 {
		name = name[idx + 1:]
	}
	return strings.clone(name)
}

// A plugin name becomes a directory under the plugins root and an argument
// to `rm`, so it must be a single, non-special path component.
is_valid_plugin_name :: proc(name: string) -> bool {
	if len(name) == 0 || name == "." || name == ".." {
		return false
	}
	if strings.has_prefix(name, "-") {
		return false
	}
	for c in name {
		if c == '/' || c == '\\' || c == 0 || c == '\n' || c == '\r' {
			return false
		}
	}
	return true
}

// True when `path` is strictly inside `root` (never root itself). Both are
// cleaned first so "root/x/.." and "root/" are rejected.
is_path_inside_dir :: proc(path: string, root: string) -> bool {
	if len(path) == 0 || len(root) == 0 {
		return false
	}
	clean_path, _ := filepath.clean(path, context.temp_allocator)
	clean_root, _ := filepath.clean(root, context.temp_allocator)
	prefix := strings.concatenate({clean_root, "/"}, context.temp_allocator)
	return strings.has_prefix(clean_path, prefix) && len(clean_path) > len(prefix)
}

// Free a PluginInfo returned by resolve_plugin (all fields are owned).
plugin_info_destroy :: proc(info: ^PluginInfo) {
	delete(info.name)
	delete(info.url)
	delete(info.description)
	info^ = PluginInfo{}
}

// Find plugin by name in config
find_plugin :: proc(config: ^PluginConfig, name: string) -> (^InstalledPlugin, bool) {
	for &plugin in config.plugins {
		if plugin.name == name {
			return &plugin, true
		}
	}
	return nil, false
}

// Check if plugin is already installed
is_plugin_installed :: proc(config: ^PluginConfig, name: string) -> bool {
	_, found := find_plugin(config, name)
	return found
}

// Plugin match result with score
PluginMatch :: struct {
	plugin: ^PluginMetadata,
	score:  int,
}

// Find plugin in JSON config by EXACT name (or exact display name).
// Never prompts and never fuzzy-matches: this is the lookup used for
// identity checks ("already installed", dependency resolution, loader
// generation, removal, TUI). User-facing CLI commands that want typo
// tolerance call find_plugin_json_fuzzy instead.
find_plugin_json :: proc(config: ^PluginConfigJSON, name: string) -> (^PluginMetadata, bool) {
	for &plugin in config.plugins {
		if plugin.name == name {
			return &plugin, true
		}
	}
	for &plugin in config.plugins {
		if plugin.display_name != "" && plugin.display_name == name {
			return &plugin, true
		}
	}
	return nil, false
}

// Collect fuzzy candidates (score >= 50), best first. Allocated in temp.
plugin_fuzzy_candidates :: proc(config: ^PluginConfigJSON, name: string) -> [dynamic]PluginMatch {
	matches := make([dynamic]PluginMatch, allocator = context.temp_allocator)

	for &plugin in config.plugins {
		score := fuzzy_match_score(plugin.name, name)
		if plugin.display_name != "" && plugin.display_name != plugin.name {
			dn_score := fuzzy_match_score(plugin.display_name, name)
			if dn_score > score {
				score = dn_score
			}
		}
		if score >= 50 {
			append(&matches, PluginMatch{plugin = &plugin, score = score})
		}
	}

	slice.stable_sort_by(matches[:], proc(a, b: PluginMatch) -> bool {
		return a.score > b.score
	})
	return matches
}

// Print up to 3 "did you mean" suggestions to stderr. Returns true when at
// least one suggestion was printed.
print_plugin_suggestions :: proc(config: ^PluginConfigJSON, name: string) -> bool {
	matches := plugin_fuzzy_candidates(config, name)
	if len(matches) == 0 {
		return false
	}
	fmt.eprintln("Did you mean:")
	for i in 0..<min(len(matches), 3) {
		fmt.eprintfln("  %s", matches[i].plugin.name)
	}
	return true
}

// Find plugin by name with fuzzy fallback (CLI convenience lookup).
// Exact match wins. Otherwise a single/clearly-best fuzzy match is returned.
// With several close matches, an interactive selection is shown ONLY when
// stdin is a terminal; otherwise the candidates are listed on stderr and the
// lookup fails (never blocks on stdin in scripts/pipes).
find_plugin_json_fuzzy :: proc(config: ^PluginConfigJSON, name: string) -> (^PluginMetadata, bool) {
	if p, ok := find_plugin_json(config, name); ok {
		return p, true
	}

	matches := plugin_fuzzy_candidates(config, name)

	if len(matches) == 0 {
		return nil, false
	}

	// If only one match, return it directly
	if len(matches) == 1 {
		return matches[0].plugin, true
	}

	// If best match has significantly higher score (20+ points), use it
	if matches[0].score >= matches[1].score + 20 {
		return matches[0].plugin, true
	}

	num_options := min(len(matches), 3)

	if !os.is_tty(os.stdin) {
		fmt.eprintfln("Ambiguous plugin name '%s'. Candidates:", name)
		for i in 0..<num_options {
			fmt.eprintfln("  %s", matches[i].plugin.name)
		}
		return nil, false
	}

	// Multiple close matches - show selection menu (max 3 options)
	fmt.println()
	fmt.printfln("%sMultiple matches found for '%s':%s", BOLD, name, RESET)
	fmt.println()

	for i in 0..<num_options {
		marker := "  "
		if i == 0 {
			marker = "→ "  // Preselected option
		}

		status_icon := "○"
		if matches[i].plugin.enabled {
			status_icon = "✓"
		}

		score_str := ""
		if matches[i].score < 100 {
			score_str = fmt.tprintf(" (%d%% match)", matches[i].score)
		}

		fmt.printfln("%s%d. %s %s%s%s%s",
			marker, i + 1, status_icon, matches[i].plugin.name,
			RESET, score_str, get_muted())
	}

	fmt.println()
	fmt.printf("Select option [1-%d, Enter for 1]: ", num_options)

	// Read user input
	input_buf: [8]byte
	n, _ := os.read(os.stdin, input_buf[:])

	selection := 1  // Default to first (preselected)
	if n > 1 {
		input_str := strings.trim_space(string(input_buf[:n]))
		if parsed, ok := strconv.parse_int(input_str); ok && parsed >= 1 && parsed <= num_options {
			selection = parsed
		}
	}

	fmt.printfln("%sSelected: %s%s", get_success(), matches[selection - 1].plugin.name, RESET)
	fmt.println()

	return matches[selection - 1].plugin, true
}

// Simple fuzzy match score (0-100+)
fuzzy_match_score :: proc(text: string, query: string) -> int {
	if len(query) == 0 {
		return 0
	}
	if len(text) == 0 {
		return 0
	}
	
	text_lower := strings.to_lower(text)
	defer delete(text_lower)
	query_lower := strings.to_lower(query)
	defer delete(query_lower)
	
	// Exact match = 100
	if text_lower == query_lower {
		return 100
	}
	
	// Starts with = 90
	if strings.has_prefix(text_lower, query_lower) {
		return 90
	}
	
	// Contains = 70
	if strings.contains(text_lower, query_lower) {
		return 70
	}
	
	// Fuzzy match - all characters in order
	score := 0
	text_idx := 0
	for query_char in query_lower {
		for text_idx < len(text_lower) {
			if rune(text_lower[text_idx]) == query_char {
				score += 10
				text_idx += 1
				break
			}
			text_idx += 1
		}
	}
	
	// Normalize by query length
	if score > 0 {
		return score * 10 / len(query)
	}
	
	return 0
}

// Validate that all of a plugin's dependencies are installed
// Returns array of missing dependency names
validate_plugin_dependencies :: proc(
	plugin: ^PluginMetadata,
	config: ^PluginConfigJSON,
) -> [dynamic]string {
	missing := make([dynamic]string)

	for dep_name in plugin.dependencies {
		_, found := find_plugin_json(config, dep_name)
		if !found {
			append(&missing, strings.clone(dep_name))
		}
	}

	return missing
}

// Check if any other plugins depend on the given plugin
// Returns array of plugin names that depend on this plugin
check_plugin_dependents :: proc(
	plugin_name: string,
	config: ^PluginConfigJSON,
) -> [dynamic]string {
	dependents := make([dynamic]string)

	for plugin in config.plugins {
		// Skip the plugin itself
		if plugin.name == plugin_name {
			continue
		}

		// Check if this plugin lists plugin_name as a dependency
		for dep_name in plugin.dependencies {
			if dep_name == plugin_name {
				append(&dependents, strings.clone(plugin.name))
				break  // Each plugin only added once
			}
		}
	}

	return dependents
}

// Phase 4: Circular Dependency Detection (Three-Color DFS)

// DFS color states for cycle detection
DFSColor :: enum {
	WHITE = 0,  // Not visited yet
	GRAY  = 1,  // Currently being processed (in recursion stack)
	BLACK = 2,  // Fully processed
}

// Result of circular dependency detection
CycleDetectionResult :: struct {
	has_cycle:  bool,
	cycle_path: [dynamic]string,  // Empty if no cycle
}

// Build directed dependency graph from plugin config
// Returns map: plugin_name -> [dependencies]
build_dependency_graph :: proc(config: ^PluginConfigJSON) -> map[string][dynamic]string {
	graph := make(map[string][dynamic]string)

	for plugin in config.plugins {
		// Initialize entry for this plugin
		if plugin.name not_in graph {
			graph[plugin.name] = make([dynamic]string)
		}

		// Add edges for each dependency
		for dep_name in plugin.dependencies {
			append(&graph[plugin.name], strings.clone(dep_name))
		}
	}

	return graph
}

// Reconstruct cycle path from parent pointers
reconstruct_cycle :: proc(
	cycle_start: string,
	cycle_end: string,
	parent: map[string]string,
) -> [dynamic]string {
	path := make([dynamic]string)

	// Build path from cycle_end back to cycle_start
	append(&path, strings.clone(cycle_start))
	current := cycle_end
	for current != cycle_start {
		append(&path, strings.clone(current))
		current = parent[current]
	}
	append(&path, strings.clone(cycle_start))  // Close the cycle

	// Reverse to get correct order: A → B → C → A
	for i := 0; i < len(path) / 2; i += 1 {
		j := len(path) - 1 - i
		path[i], path[j] = path[j], path[i]
	}

	return path
}

// DFS visit for cycle detection
// Returns true if cycle found
dfs_visit :: proc(
	node: string,
	graph: map[string][dynamic]string,
	color: ^map[string]DFSColor,
	parent: ^map[string]string,
	cycle_start: ^string,
	cycle_end: ^string,
) -> bool {
	color[node] = .GRAY  // Mark as being processed

	// Visit all dependencies
	if node in graph {
		for neighbor in graph[node] {
			if color[neighbor] == .WHITE {
				parent[neighbor] = node
				if dfs_visit(neighbor, graph, color, parent, cycle_start, cycle_end) {
					return true
				}
			} else if color[neighbor] == .GRAY {
				// Back edge detected - cycle found!
				cycle_start^ = neighbor
				cycle_end^ = node
				return true
			}
			// BLACK nodes are fully processed, skip
		}
	}

	color[node] = .BLACK  // Mark as fully processed
	return false
}

// Detect circular dependencies in plugin dependency graph
// Uses three-color DFS with parent tracking for cycle reconstruction
detect_circular_dependencies :: proc(
	graph: map[string][dynamic]string,
) -> CycleDetectionResult {
	color := make(map[string]DFSColor)
	parent := make(map[string]string)
	defer delete(color)
	defer delete(parent)

	// Initialize all nodes as WHITE (unvisited)
	for plugin_name in graph {
		color[plugin_name] = .WHITE
	}

	cycle_start: string = ""
	cycle_end: string = ""

	// Run DFS from each unvisited node
	for plugin_name in graph {
		if color[plugin_name] == .WHITE {
			if dfs_visit(plugin_name, graph, &color, &parent, &cycle_start, &cycle_end) {
				// Cycle found! Reconstruct path
				cycle_path := reconstruct_cycle(cycle_start, cycle_end, parent)
				return CycleDetectionResult{
					has_cycle = true,
					cycle_path = cycle_path,
				}
			}
		}
	}

	// No cycle found
	return CycleDetectionResult{ has_cycle = false }
}

// Validate that plugin configuration has no circular dependencies.
// Returns true if the config is valid (no cycles), false if a cycle was detected.
// Prints the error details when returning false — caller is responsible for cleanup and exit.
validate_no_circular_dependencies :: proc(config: ^PluginConfigJSON) -> bool {
	// Build dependency graph
	graph := build_dependency_graph(config)
	defer {
		for _, deps in graph {
			for dep in deps {
				delete(dep)
			}
			delete(deps)
		}
		delete(graph)
	}

	// Detect cycles
	result := detect_circular_dependencies(graph)
	defer if result.has_cycle {
		for p in result.cycle_path {
			delete(p)
		}
		delete(result.cycle_path)
	}

	if result.has_cycle {
		cycle_str := strings.join(result.cycle_path[:], " → ")
		defer delete(cycle_str)

		print_error("Circular dependency detected: %s", cycle_str)
		fmt.println()
		fmt.println("Circular dependencies prevent determining a valid plugin load order.")
		fmt.println()
		fmt.println("Suggestions:")
		fmt.println("  • Review the dependencies for these plugins")
		fmt.println("  • Remove the dependency that creates the cycle")
		fmt.println("  • Consider if all these dependencies are necessary")
		return false
	}

	return true
}

// zsh-syntax-highlighting wraps every ZLE widget that exists when it is
// sourced, so upstream requires it to be loaded after all other plugins.
plugin_must_load_last :: proc(name: string) -> bool {
	return name == "zsh-syntax-highlighting"
}

// Phase 5: Resolve dependencies with priority-based ordering
// Uses Kahn's algorithm (BFS topological sort) with a priority queue so that
// among all nodes whose dependencies are already satisfied, the one with the
// lowest priority number is emitted first.  This guarantees:
//   1. A node is never emitted before any of its dependencies.
//   2. Among "ready" nodes (all deps satisfied), lower priority number wins.
resolve_dependencies_with_priority :: proc(config: ^PluginConfigJSON) -> (order: [dynamic]string, ok: bool) {
	order = make([dynamic]string)

	// Build priority map and collect enabled plugin names
	priority_map := make(map[string]int)
	defer delete(priority_map)

	for plugin in config.plugins {
		if plugin.enabled {
			priority_map[plugin.name] = plugin.priority
		}
	}

	// Build in-degree map and reverse adjacency list (dependents)
	// in_degree[A] = number of enabled dependencies A still needs before it can load
	// dependents[B] = list of plugins that directly depend on B
	in_degree  := make(map[string]int)
	dependents := make(map[string][dynamic]string)
	defer delete(in_degree)
	defer {
		for _, deps in dependents {
			for dep in deps {
				delete(dep)
			}
			delete(deps)
		}
		delete(dependents)
	}

	// Initialise every enabled plugin with in_degree 0
	for plugin in config.plugins {
		if !plugin.enabled {
			continue
		}
		in_degree[plugin.name] = 0
		if plugin.name not_in dependents {
			dependents[plugin.name] = make([dynamic]string)
		}
	}

	// Count in-degrees and build reverse edges (only among enabled plugins)
	for plugin in config.plugins {
		if !plugin.enabled {
			continue
		}
		for dep_name in plugin.dependencies {
			// Only count the dependency if it is an enabled plugin
			if dep_name in in_degree {
				in_degree[plugin.name] += 1
				append(&dependents[dep_name], strings.clone(plugin.name))
			}
		}
	}

	// Collect all nodes with in_degree == 0 into a "ready" list, then
	// repeatedly pick the one with the lowest priority number.
	ready := make([dynamic]string)
	defer {
		for r in ready {
			delete(r)
		}
		delete(ready)
	}

	// Config position of each enabled plugin — deterministic tie-breaker.
	index_map := make(map[string]int)
	defer delete(index_map)
	for plugin, i in config.plugins {
		if plugin.enabled && plugin.name not_in index_map {
			index_map[plugin.name] = i
		}
	}

	// Seed in config order (map iteration order is unspecified).
	for plugin in config.plugins {
		if !plugin.enabled {
			continue
		}
		if in_degree[plugin.name] == 0 && !slice.contains(ready[:], plugin.name) {
			append(&ready, strings.clone(plugin.name))
		}
	}

	// Ordering key among ready nodes: (must-load-last, priority, config index).
	ready_less :: proc(a, b: string, priority_map, index_map: map[string]int) -> bool {
		a_last := plugin_must_load_last(a)
		b_last := plugin_must_load_last(b)
		if a_last != b_last {
			return !a_last
		}
		pa, pb := priority_map[a], priority_map[b]
		if pa != pb {
			return pa < pb
		}
		return index_map[a] < index_map[b]
	}

	emitted := 0
	total_enabled := len(in_degree)

	for len(ready) > 0 {
		best_idx := 0
		for i in 1..<len(ready) {
			if ready_less(ready[i], ready[best_idx], priority_map, index_map) {
				best_idx = i
			}
		}

		// Emit it
		chosen := ready[best_idx]
		ordered_remove(&ready, best_idx)
		append(&order, strings.clone(chosen))
		emitted += 1

		// Reduce in-degree of dependents
		for dep_name in dependents[chosen] {
			in_degree[dep_name] -= 1
			if in_degree[dep_name] == 0 {
				append(&ready, strings.clone(dep_name))
			}
		}

		delete(chosen)
	}

	// If we didn't emit all nodes, there's a cycle among enabled plugins
	if emitted != total_enabled {
		for name in order {
			delete(name)
		}
		delete(order)
		return order, false
	}

	return order, true
}

// Phase 6: Conflict Detection

// Variables every plugin legitimately appends to; sharing them is not a
// conflict.
SHARED_ENV_VARS :: [?]string{
	"PATH", "FPATH", "MANPATH", "INFOPATH", "CDPATH",
	"path", "fpath", "manpath", "infopath", "cdpath",
}

is_shared_env_var :: proc(name: string) -> bool {
	for v in SHARED_ENV_VARS {
		if v == name {
			return true
		}
	}
	return false
}

// Shell function/alias identifier: no whitespace, quotes, '=', '$', parens
// or redirection characters.
is_shell_identifier :: proc(name: string) -> bool {
	if len(name) == 0 {
		return false
	}
	for c in name {
		switch c {
		case ' ', '\t', '=', '$', '(', ')', '{', '}', '"', '\'', '`', ';', '&', '|', '<', '>', '[', ']':
			return false
		}
	}
	return true
}

// Parse a function definition line. Recognizes:
//   function name() {   function name {   function name
//   name() {            name ()  {        name()
// Rejects assignments such as `reply=()` or `arr=( a b )`.
parse_function_definition :: proc(trimmed: string) -> (string, bool) {
	if strings.has_prefix(trimmed, "function ") {
		rest := strings.trim_left_space(trimmed[len("function "):])
		end := len(rest)
		for c, i in rest {
			if c == ' ' || c == '\t' || c == '(' || c == '{' {
				end = i
				break
			}
		}
		name := rest[:end]
		if is_shell_identifier(name) {
			return name, true
		}
		return "", false
	}

	paren_idx := strings.index(trimmed, "()")
	if paren_idx <= 0 {
		return "", false
	}
	name := strings.trim_right_space(trimmed[:paren_idx])
	if !is_shell_identifier(name) {
		return "", false
	}
	after := strings.trim_left_space(trimmed[paren_idx + 2:])
	if len(after) != 0 && !strings.has_prefix(after, "{") && !strings.has_prefix(after, "(") {
		return "", false
	}
	return name, true
}

append_unique :: proc(list: ^[dynamic]string, value: string) {
	for existing in list {
		if existing == value {
			return
		}
	}
	append(list, strings.clone(value))
}

free_string_list :: proc(list: ^[dynamic]string) {
	for s in list {
		delete(s)
	}
	delete(list^)
	list^ = make([dynamic]string)
}

// Scan one script file and record exports/functions/aliases.
@(private="file")
scan_conflicts_in_file :: proc(plugin: ^PluginMetadata, path: string) -> bool {
	content, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return false
	}
	defer delete(content)

	lines := strings.split_lines(string(content))
	defer delete(lines)

	for line in lines {
		trimmed := strings.trim_space(line)

		// Skip comments and empty lines
		if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") {
			continue
		}

		// export VAR=value / export VAR
		if strings.has_prefix(trimmed, "export ") {
			after_export := strings.trim_left_space(trimmed[len("export "):])
			end := len(after_export)
			for c, i in after_export {
				if c == '=' || c == ' ' || c == '\t' || c == ';' {
					end = i
					break
				}
			}
			var_name := after_export[:end]
			if is_shell_identifier(var_name) && !strings.has_prefix(var_name, "-") && !is_shared_env_var(var_name) {
				append_unique(&plugin.conflicts.env_vars, var_name)
			}
			continue
		}

		// alias [-flags] name=value
		if strings.has_prefix(trimmed, "alias ") {
			rest := strings.trim_left_space(trimmed[len("alias "):])
			for strings.has_prefix(rest, "-") {
				sp := strings.index_any(rest, " \t")
				if sp < 0 {
					rest = ""
					break
				}
				rest = strings.trim_left_space(rest[sp:])
			}
			eq := strings.index_byte(rest, '=')
			if eq > 0 {
				alias_name := rest[:eq]
				if is_shell_identifier(alias_name) {
					append_unique(&plugin.conflicts.aliases_, alias_name)
				}
			}
			continue
		}

		if func_name, ok := parse_function_definition(trimmed); ok {
			append_unique(&plugin.conflicts.functions, func_name)
		}
	}

	return true
}

// Scan plugin for potential conflicts (exports, functions, aliases).
// Scans every file the loader would source for this plugin, not just the
// detected entry file.
scan_plugin_conflicts :: proc(plugin: ^PluginMetadata) -> bool {
	files := get_plugin_files_to_source(plugin^, wayu.shell)
	defer {
		for f in files {
			delete(f)
		}
		delete(files)
	}

	// Clear existing conflict data (free owned strings too)
	free_string_list(&plugin.conflicts.env_vars)
	free_string_list(&plugin.conflicts.functions)
	free_string_list(&plugin.conflicts.aliases_)

	ok := true
	for f in files {
		if os.is_dir(f) {
			continue
		}
		if !scan_conflicts_in_file(plugin, f) {
			ok = false
		}
	}
	return ok
}

// Detect conflicts between all enabled plugins
// Compares env vars, functions, and aliases to find duplicates
detect_conflicts :: proc(config: ^PluginConfigJSON) {
	// First, scan all enabled plugins for their declarations.
	// Only scan if installed_path exists — tests pre-populate conflict arrays
	// with non-existent paths and expect those arrays to be preserved.
	for &plugin in config.plugins {
		if !plugin.enabled {
			continue
		}

		if os.exists(plugin.installed_path) {
			scan_plugin_conflicts(&plugin)
		}
	}

	// Reset conflict tracking for all enabled plugins before pairwise comparison.
	// This must be a separate pass so that results written during pair (i,j)
	// are not erased when the outer loop reaches j as the new i.
	for i := 0; i < len(config.plugins); i += 1 {
		plugin := &config.plugins[i]
		if !plugin.enabled {
			continue
		}
		free_string_list(&plugin.conflicts.conflicting_plugins)
		plugin.conflicts.detected = false
	}

	// Now compare plugins pairwise to detect conflicts
	for i := 0; i < len(config.plugins); i += 1 {
		plugin_a := &config.plugins[i]

		if !plugin_a.enabled {
			continue
		}

		for j := i + 1; j < len(config.plugins); j += 1 {
			plugin_b := &config.plugins[j]

			if !plugin_b.enabled {
				continue
			}

			has_conflict := false

			// Check environment variable conflicts
			for var_a in plugin_a.conflicts.env_vars {
				for var_b in plugin_b.conflicts.env_vars {
					if var_a == var_b {
						has_conflict = true
						break
					}
				}
				if has_conflict do break
			}

			// Check function conflicts
			if !has_conflict {
				for func_a in plugin_a.conflicts.functions {
					for func_b in plugin_b.conflicts.functions {
						if func_a == func_b {
							has_conflict = true
							break
						}
					}
					if has_conflict do break
				}
			}

			// Check alias conflicts
			if !has_conflict {
				for alias_a in plugin_a.conflicts.aliases_ {
					for alias_b in plugin_b.conflicts.aliases_ {
						if alias_a == alias_b {
							has_conflict = true
							break
						}
					}
					if has_conflict do break
				}
			}

			// If conflict found, mark both plugins
			if has_conflict {
				plugin_a.conflicts.detected = true
				plugin_b.conflicts.detected = true

				// Add to conflicting plugins list (avoid duplicates)
				already_tracked := false
				for existing in plugin_a.conflicts.conflicting_plugins {
					if existing == plugin_b.name {
						already_tracked = true
						break
					}
				}
				if !already_tracked {
					append(&plugin_a.conflicts.conflicting_plugins, strings.clone(plugin_b.name))
				}

				// Also track in plugin_b
				already_tracked_b := false
				for existing in plugin_b.conflicts.conflicting_plugins {
					if existing == plugin_a.name {
						already_tracked_b = true
						break
					}
				}
				if !already_tracked_b {
					append(&plugin_b.conflicts.conflicting_plugins, strings.clone(plugin_a.name))
				}
			}
		}
	}
}

// Resolve plugin name or URL to PluginInfo.
// On success every string field is ALLOCATED (registry entries and argv are
// cloned) — release with plugin_info_destroy. Fails for unknown keys and for
// URLs whose derived name is not a safe directory name (see
// is_valid_plugin_name), e.g. "https://github.com/" or ".../..".
resolve_plugin :: proc(name_or_url: string) -> (PluginInfo, bool) {
	// Check if it's a URL
	if is_valid_git_url(name_or_url) {
		plugin_name := extract_plugin_name_from_url(name_or_url)
		if !is_valid_plugin_name(plugin_name) {
			delete(plugin_name)
			return PluginInfo{}, false
		}

		return PluginInfo{
			name = plugin_name,
			url = strings.clone(name_or_url),
			shell = .BOTH, // Unknown shell compat for custom URLs
			description = strings.clone("Custom plugin"),
		}, true
	}

	// Check popular plugins registry (static literals — clone for ownership)
	if info, found := popular_plugin_find(name_or_url); found {
		return PluginInfo{
			name = strings.clone(info.name),
			url = strings.clone(info.url),
			shell = info.shell,
			description = strings.clone(info.description),
		}, true
	}

	return PluginInfo{}, false
}

// True when local and remote commit SHAs refer to the same commit. Either
// side may be abbreviated (rev-parse --short length varies), so the shorter
// one must be a prefix of the longer one.
git_commits_match :: proc(a: string, b: string) -> bool {
	la := strings.trim_space(a)
	lb := strings.trim_space(b)
	if len(la) == 0 || len(lb) == 0 {
		return false
	}
	if len(la) <= len(lb) {
		return strings.has_prefix(lb, la)
	}
	return strings.has_prefix(la, lb)
}

// Get remote commit SHA for a git repository
// Returns full SHA or empty string on failure
// CRITICAL: Returned string is ALLOCATED - caller must delete()
get_remote_commit :: proc(url: string, branch: string) -> string {
	// Use HEAD if no branch specified
	branch_ref := branch != "" ? branch : "HEAD"

	// Run: git ls-remote <url> <branch_ref>
	// Output format: "<40-char-SHA>\t<ref-name>\n"
	// No shell needed — parse the first field in Odin
	output := capture_command([]string{"git", "ls-remote", url, branch_ref})
	defer delete(output)

	if output == "" {
		return ""
	}

	// Parse: first field before any whitespace is the full SHA
	// git ls-remote output: "abc123def456...\trefs/heads/main"
	// NOTE: Odin for-string syntax is "for value, index in str" — r=rune, i=byte_offset
	full_sha := output
	for r, i in output {
		if r == '\t' || r == ' ' || r == '\n' || r == '\r' {
			full_sha = output[:i]
			break
		}
	}

	if len(full_sha) == 0 {
		return ""
	}

	// Return the full SHA — ALLOCATED, caller must delete. Comparison against
	// the (abbreviated) local commit uses git_commits_match.
	return strings.clone(full_sha)
}


// ============================================================================
// CLI command handlers (merged from plugin_operations.odin)
// ============================================================================




// Handle plugin check command - check for available updates
// CLI-only command (no interactive mode)
// Checks all enabled plugins for updates using git ls-remote

