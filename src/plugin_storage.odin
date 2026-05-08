package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:slice"
import "core:sync"
import "core:strconv"
import "core:encoding/json"

// Mutex to protect concurrent access to plugins.json
// Prevents race conditions when multiple threads read/write simultaneously
_plugins_json_mutex: sync.Mutex

// Get plugins config file path
get_plugins_config_file :: proc() -> string {
	return fmt.aprintf("%s/plugins.conf", g_ctx.wayu_config)
}

// Get plugins JSON config file path
get_plugins_json_config_file :: proc() -> string {
	return fmt.aprintf("%s/plugins.json", g_ctx.wayu_config)
}

// Get plugins directory path
get_plugins_dir :: proc() -> string {
	return fmt.aprintf("%s/plugins", g_ctx.wayu_config)
}

// Read plugins.conf configuration file
read_plugin_config :: proc() -> PluginConfig {
	config := PluginConfig{}
	config.plugins = make([dynamic]InstalledPlugin)

	config_file := get_plugins_config_file()
	defer delete(config_file)

	if !os.exists(config_file) {
		return config
	}

	data, read_err := os.read_entire_file(config_file, context.allocator)
	if read_err != nil {
		return config
	}
	defer delete(data)

	content := string(data)
	lines := strings.split_lines(content)
	defer delete(lines)

	for line in lines {
		trimmed_line := strings.trim_space(line)

		// Skip empty lines and comments
		if len(trimmed_line) == 0 || strings.has_prefix(trimmed_line, "#") {
			continue
		}

		// Parse: name|url|enabled|shell
		parts := strings.split(trimmed_line, "|")
		defer delete(parts)

		if len(parts) != 4 {
			continue
		}

		plugins_dir := get_plugins_dir()
		defer delete(plugins_dir)

		plugin := InstalledPlugin{
			name = strings.clone(parts[0]),
			url = strings.clone(parts[1]),
			enabled = parts[2] == "true",
			shell = parse_shell_compat(parts[3]),
			installed_path = fmt.aprintf("%s/%s", plugins_dir, parts[0]),
		}

		append(&config.plugins, plugin)
	}

	return config
}

// Write plugins.conf configuration file
write_plugin_config :: proc(config: ^PluginConfig) -> bool {
	config_file := get_plugins_config_file()
	defer delete(config_file)

	// Build content
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)

	strings.write_string(&sb, "# Wayu Plugin Configuration\n")
	strings.write_string(&sb, "# Format: name|url|enabled|shell\n")
	strings.write_string(&sb, "# shell: zsh, bash, both\n\n")

	for plugin in config.plugins {
		line := fmt.aprintf("%s|%s|%t|%s\n",
			plugin.name,
			plugin.url,
			plugin.enabled,
			shell_compat_to_string(plugin.shell))
		defer delete(line)

		strings.write_string(&sb, line)
	}

	content := strings.to_string(sb)
	return os.write_entire_file(config_file, transmute([]byte)content) == nil
}

// Read JSON5 configuration file
read_plugin_config_json :: proc() -> (config: PluginConfigJSON, ok: bool) {
	sync.lock(&_plugins_json_mutex)
	defer sync.unlock(&_plugins_json_mutex)

	config_file := get_plugins_json_config_file()
	defer delete(config_file)

	if !os.exists(config_file) {
		// Return empty config on first run
		config.version = strings.clone("1.0")
		config.last_updated = get_iso8601_timestamp()
		config.plugins = make([dynamic]PluginMetadata)
		return config, true
	}

	data, read_err := os.read_entire_file(config_file, context.allocator)
	if read_err != nil {
		fmt.eprintln("Error: Failed to read plugins.json")
		return config, false
	}
	defer delete(data)

	// Parse as JSON5 (allows comments and trailing commas)
	json_err := json.unmarshal(data, &config, spec = .JSON5)
	if json_err != nil {
		fmt.eprintfln("Error: Failed to parse plugins.json: %v", json_err)
		return config, false
	}

	// Phase 4: Validate no circular dependencies on load
	if !validate_no_circular_dependencies(&config) {
		return config, false
	}

	return config, true
}

// Write JSON5 configuration file
write_plugin_config_json :: proc(config: ^PluginConfigJSON) -> bool {
	sync.lock(&_plugins_json_mutex)
	defer sync.unlock(&_plugins_json_mutex)

	// Free old last_updated before overwriting (it was allocated by get_iso8601_timestamp)
	if len(config.last_updated) > 0 {
		delete(config.last_updated)
	}
	config.last_updated = get_iso8601_timestamp()

	// Marshal to JSON5 with pretty printing
	marshal_options := json.Marshal_Options{
		pretty = true,
		use_spaces = true,
		spaces = 2,
		spec = .JSON5,
	}

	data, marshal_err := json.marshal(config^, marshal_options)
	if marshal_err != nil {
		fmt.eprintfln("Error: Failed to marshal config: %v", marshal_err)
		return false
	}
	defer delete(data)

	config_file := get_plugins_json_config_file()
	defer delete(config_file)

	write_err := os.write_entire_file(config_file, data)
	if write_err != nil {
		fmt.eprintln("Error: Failed to write plugins.json")
		return false
	}

	return true
}

