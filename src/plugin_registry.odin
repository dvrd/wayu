package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:c/libc"
import "core:slice"
import "core:encoding/json"

// Get plugins config file path
get_plugins_config_file :: proc() -> string {
	return fmt.aprintf("%s/plugins.conf", WAYU_CONFIG)
}

// Get plugins JSON config file path
get_plugins_json_config_file :: proc() -> string {
	return fmt.aprintf("%s/plugins.json", WAYU_CONFIG)
}

// Get plugins directory path
get_plugins_dir :: proc() -> string {
	return fmt.aprintf("%s/plugins", WAYU_CONFIG)
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
	config_file := get_plugins_json_config_file()
	defer delete(config_file)

	if !os.exists(config_file) {
		// Return empty config on first run
		config.version = "1.0"
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
	validate_no_circular_dependencies(&config)

	return config, true
}

// Write JSON5 configuration file
write_plugin_config_json :: proc(config: ^PluginConfigJSON) -> bool {
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
			url = strings.clone(old_plugin.url),
			enabled = old_plugin.enabled,
			shell = old_plugin.shell,
			installed_path = strings.clone(old_plugin.installed_path),
			entry_file = strings.clone(old_plugin.entry_file),
			git = git_info,
			dependencies = make([dynamic]string),
			priority = 100, // Default priority
			config = make(map[string]string),
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
		print_error_simple("Error: Failed to write new configuration")
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
	// Validate inputs against shell injection
	if !is_safe_shell_arg(url) || !is_safe_shell_arg(dest) {
		print_error_simple("Error: URL or destination contains unsafe characters")
		return false
	}

	cmd := fmt.aprintf("git clone --depth=1 --quiet \"%s\" \"%s\" 2>&1", url, dest)
	defer delete(cmd)

	if DRY_RUN {
		print_info("[DRY RUN] Would execute: %s", cmd)
		return true
	}

	cmd_cstr := strings.clone_to_cstring(cmd)
	defer delete(cmd_cstr)

	result := libc.system(cmd_cstr)
	return result == 0
}

// Update plugin (git pull)
git_update :: proc(plugin_dir: string) -> bool {
	// Validate plugin_dir against shell injection
	if !is_safe_shell_arg(plugin_dir) {
		print_error_simple("Error: Plugin directory path contains unsafe characters")
		return false
	}

	cmd := fmt.aprintf("git -C \"%s\" pull --quiet 2>&1", plugin_dir)
	defer delete(cmd)

	if DRY_RUN {
		print_info("[DRY RUN] Would execute: %s", cmd)
		return true
	}

	cmd_cstr := strings.clone_to_cstring(cmd)
	defer delete(cmd_cstr)

	result := libc.system(cmd_cstr)
	return result == 0
}

// Check if directory is git repo
is_git_repo :: proc(dir: string) -> bool {
	git_dir := fmt.aprintf("%s/.git", dir)
	defer delete(git_dir)

	return os.exists(git_dir)
}

// Plugin file detection

// Detect plugin entry file to source
detect_plugin_file :: proc(plugin_dir: string, plugin_name: string, shell: ShellType) -> (string, bool) {
	ext := get_shell_extension(shell)

	// 1. Standard plugin file: {name}.plugin.{zsh,bash}
	plugin_file := fmt.aprintf("%s/%s.plugin.%s", plugin_dir, plugin_name, ext)
	if os.exists(plugin_file) {
		return plugin_file, true
	}
	delete(plugin_file)

	// 2. Simple naming: {name}.{zsh,bash}
	simple_file := fmt.aprintf("%s/%s.%s", plugin_dir, plugin_name, ext)
	if os.exists(simple_file) {
		return simple_file, true
	}
	delete(simple_file)

	// 3. Init file: init.{zsh,bash}
	init_file := fmt.aprintf("%s/init.%s", plugin_dir, ext)
	if os.exists(init_file) {
		return init_file, true
	}
	delete(init_file)

	// 4. Fallback: return directory (source all .{zsh,bash} files)
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

// Find plugin in JSON config by name
// Returns pointer to plugin in config array, or nil if not found
find_plugin_json :: proc(config: ^PluginConfigJSON, name: string) -> (^PluginMetadata, bool) {
	for &plugin in config.plugins {
		if plugin.name == name {
			return &plugin, true
		}
	}
	return nil, false
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

// Validate that plugin configuration has no circular dependencies
// Exits with error if circular dependency detected
validate_no_circular_dependencies :: proc(config: ^PluginConfigJSON) {
	// Build dependency graph
	graph := build_dependency_graph(config)
	defer {
		for _, deps in graph {
			delete(deps)
		}
		delete(graph)
	}

	// Detect cycles
	result := detect_circular_dependencies(graph)
	defer if result.has_cycle do delete(result.cycle_path)

	// If cycle found, print error and exit
	if result.has_cycle {
		cycle_str := strings.join(result.cycle_path[:], " → ")

		print_error("Circular dependency detected: %s", cycle_str)
		fmt.println()
		fmt.println("Circular dependencies prevent determining a valid plugin load order.")
		fmt.println()
		fmt.println("Suggestions:")
		fmt.println("  • Review the dependencies for these plugins")
		fmt.println("  • Remove the dependency that creates the cycle")
		fmt.println("  • Consider if all these dependencies are necessary")

		delete(cycle_str)  // Clean up before exit
		os.exit(EXIT_DATAERR)
	}
}

// Phase 5: Resolve dependencies with priority-based ordering
// Dependencies are resolved first (dependency order), then sorted by priority
// Returns plugins in load order: dependencies first, then by priority
resolve_dependencies_with_priority :: proc(config: ^PluginConfigJSON) -> (order: [dynamic]string, ok: bool) {
	// Build dependency graph
	graph := build_dependency_graph(config)
	defer {
		for _, edges in graph {
			delete(edges)
		}
		delete(graph)
	}

	// Topological sort with DFS (respects dependencies)
	visited := make(map[string]bool)
	defer delete(visited)

	temp_mark := make(map[string]bool)
	defer delete(temp_mark)

	order = make([dynamic]string)

	// Visit all enabled plugins
	for plugin in config.plugins {
		if !plugin.enabled {
			continue
		}

		if !dfs_visit_with_priority(plugin.name, &graph, &visited, &temp_mark, &order, config) {
			// Circular dependency detected
			delete(order)
			return order, false
		}
	}

	// Now sort by priority (stable sort preserves dependency order)
	// Create array of (name, priority) pairs for sorting
	PriorityPair :: struct {
		name: string,
		priority: int,
	}

	pairs := make([dynamic]PriorityPair)
	defer delete(pairs)

	// Build priority map first
	priority_map := make(map[string]int)
	defer delete(priority_map)

	for plugin in config.plugins {
		priority_map[plugin.name] = plugin.priority
	}

	// Create pairs array from order
	for name in order {
		pair := PriorityPair{
			name = name,
			priority = priority_map[name],
		}
		append(&pairs, pair)
	}

	// Stable sort pairs by priority
	slice.stable_sort_by(pairs[:], proc(a, b: PriorityPair) -> bool {
		return a.priority < b.priority
	})

	// Clean up old order strings before replacing
	for name in order {
		delete(name)
	}
	clear(&order)

	// Extract sorted names back into order array
	for pair in pairs {
		append(&order, strings.clone(pair.name))
	}

	return order, true
}

// Phase 5: DFS visit for topological sort with priority awareness
dfs_visit_with_priority :: proc(
	node: string,
	graph: ^map[string][dynamic]string,
	visited: ^map[string]bool,
	temp_mark: ^map[string]bool,
	order: ^[dynamic]string,
	config: ^PluginConfigJSON,
) -> bool {
	// Already processed
	if visited[node] {
		return true
	}

	// Cycle detection
	if temp_mark[node] {
		return false
	}

	temp_mark[node] = true

	// Visit dependencies first
	if deps, has_deps := graph[node]; has_deps {
		for dep in deps {
			if !dfs_visit_with_priority(dep, graph, visited, temp_mark, order, config) {
				return false
			}
		}
	}

	delete_key(temp_mark, node)
	visited[node] = true
	append(order, strings.clone(node))

	return true
}

// Phase 6: Conflict Detection

// Scan plugin for potential conflicts (exports, functions, aliases)
// Parses the plugin's entry file and populates ConflictInfo
scan_plugin_conflicts :: proc(plugin: ^PluginMetadata) -> bool {
	// Detect the entry file first
	entry_file, found := detect_plugin_file(plugin.installed_path, plugin.name, DETECTED_SHELL)

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
	// First, scan all enabled plugins for their declarations
	for &plugin in config.plugins {
		if !plugin.enabled {
			continue
		}

		scan_plugin_conflicts(&plugin)
	}

	// Now compare plugins pairwise to detect conflicts
	for i := 0; i < len(config.plugins); i += 1 {
		plugin_a := &config.plugins[i]

		if !plugin_a.enabled {
			continue
		}

		// Clear previous conflict tracking
		delete(plugin_a.conflicts.conflicting_plugins)
		plugin_a.conflicts.conflicting_plugins = make([dynamic]string)
		plugin_a.conflicts.detected = false

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

	// Check popular plugins registry
	if info, found := POPULAR_PLUGINS[name_or_url]; found {
		return info, true
	}

	return PluginInfo{}, false
}

// Get remote commit SHA for a git repository
// Returns short SHA (7 chars) or empty string on failure
// CRITICAL: Returned string is ALLOCATED - caller must delete()
get_remote_commit :: proc(url: string, branch: string) -> string {
	// Validate URL against shell injection
	if !is_safe_shell_arg(url) {
		print_error_simple("Error: URL contains unsafe characters")
		return ""
	}

	// Use HEAD if no branch specified
	branch_ref := branch != "" ? branch : "HEAD"

	// Validate branch ref against shell injection
	if !is_safe_shell_arg(branch_ref) {
		print_error_simple("Error: Branch name contains unsafe characters")
		return ""
	}

	// Build command: git ls-remote "<url>" "<branch>" 2>/dev/null | cut -f1
	// The '2>/dev/null' suppresses error output
	// The 'cut -f1' extracts just the commit SHA (first field)
	cmd := fmt.aprintf("git ls-remote \"%s\" \"%s\" 2>/dev/null | cut -f1", url, branch_ref)
	defer delete(cmd)

	// Execute and get full SHA (40 chars) or empty string
	full_sha := exec_command_output(cmd)  // ALLOCATED - must delete
	if full_sha == "" {
		return ""
	}

	// Extract short SHA (first 7 chars)
	// NOTE: Create new allocated string before deleting full_sha
	short_sha := strings.clone(full_sha[0:min(7, len(full_sha))])
	delete(full_sha)  // Clean up full SHA

	return short_sha  // Caller's responsibility to delete
}