// Migrate from old pipe-delimited format to JSON5
migrate_plugin_config :: proc() -> bool {
	old_file := get_plugins_config_file()
	defer delete(old_file)

	new_file := get_plugins_json_config_file()
	defer delete(new_file)

	// Skip if new file exists or old file doesn't exist
	if os.exists(new_file) || !os.exists(old_file) {
		return true
	}

	print_info("Migrating plugins.conf to plugins.json...")

	// Read old config
	old_config := read_plugin_config()
	defer {
		for plugin in old_config.plugins {
			delete(plugin.name)
			delete(plugin.url)
			delete(plugin.installed_path)
			delete(plugin.entry_file)
		}
		delete(old_config.plugins)
	}

	// Convert to new format
	new_config := PluginConfigJSON{
		version = "1.0",
		last_updated = get_iso8601_timestamp(),
		plugins = make([dynamic]PluginMetadata),
	}
	defer cleanup_plugin_config_json(&new_config)

	for old_plugin in old_config.plugins {
		// Get git info for existing plugin
		git_info := get_git_info(old_plugin.installed_path)

		new_plugin := PluginMetadata{
			name = strings.clone(old_plugin.name),
			display_name = strings.clone(old_plugin.name),
			url = strings.clone(old_plugin.url),
			source_type = .GitHub,  // Default for migrated plugins
			enabled = old_plugin.enabled,
			shell = old_plugin.shell,
			installed_path = strings.clone(old_plugin.installed_path),
			entry_file = strings.clone(old_plugin.entry_file),
			use = make([dynamic]string),  // Empty = auto-detect
			template = .Source,  // Default template
			git = git_info,
			dependencies = make([dynamic]string),
			priority = 100, // Default priority
			profiles = make([dynamic]string),  // Empty = all profiles
			conflicts = ConflictInfo{
				env_vars = make([dynamic]string),
				functions = make([dynamic]string),
				aliases_ = make([dynamic]string),
				detected = false,
				conflicting_plugins = make([dynamic]string),
			},
		}

		append(&new_config.plugins, new_plugin)
	}

	// Write new config
	if !write_plugin_config_json(&new_config) {
		print_error_simple("Failed to write new configuration")
		return false
	}

	// Backup old config
	backup_file := fmt.aprintf("%s.backup", old_file)
	defer delete(backup_file)

	os.rename(old_file, backup_file)

	print_success("Migration complete! Old config backed up to plugins.conf.backup")
	return true
}

// Git operations

// Clone plugin repository
git_clone :: proc(url: string, dest: string) -> bool {
	if g_ctx.dry_run {
		print_info("[DRY RUN] Would execute: git clone --depth=1 --quiet %s %s", url, dest)
		return true
	}

	return run_command([]string{"git", "clone", "--depth=1", "--quiet", url, dest})
}

// Update plugin (git pull)
git_update :: proc(plugin_dir: string) -> bool {
	if g_ctx.dry_run {
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

// Extract plugin name from URL
extract_plugin_name_from_url :: proc(url: string) -> string {
	// Remove .git suffix if present
	url_clean := strings.trim_suffix(url, ".git")

	// Extract last component from URL
	parts := strings.split(url_clean, "/")
	defer delete(parts)

	if len(parts) > 0 {
		return strings.clone(parts[len(parts) - 1])
	}

	return ""
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

// Find plugin in JSON config by name (exact match first, then fuzzy with selection)
// Returns pointer to plugin in config array, or nil if not found
// If multiple matches above threshold, shows selection menu
find_plugin_json :: proc(config: ^PluginConfigJSON, name: string) -> (^PluginMetadata, bool) {
	// First try exact match by full name
	for &plugin in config.plugins {
		if plugin.name == name {
			return &plugin, true
		}
	}
	
	// Then try exact match by display name
	for &plugin in config.plugins {
		if plugin.display_name == name {
			return &plugin, true
		}
	}
	
	// Collect all fuzzy matches with scores
	matches := make([dynamic]PluginMatch, allocator = context.temp_allocator)
	
	for &plugin in config.plugins {
		// Check against full name
		score := fuzzy_match_score(plugin.name, name)
		
		// Check against display name
		if plugin.display_name != "" && plugin.display_name != plugin.name {
			dn_score := fuzzy_match_score(plugin.display_name, name)
			if dn_score > score {
				score = dn_score
			}
		}
		
		if score >= 50 {  // Minimum threshold for fuzzy match
			append(&matches, PluginMatch{plugin = &plugin, score = score})
		}
	}
	
	if len(matches) == 0 {
		return nil, false
	}
	
	// Sort by score descending
	slice.sort_by(matches[:], proc(a, b: PluginMatch) -> bool {
		return a.score > b.score
	})
	
	// If only one match, return it directly
	if len(matches) == 1 {
		return matches[0].plugin, true
	}
	
	// If best match has significantly higher score (20+ points), use it
	if len(matches) >= 2 && matches[0].score >= matches[1].score + 20 {
		return matches[0].plugin, true
	}
	
	// Multiple close matches - show selection menu (max 3 options)
	num_options := min(len(matches), 3)
	
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
		// User typed something
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

	for name, deg in in_degree {
		if deg == 0 {
			append(&ready, strings.clone(name))
		}
	}

	emitted := 0
	total_enabled := len(in_degree)

	for len(ready) > 0 {
		// Find the ready node with the lowest priority number
		best_idx := 0
		for i in 1..<len(ready) {
			if priority_map[ready[i]] < priority_map[ready[best_idx]] {
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

// Scan plugin for potential conflicts (exports, functions, aliases)
// Parses the plugin's entry file and populates ConflictInfo
scan_plugin_conflicts :: proc(plugin: ^PluginMetadata) -> bool {
	// Detect the entry file first
	entry_file, found := detect_plugin_file(plugin.installed_path, plugin.name, g_ctx.shell)

	// If no specific entry file found, return true (no conflicts to scan)
	if !found {
		return true
	}
	defer delete(entry_file)

	if !os.exists(entry_file) {
		return true
	}

	content, read_err := os.read_entire_file(entry_file, context.allocator)
	if read_err != nil {
		return false
	}
	defer delete(content)

	script := string(content)
	lines := strings.split_lines(script)
	defer delete(lines)

	// Clear existing conflict data
	delete(plugin.conflicts.env_vars)
	delete(plugin.conflicts.functions)
	delete(plugin.conflicts.aliases_)
	plugin.conflicts.env_vars = make([dynamic]string)
	plugin.conflicts.functions = make([dynamic]string)
	plugin.conflicts.aliases_ = make([dynamic]string)

	// Scan for exports, functions, and aliases
	for line in lines {
		trimmed := strings.trim_space(line)

		// Skip comments and empty lines
		if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") {
			continue
		}

		// Check for exports: export VAR=value
		if strings.has_prefix(trimmed, "export ") {
			after_export := trimmed[7:]  // Skip "export "
			parts := strings.split(after_export, "=")
			if len(parts) >= 1 {
				var_name := strings.trim_space(parts[0])
				if len(var_name) > 0 {
					append(&plugin.conflicts.env_vars, strings.clone(var_name))
				}
			}
			delete(parts)
		}

		// Check for functions (bash/zsh syntax)
		// Pattern 1: function name() {
		// Pattern 2: name() {
		if strings.contains(trimmed, "()") {
			func_name := ""

			if strings.has_prefix(trimmed, "function ") {
				// Pattern: function name() {
				after_function := trimmed[9:]  // Skip "function "
				paren_idx := strings.index(after_function, "(")
				if paren_idx > 0 {
					func_name = strings.trim_space(after_function[:paren_idx])
				}
			} else {
				// Pattern: name() {
				paren_idx := strings.index(trimmed, "()")
				if paren_idx > 0 {
					func_name = strings.trim_space(trimmed[:paren_idx])
				}
			}

			if len(func_name) > 0 {
				append(&plugin.conflicts.functions, strings.clone(func_name))
			}
		}

		// Check for aliases: alias name=value
		if strings.has_prefix(trimmed, "alias ") {
			after_alias := trimmed[6:]  // Skip "alias "
			parts := strings.split(after_alias, "=")
			if len(parts) >= 1 {
				alias_name := strings.trim_space(parts[0])
				if len(alias_name) > 0 {
					append(&plugin.conflicts.aliases_, strings.clone(alias_name))
				}
			}
			delete(parts)
		}
	}

	return true
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
		delete(plugin.conflicts.conflicting_plugins)
		plugin.conflicts.conflicting_plugins = make([dynamic]string)
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

// Resolve plugin name or URL to PluginInfo
resolve_plugin :: proc(name_or_url: string) -> (PluginInfo, bool) {
	// Check if it's a URL
	if is_valid_git_url(name_or_url) {
		// Extract name from URL
		plugin_name := extract_plugin_name_from_url(name_or_url)

		return PluginInfo{
			name = plugin_name,
			url = name_or_url,
			shell = .BOTH, // Unknown shell compat for custom URLs
			description = "Custom plugin",
		}, true
	}

	// Check popular plugins registry (linear scan — 9 entries, no heap)
	if info, found := popular_plugin_find(name_or_url); found {
		return info, true
	}

	return PluginInfo{}, false
}

// Get remote commit SHA for a git repository
// Returns short SHA (7 chars) or empty string on failure
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

	// Return short SHA (first 7 chars) — ALLOCATED, caller must delete
	return strings.clone(full_sha[0:min(7, len(full_sha))])
}


// ============================================================================
// CLI command handlers (merged from plugin_operations.odin)
// ============================================================================




// Handle plugin check command - check for available updates
// CLI-only command (no interactive mode)
// Checks all enabled plugins for updates using git ls-remote
handle_plugin_check :: proc(args: []string) {
	// Read plugin configuration
	config, ok := read_plugin_config_json()
	if !ok {
		os.exit(EXIT_CONFIG)
	}
	defer cleanup_plugin_config_json(&config)

	// Handle empty plugin list (non-error case)
	if len(config.plugins) == 0 {
		print_info("No plugins installed")
		fmt.println()
		fmt.println("Run 'wayu plugin add <name>' to install a plugin")
		return
	}

	// Display header
	print_header("Checking Plugin Updates", EMOJI_COMMAND)
	fmt.println()

	updates_available := false
	check_count := 0

	// Check each enabled plugin
	for &plugin in config.plugins {
		// Skip disabled plugins
		if !plugin.enabled {
			continue
		}

		check_count += 1
		fmt.printfln("Checking %s...", plugin.name)

		// Fetch remote commit SHA
		// NOTE: get_remote_commit returns an allocated string — must delete explicitly.
		// defer inside a loop defers to function exit (not iteration end), so we use
		// a plain delete at the bottom of the loop body instead.
		remote_commit := get_remote_commit(plugin.url, plugin.git.branch)
		if remote_commit == "" {
			print_warning("  ⚠ Failed to check remote (network error or invalid URL)")
			continue
		}

		// Update metadata with remote commit and timestamp
		delete(plugin.git.remote_commit)  // Clean up old value
		plugin.git.remote_commit = strings.clone(remote_commit)

		delete(plugin.git.last_checked)  // Clean up old timestamp
		plugin.git.last_checked = get_iso8601_timestamp()  // ALLOCATED

		// Compare local vs remote commits
		if plugin.git.commit != remote_commit {
			// Truncate to 7 chars for display
			local_short := plugin.git.commit[0:min(7, len(plugin.git.commit))]
			remote_short := remote_commit[0:min(7, len(remote_commit))]

			print_success("  ↑ Update available: %s → %s", local_short, remote_short)
			updates_available = true
		} else {
			print_info("  ✓ Up to date")
		}

		delete(remote_commit)  // Free per-iteration — not deferred (see note above)
	}

	fmt.println()

	// No enabled plugins to check
	if check_count == 0 {
		print_info("No enabled plugins to check")
		fmt.println()
		print_info("Enable plugins with: wayu --tui")
		return
	}

	// Save updated metadata (last_checked timestamps)
	if !g_ctx.dry_run {
		if !write_plugin_config_json(&config) {
			print_error_simple("Failed to save plugin metadata")
			os.exit(EXIT_CONFIG)
		}
	} else {
		print_info("[DRY RUN] Would save updated metadata")
	}

	// Display summary
	if updates_available {
		fmt.println()
		print_info("Updates available! Run one of:")
		fmt.println("  wayu plugin update <name>      # Update specific plugin")
		fmt.println("  wayu plugin update --all       # Update all plugins")
	} else {
		print_success("All plugins are up to date!")
	}
}

// Handle plugin update command - update plugins
// Supports both single plugin and --all flag
// CLI-only command (no interactive mode)
handle_plugin_update :: proc(args: []string) {
	// Require explicit argument (plugin name or --all)
	if len(args) == 0 {
		print_error("Missing required argument: plugin name or --all")
		fmt.println()
		fmt.println("Usage:")
		fmt.println("  wayu plugin update <name>      # Update specific plugin")
		fmt.println("  wayu plugin update --all       # Update all plugins")
		fmt.println()
		fmt.printfln("%sExample:%s", get_muted(), RESET)
		fmt.printfln("  %swayu plugin update zsh-autosuggestions%s", get_muted(), RESET)
		os.exit(EXIT_USAGE)
	}

	update_all := args[0] == "--all" || args[0] == "-a"

	// Read plugin configuration
	config, ok := read_plugin_config_json()
	if !ok {
		os.exit(EXIT_CONFIG)
	}
	defer cleanup_plugin_config_json(&config)

	// Handle empty plugin list
	if len(config.plugins) == 0 {
		print_info("No plugins installed")
		fmt.println()
		fmt.println("Run 'wayu plugin add <name>' to install a plugin")
		return
	}

	// Display header
	if update_all {
		print_header("Updating All Plugins", EMOJI_COMMAND)
	} else {
		print_header("Updating Plugin", EMOJI_COMMAND)
	}
	fmt.println()

	updated_count := 0

	// Update specific plugin
	if !update_all {
		plugin_name := args[0]

		// Find plugin (with fuzzy fallback)
		plugin_ptr, found := find_plugin_json(&config, plugin_name)
		
		if !found {
			print_error_simple("Plugin '%s' not found", plugin_name)
			fmt.println()
			fmt.println("Run 'wayu plugin list' to see installed plugins")
			os.exit(EXIT_DATAERR)
		}

		// Perform update
		print_info("Updating %s...", plugin_ptr.name)

		// Show spinner for long operation
		spinner := new_spinner(.Dots)
		spinner_text(&spinner, fmt.aprintf("Updating %s", plugin_ptr.name))
		spinner_start(&spinner)

		success := git_update(plugin_ptr.installed_path)

		spinner_stop(&spinner)

		if !success {
			print_error_simple("Failed to update plugin")
			os.exit(EXIT_IOERR)
		}

		// Refresh git metadata after update
		new_git_info := get_git_info(plugin_ptr.installed_path)

		// Clean up old git metadata
		delete(plugin_ptr.git.branch)
		delete(plugin_ptr.git.commit)
		delete(plugin_ptr.git.last_checked)
		delete(plugin_ptr.git.remote_commit)

		// Assign new metadata
		plugin_ptr.git = new_git_info

		print_success("Plugin '%s' updated successfully", plugin_ptr.name)
		updated_count = 1
	} else {
		// Update all plugins
		for &plugin in config.plugins {
			// Skip disabled plugins
			if !plugin.enabled {
				continue
			}

			print_info("Updating %s...", plugin.name)

			// Perform update
			success := git_update(plugin.installed_path)

			if !success {
				print_warning("  ⚠ Failed to update plugin")
				continue
			}

			// Refresh git metadata
			new_git_info := get_git_info(plugin.installed_path)

			// Clean up old git metadata
			delete(plugin.git.branch)
			delete(plugin.git.commit)
			delete(plugin.git.last_checked)
			delete(plugin.git.remote_commit)

			// Assign new metadata
			plugin.git = new_git_info

			print_success("  ✓ Updated")
			updated_count += 1
		}
	}

	fmt.println()

	// Save updated metadata
	if !g_ctx.dry_run {
		// Create backup before writing
		config_file := get_plugins_json_config_file()
		defer delete(config_file)

		if os.exists(config_file) {
			backup_path, backup_ok := create_backup(config_file)
			if backup_ok {
				defer delete(backup_path)
			} else {
				print_warning("Warning: Failed to create backup")
			}
		}

		// Write updated config
		if !write_plugin_config_json(&config) {
			print_error_simple("Failed to save plugin metadata")
			os.exit(EXIT_CONFIG)
		}
	} else {
		print_info("[DRY RUN] Would save updated metadata")
	}

	// Summary
	if updated_count == 0 {
		print_info("No plugins updated")
	} else if updated_count == 1 {
		print_success("1 plugin updated")
	} else {
		print_success("%d plugins updated", updated_count)
	}

	// Regenerate plugins loader file for current shell
	if !g_ctx.dry_run {
		if !generate_plugins_file(g_ctx.shell) {
			print_warning("Warning: Failed to regenerate plugins loader")
		}
	}

	fmt.println()
	print_info("Restart your shell or run 'source ~/.%src' to reload plugins", g_ctx.shell_ext)
}

// Shared implementation for enable/disable plugin commands
// Sets enabled state in plugins.json and regenerates shell loader
// Idempotent: Setting a plugin to its current state returns EXIT_SUCCESS
// Per-direction verb forms used by the user-facing messaging in
// handle_plugin_set_enabled. Groups the five conjugations of enable/disable
// into a single struct so the proc body doesn't fan out across ten if-else
// ternaries. See thoughts/code_review_2026-04-24.md N7.
PluginVerbForms :: struct {
	word:   string, // "enable" (imperative / flag name)
	Word:   string, // "Enable" (sentence-start)
	ing:    string, // "Enabling"
	past:   string, // "enabled"
	header: string, // "Enabling Plugin" (used as section header)
}

PLUGIN_VERBS := [2]PluginVerbForms{
	{"disable", "Disable", "Disabling", "disabled", "Disabling Plugin"},
	{"enable",  "Enable",  "Enabling",  "enabled",  "Enabling Plugin"},
}

handle_plugin_set_enabled :: proc(args: []string, enable: bool) {
	v := PLUGIN_VERBS[enable ? 1 : 0]
	action_word     := v.word
	action_word_cap := v.Word
	action_ing      := v.ing
	action_past     := v.past
	header_text     := v.header

	// 1. Validate arguments
	if len(args) == 0 {
		print_error("Missing required argument: plugin name")
		fmt.println()
		fmt.printfln("Usage: wayu plugin %s <name>", action_word)
		fmt.println()
		fmt.println("Example:")
		fmt.printfln("  wayu plugin %s zsh-autosuggestions", action_word)
		fmt.println()
		fmt.printfln("%sHint:%s For interactive selection, use: %swayu --tui%s",
			get_muted(), RESET, get_primary(), RESET)
		os.exit(EXIT_USAGE)
	}

	plugin_name := args[0]

	// 2. Read plugin configuration
	config, ok := read_plugin_config_json()
	if !ok {
		os.exit(EXIT_CONFIG)
	}

	// 3. Find plugin by name (with fuzzy fallback)
	plugin_ptr, found := find_plugin_json(&config, plugin_name)
	
	if !found {
		cleanup_plugin_config_json(&config)
		print_error_simple("Plugin '%s' not found", plugin_name)
		fmt.println()
		fmt.println("Run 'wayu plugin list' to see installed plugins")
		os.exit(EXIT_DATAERR)
	}

	// 4. Check if already in target state (idempotent operation)
	if plugin_ptr.enabled == enable {
		cleanup_plugin_config_json(&config)
		print_info("Plugin '%s' is already %s", plugin_name, action_past)
		os.exit(EXIT_SUCCESS)  // NOT an error - idempotent
	}

	// Display header
	print_header(header_text, EMOJI_COMMAND)
	fmt.println()

	// 5. Create backup before modifying
	config_file := get_plugins_json_config_file()

	if os.exists(config_file) {
		backup_path, backup_ok := create_backup(config_file)
		if backup_ok {
			delete(backup_path)
		} else {
			print_warning("Warning: Failed to create backup")
		}
	}

	// 6. Set plugin enabled state
	plugin_ptr.enabled = enable

	// 7. Write updated configuration
	if !g_ctx.dry_run {
		if !write_plugin_config_json(&config) {
			delete(config_file)
			cleanup_plugin_config_json(&config)
			print_error_simple("Failed to save plugin configuration")
			os.exit(EXIT_CONFIG)
		}
	} else {
		print_info("[DRY RUN] Would save updated configuration")
	}

	// 8. Regenerate shell loader
	if !g_ctx.dry_run {
		if !generate_plugins_file(g_ctx.shell) {
			delete(config_file)
			cleanup_plugin_config_json(&config)
			print_error_simple("Failed to regenerate plugins loader")
			os.exit(EXIT_IOERR)
		}
	} else {
		print_info("[DRY RUN] Would regenerate shell loader")
	}

	// 9. Success
	delete(config_file)
	cleanup_plugin_config_json(&config)
	print_success("Plugin '%s' %s successfully", plugin_name, action_past)
	fmt.println()

	if enable {
		fmt.printfln("%sThe plugin will be loaded in new shell sessions.%s", BRIGHT_CYAN, RESET)
	} else {
		fmt.printfln("%sThe plugin will not be loaded in new shell sessions.%s", BRIGHT_CYAN, RESET)
	}
	fmt.printfln("Restart your shell or run 'source ~/.%src' to apply changes.", g_ctx.shell_ext)

	if !enable {
		fmt.println()
		fmt.printfln("%sTo re-enable:%s wayu plugin enable %s", get_muted(), RESET, plugin_name)
	}

	os.exit(EXIT_SUCCESS)
}

// Handle plugin enable command - enable a disabled plugin
// Sets enabled: true in plugins.json and regenerates shell loader
// CLI-only command (no interactive mode)
// Idempotent: Enabling an already-enabled plugin returns EXIT_SUCCESS
handle_plugin_enable :: proc(args: []string) {
	handle_plugin_set_enabled(args, true)
}

// Handle plugin disable command - disable an enabled plugin
// Sets enabled: false in plugins.json and regenerates shell loader
// CLI-only command (no interactive mode)
// Plugin remains installed, only prevents loading on shell startup
// Idempotent: Disabling an already-disabled plugin returns EXIT_SUCCESS
handle_plugin_disable :: proc(args: []string) {
	handle_plugin_set_enabled(args, false)
}

// Handle plugin priority command - set plugin load priority
// Lower priority numbers load first (default: 100)
// CLI-only command (no interactive mode)
handle_plugin_priority :: proc(args: []string) {
	// 1. Validate arguments
	if len(args) < 2 {
		print_error("Missing required arguments: plugin name and priority")
		fmt.println()
		fmt.println("Usage: wayu plugin priority <name> <number>")
		fmt.println()
		fmt.println("  Lower numbers load first (default: 100)")
		fmt.println()
		fmt.println("Example:")
		fmt.println("  wayu plugin priority zsh-autosuggestions 50")
		os.exit(EXIT_USAGE)
	}

	plugin_name := args[0]
	priority_str := args[1]

	// 2. Parse priority number
	priority, ok := strconv.parse_int(priority_str)
	if !ok {
		print_error_simple("Invalid priority number '%s'", priority_str)
		fmt.println()
		fmt.println("Priority must be a valid integer")
		os.exit(EXIT_USAGE)
	}

	// 3. Read config
	config, read_ok := read_plugin_config_json()
	if !read_ok {
		os.exit(EXIT_CONFIG)
	}
	defer cleanup_plugin_config_json(&config)

	// 4. Find plugin
	plugin, found := find_plugin_json(&config, plugin_name)
	if !found {
		print_error_simple("Plugin '%s' not found", plugin_name)
		fmt.println()
		fmt.println("Use 'wayu plugin list' to see installed plugins")
		os.exit(EXIT_DATAERR)
	}

	if g_ctx.dry_run {
		print_info("[DRY RUN] Would set priority of '%s' to %d (current: %d)",
			plugin_name, priority, plugin.priority)
		return
	}

	// Display header
	print_header("Setting Plugin Priority", EMOJI_COMMAND)
	fmt.println()

	old_priority := plugin.priority
	plugin.priority = priority

	// 5. Create backup before modifying
	config_file := get_plugins_json_config_file()
	defer delete(config_file)

	if os.exists(config_file) {
		backup_path, backup_ok := create_backup(config_file)
		if backup_ok {
			defer delete(backup_path)
		} else {
			print_warning("Warning: Failed to create backup")
		}
	}

	// 6. Save config
	if !write_plugin_config_json(&config) {
		print_error_simple("Failed to save configuration")
		os.exit(EXIT_CANTCREAT)
	}

	// 7. Regenerate loader (load order changed)
	if !generate_plugins_file(g_ctx.shell) {
		print_warning("Warning: Failed to regenerate plugin loader")
		// Don't exit - config was saved successfully
	}

	// 8. Success
	print_success("Updated priority for '%s': %d → %d", plugin_name, old_priority, priority)
	fmt.println()
	fmt.println("Restart your shell for changes to take effect")
}

// Command handlers

// Handle plugin add command
handle_plugin_add :: proc(args: []string) {
	if len(args) == 0 {
		print_error_simple("Plugin name or URL required")
		print_plugin_add_help()
		os.exit(EXIT_USAGE)
	}

	name_or_url := args[0]

	// Resolve plugin
	info, resolved := resolve_plugin(name_or_url)
	if !resolved {
		print_error_simple("Unknown plugin '%s'", name_or_url)
		fmt.println("\nRun 'wayu plugin search' to see available plugins")
		os.exit(EXIT_DATAERR)
	}
	defer delete(info.name)
	defer delete(info.url)
	defer delete(info.description)

	// Read current config
	config, ok := read_plugin_config_json()
	if !ok {
		print_error_simple("Failed to read plugin configuration")
		os.exit(EXIT_CONFIG)
	}
	defer cleanup_plugin_config_json(&config)

	// Check if already installed
	_, found := find_plugin_json(&config, info.name)
	if found {
		print_warning("Plugin '%s' is already installed", info.name)
		os.exit(EXIT_SUCCESS)
	}

	print_header("Installing Plugin", EMOJI_COMMAND)
	print_info("Name: %s", info.name)
	print_info("URL: %s", info.url)
	print_info("Shell: %s", shell_compat_to_string(info.shell))
	fmt.println()

	// Create plugins directory if it doesn't exist
	plugins_dir := get_plugins_dir()
	defer delete(plugins_dir)

	if !os.exists(plugins_dir) && !g_ctx.dry_run {
		err := os.make_directory(plugins_dir)
		if err != nil {
			print_error_simple("Failed to create plugins directory: %v", err)
			os.exit(EXIT_CANTCREAT)
		}
	}

	// Clone repository
	plugin_path := fmt.aprintf("%s/%s", plugins_dir, info.name)
	defer delete(plugin_path)

	spinner := new_spinner(.Dots)
	spinner_text(&spinner, "Cloning repository")
	spinner_start(&spinner)

	success := git_clone(info.url, plugin_path)

	spinner_stop(&spinner)

	if !success {
		print_error_simple("Failed to clone plugin repository")
		os.exit(EXIT_OSERR)
	}

	print_success("Cloned plugin repository")

	// Add to config
	git_info := get_git_info(plugin_path)

	new_plugin := PluginMetadata{
		name = strings.clone(info.name),
		display_name = strings.clone(info.name),
		url = strings.clone(info.url),
		source_type = .GitHub,  // Default source
		enabled = true,
		shell = info.shell,
		installed_path = strings.clone(plugin_path),
		entry_file = "",  // Will be detected by generate_plugins_file
		use = make([dynamic]string),  // Empty = auto-detect
		template = .Source,  // Default loading template
		git = git_info,
		dependencies = make([dynamic]string),  // Phase 4: Initialize empty
		priority = 100,  // Phase 5: Default priority
		profiles = make([dynamic]string),  // Empty = all profiles
		conflicts = ConflictInfo{},  // Phase 6: No conflicts yet
	}

	append(&config.plugins, new_plugin)

	// Phase 4: Validate no circular dependencies before writing config
	if !validate_no_circular_dependencies(&config) {
		os.exit(EXIT_DATAERR)
	}

	// Create backup before writing
	if !g_ctx.dry_run {
		config_file := get_plugins_json_config_file()
		defer delete(config_file)

		if os.exists(config_file) {
			backup_path, backup_ok := create_backup(config_file)
			if backup_ok {
				defer delete(backup_path)
			}
		}
	}

	// Write config
	if !write_plugin_config_json(&config) {
		print_error_simple("Failed to write plugin configuration")
		os.exit(EXIT_IOERR)
	}

	// Generate plugins file for current shell
	if !generate_plugins_file(g_ctx.shell) {
		print_error_simple("Failed to generate plugins loader")
		os.exit(EXIT_IOERR)
	}

	print_success("Plugin '%s' installed successfully", info.name)
	fmt.println()
	print_info("Restart your shell or run 'source ~/.%src' to load the plugin", g_ctx.shell_ext)
}

// Emit the plugin list as structured JSON. Shape:
//   { "plugins": [ {"name": ..., "enabled": bool, "priority": N,
//                   "shell": "zsh|bash|both|fish|any", "url": ...,
//                   "commit": ..., "installed_path": ...}, ... ],
//     "count": N, "enabled": M }
print_plugins_json :: proc(config: ^PluginConfigJSON) {
	enabled_count := 0
	for plugin in config.plugins {
		if plugin.enabled { enabled_count += 1 }
	}

	fmt.println("{")
	fmt.println(`  "plugins": [`)

	for plugin, i in config.plugins {
		if i > 0 { fmt.println(",") }
		enabled_str := plugin.enabled ? "true" : "false"
		// `{` is a struct-verb opener in Odin's fmt — emit via %c.
		fmt.printf(
			"    %c\"name\": \"%s\", \"enabled\": %s, \"priority\": %d, \"shell\": \"%s\", \"url\": \"%s\", \"commit\": \"%s\", \"installed_path\": \"%s\"%c",
			'{',
			plugin.name,
			enabled_str,
			plugin.priority,
			shell_compat_to_string(plugin.shell),
			plugin.url,
			plugin.git.commit,
			plugin.installed_path,
			'}',
		)
	}

	fmt.println()
	fmt.println("  ],")
	fmt.printfln("  \"count\": %d,", len(config.plugins))
	fmt.printfln("  \"enabled\": %d", enabled_count)
	fmt.println("}")
}

// Handle plugin list command
handle_plugin_list :: proc(args: []string) {
	// Run migration if needed
	if !migrate_plugin_config() {
		os.exit(EXIT_CONFIG)
	}

	// Use JSON5 config if it exists, otherwise fall back to old format
	json_file := get_plugins_json_config_file()
	defer delete(json_file)

	use_json := os.exists(json_file)

	if use_json {
		// Read from JSON5 config
		config, ok := read_plugin_config_json()
		if !ok {
			os.exit(EXIT_CONFIG)
		}
		defer cleanup_plugin_config_json(&config)

		if g_ctx.json_output {
			print_plugins_json(&config)
			return
		}

		if len(config.plugins) == 0 {
			print_info("No plugins installed")
			fmt.println("\nRun 'wayu plugin add <name>' to install a plugin")
			return
		}

		print_header("Installed Plugins", EMOJI_COMMAND)
		fmt.println()

		// Create table
		table := new_table([]string{"Name", "Status", "Priority", "Shell", "URL"})
		defer delete(table.rows)

		for plugin in config.plugins {
			status := plugin.enabled ? "✓ Active" : "○ Disabled"
			priority_str := fmt.aprintf("%d", plugin.priority)
			shell_str := shell_compat_to_string(plugin.shell)

			// Truncate URL for display
			url_display := plugin.url
			if len(url_display) > 40 {
				url_display = fmt.aprintf("%s...", plugin.url[:37])
			}

			row := []string{plugin.name, status, priority_str, shell_str, url_display}
			table_add_row(&table, row)
			delete(priority_str)

			if len(url_display) > 40 {
				delete(url_display)
			}
		}

		output := table_render(table, get_cli_terminal_width())
		defer delete(output)
		fmt.print(output)

		fmt.println()
		enabled_count := 0
		for plugin in config.plugins {
			if plugin.enabled {
				enabled_count += 1
			}
		}

		print_info("%d plugins installed (%d enabled)", len(config.plugins), enabled_count)
	} else {
		// Fall back to old format (for backward compatibility during transition)
		config := read_plugin_config()
		defer {
			for plugin in config.plugins {
				delete(plugin.name)
				delete(plugin.url)
				delete(plugin.installed_path)
				delete(plugin.entry_file)
			}
			delete(config.plugins)
		}

		if len(config.plugins) == 0 {
			print_info("No plugins installed")
			fmt.println("\nRun 'wayu plugin add <name>' to install a plugin")
			return
		}

		print_header("Installed Plugins", EMOJI_COMMAND)
		fmt.println()

		// Create table (old format fallback - priority defaults to 100)
		table := new_table([]string{"Name", "Status", "Priority", "Shell", "URL"})
		defer delete(table.rows)

		for plugin in config.plugins {
			status := plugin.enabled ? "✓ Active" : "○ Disabled"
			priority_str := fmt.aprintf("%d", 100)  // Old format doesn't have priority field
			shell_str := shell_compat_to_string(plugin.shell)

			// Truncate URL for display
			url_display := plugin.url
			if len(url_display) > 40 {
				url_display = fmt.aprintf("%s...", plugin.url[:37])
			}

			row := []string{plugin.name, status, priority_str, shell_str, url_display}
			table_add_row(&table, row)
			delete(priority_str)

			if len(url_display) > 40 {
				delete(url_display)
			}
		}

		output := table_render(table, get_cli_terminal_width())
		defer delete(output)
		fmt.print(output)

		fmt.println()
		enabled_count := 0
		for plugin in config.plugins {
			if plugin.enabled {
				enabled_count += 1
			}
		}

		print_info("%d plugins installed (%d enabled)", len(config.plugins), enabled_count)
	}
}

// Handle plugin remove command
handle_plugin_remove :: proc(args: []string) {
	// Read plugin configuration
	config, ok := read_plugin_config_json()
	if !ok {
		print_error_simple("Failed to read plugin configuration")
		os.exit(EXIT_CONFIG)
	}
	defer cleanup_plugin_config_json(&config)

	if len(config.plugins) == 0 {
		print_info("No plugins installed")
		return
	}

	// Require explicit plugin name (no interactive selection in CLI)
	if len(args) == 0 {
		print_error("Missing required argument: plugin name")
		fmt.println()
		fmt.println("Usage: wayu plugin rm <name>")
		fmt.println()
		fmt.println("Example:")
		fmt.println("  wayu plugin rm syntax-highlighting")
		fmt.println()
		fmt.printfln("%sHint:%s For interactive selection, use: %swayu --tui%s",
			get_muted(), RESET, get_primary(), RESET)
		os.exit(EXIT_USAGE)
	}

	plugin_name := args[0]

	// Find plugin
	plugin_ptr, found := find_plugin_json(&config, plugin_name)
	if !found {
		cleanup_plugin_config_json(&config)
		print_info("Plugin '%s' not found (already removed)", plugin_name)
		os.exit(EXIT_SUCCESS)
	}

	// Phase 1: Check for --yes flag (required for all removals)
	// Check this BEFORE showing details to ensure consistent behavior
	if !g_ctx.yes_flag {
		print_error("This operation requires confirmation.")
		fmt.println()
		print_info("Plugin to remove: %s", plugin_name)
		fmt.printfln("  Path: %s", plugin_ptr.installed_path)
		fmt.println()

		// Phase 2: Check if other plugins depend on this one
		dependents := check_plugin_dependents(plugin_name, &config)

		if len(dependents) > 0 {
			print_warning("Warning: The following plugins depend on '%s':", plugin_name)
			for dep in dependents {
				fmt.printfln("  - %s", dep)
			}
			fmt.println()
			print_warning("Removing this plugin may break these plugins.")
			fmt.println()
		}

		delete(dependents)  // Clean up before exit
		fmt.printfln("Add --yes flag to proceed:")
		fmt.printfln("  wayu plugin rm %s --yes", plugin_name)
		os.exit(EXIT_USAGE)
	}

	// Phase 3: Check for dependents (warning only since --yes was provided)
	dependents := check_plugin_dependents(plugin_name, &config)
	defer delete(dependents)

	if len(dependents) > 0 {
		print_warning("Warning: The following plugins depend on '%s':", plugin_name)
		for dep in dependents {
			fmt.printfln("  - %s", dep)
		}
		fmt.println()
		print_warning("Removing this plugin may break these plugins.")
		fmt.println()
	}

	print_header("Removing Plugin", EMOJI_COMMAND)
	print_info("Name: %s", plugin_ptr.name)
	fmt.println()

	// Remove plugin directory
	if os.exists(plugin_ptr.installed_path) && !g_ctx.dry_run {
		remove_err := os.remove_all(plugin_ptr.installed_path)
		if remove_err != nil {
			print_error_simple("Failed to remove plugin directory")
			os.exit(EXIT_IOERR)
		}
	}

	print_success("Removed plugin directory")

	// Remove from config
	new_plugins := make([dynamic]PluginMetadata)
	defer delete(new_plugins)

	for &plugin in config.plugins {
		if plugin.name != plugin_name {
			append(&new_plugins, plugin)
		} else {
			// Clean up memory for removed plugin
			cleanup_plugin_metadata(&plugin)
		}
	}

	config.plugins = new_plugins

	// Create backup before writing
	if !g_ctx.dry_run {
		config_file := get_plugins_json_config_file()
		defer delete(config_file)

		if os.exists(config_file) {
			backup_path, backup_ok := create_backup(config_file)
			if backup_ok {
				defer delete(backup_path)
			}
		}
	}

	// Write config
	if !write_plugin_config_json(&config) {
		print_error_simple("Failed to write plugin configuration")
		os.exit(EXIT_IOERR)
	}

	// Generate plugins file
	if !generate_plugins_file(g_ctx.shell) {
		print_error_simple("Failed to generate plugins loader")
		os.exit(EXIT_IOERR)
	}

	print_success("Plugin '%s' removed successfully", plugin_name)
}

// Handle plugin get command - display plugin info and copy URL to clipboard
handle_plugin_get :: proc(args: []string) {
	if len(args) == 0 {
		print_error_simple("Plugin name required")
		fmt.println("\nUsage: wayu plugin get <name>")
		os.exit(EXIT_USAGE)
	}

	plugin_name := args[0]

	// Read current config (JSON format)
	config, ok := read_plugin_config_json()
	if !ok {
		print_error_simple("Failed to read plugin configuration")
		os.exit(EXIT_CONFIG)
	}
	defer cleanup_plugin_config_json(&config)

	// Find plugin
	plugin_ptr, found := find_plugin_json(&config, plugin_name)
	if !found {
		print_error_simple("Plugin '%s' not found", plugin_name)
		fmt.println("\nRun 'wayu plugin list' to see installed plugins")
		os.exit(EXIT_DATAERR)
	}

	// Display plugin information
	print_header("Plugin Information", EMOJI_COMMAND)
	fmt.println()

	// Create table with plugin details
	table := new_table([]string{"Property", "Value"})
	defer delete(table.rows)

	table_add_row(&table, []string{"Name", plugin_ptr.name})
	table_add_row(&table, []string{"URL", plugin_ptr.url})
	table_add_row(&table, []string{"Status", plugin_ptr.enabled ? "✓ Enabled" : "○ Disabled"})
	table_add_row(&table, []string{"Shell", shell_compat_to_string(plugin_ptr.shell)})
	table_add_row(&table, []string{"Path", plugin_ptr.installed_path})

	output := table_render(table, get_cli_terminal_width())
	defer delete(output)
	fmt.print(output)

	fmt.println()

	// Copy URL to clipboard — write URL to stdin of clipboard command (no shell)
	if !g_ctx.dry_run {
		clipboard_ok := false
		when ODIN_OS == .Darwin {
			// macOS: pbcopy reads from stdin
			clipboard_ok = run_command_with_stdin([]string{"pbcopy"}, plugin_ptr.url)
		} else when ODIN_OS == .Linux {
			// Linux: try xclip first, fall back to xsel
			clipboard_ok = run_command_with_stdin(
				[]string{"xclip", "-selection", "clipboard"}, plugin_ptr.url)
			if !clipboard_ok {
				clipboard_ok = run_command_with_stdin(
					[]string{"xsel", "--clipboard", "--input"}, plugin_ptr.url)
			}
		} else when ODIN_OS == .Windows {
			// Windows: clip reads from stdin
			clipboard_ok = run_command_with_stdin([]string{"clip"}, plugin_ptr.url)
		}

		if clipboard_ok {
			print_success("URL copied to clipboard: %s", plugin_ptr.url)
		} else {
			print_warning("Failed to copy URL to clipboard")
			print_info("URL: %s", plugin_ptr.url)
		}
	} else {
		print_info("[DRY RUN] Would copy URL to clipboard: %s", plugin_ptr.url)
	}
}

// Search the built-in popular plugins registry.
//
// Usage:
//   wayu plugin search                       – list all 55 entries
//   wayu plugin search <query>               – filter by name/key/description/category
//   wayu plugin search --category <cat>      – show only a specific category
//
// Recognized categories: syntax, completion, navigation, git, history,
//   prompt, productivity, tools, utility
handle_plugin_search :: proc(args: []string) {
	// Parse --category flag and free-text query from args.
	// Supported forms:
	//   search git
	//   search --category git
	//   search --category=git
	query:    string
	category: string

	i := 0
	for i < len(args) {
		arg := args[i]
		if strings.has_prefix(arg, "--category=") {
			category = strings.to_lower(arg[len("--category="):])
			i += 1
		} else if arg == "--category" || arg == "-c" {
			if i + 1 < len(args) {
				category = strings.to_lower(args[i + 1])
				i += 2
			} else {
				print_error_simple("--category requires a value")
				os.exit(EXIT_USAGE)
			}
		} else {
			query = strings.to_lower(arg)
			i += 1
		}
	}
	defer if len(query)    > 0 { delete(query) }
	defer if len(category) > 0 { delete(category) }

	print_header("Popular Plugins", EMOJI_COMMAND)
	fmt.println()

	table := new_table([]string{"Key", "Category", "Shell", "Description"})
	defer delete(table.rows)

	matched := 0
	for entry in POPULAR_PLUGINS {
		info := entry.info

		// Category filter (exact match on category field).
		if len(category) > 0 && entry.category != category {
			continue
		}

		// Free-text filter: key, name, description, or category substring.
		if len(query) > 0 {
			key_lower  := strings.to_lower(entry.key)
			name_lower := strings.to_lower(info.name)
			desc_lower := strings.to_lower(info.description)
			cat_lower  := strings.to_lower(entry.category)
			defer delete(key_lower)
			defer delete(name_lower)
			defer delete(desc_lower)
			defer delete(cat_lower)

			if !strings.contains(key_lower,  query) &&
			   !strings.contains(name_lower, query) &&
			   !strings.contains(desc_lower, query) &&
			   !strings.contains(cat_lower,  query) {
				continue
			}
		}

		shell_str := shell_compat_to_string(info.shell)
		table_add_row(&table, []string{entry.key, entry.category, shell_str, info.description})
		matched += 1
	}

	if matched == 0 {
		if len(category) > 0 {
			fmt.printfln("No plugins found in category %q", category)
			fmt.println()
			fmt.println("Categories: syntax, completion, navigation, git, history, prompt, productivity, tools, utility")
		} else {
			fmt.printfln("No plugins found matching %q", query)
			fmt.println()
			fmt.println("Run 'wayu plugin search' to list all popular plugins.")
		}
		return
	}

	output := table_render(table, get_cli_terminal_width())
	defer delete(output)
	fmt.print(output)

	fmt.println()
	fmt.printfln("%sTo install:%s wayu plugin add <key>", get_muted(), RESET)
	fmt.printfln("%sFilter by category:%s wayu plugin search --category <cat>", get_muted(), RESET)
}

