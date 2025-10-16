# PRP-15: Plugin System Enhancement - Implementation Plan

## Document Information
- **PRP Number**: PRP-15
- **Status**: Planning
- **Created**: 2025-10-16
- **Dependencies**: Plugin System Enhancement PRD
- **Related PRPs**: None

## Overview

Implementation plan for enhancing wayu's plugin management system with JSON5 configuration, update checking, enable/disable functionality, dependency management, load prioritization, and conflict detection.

## Implementation Phases

### Phase 1: JSON5 Configuration Foundation (2-3 days)

#### 1.1 New Data Structures

**File**: `src/plugin.odin`

Replace existing structures with enhanced versions:

```odin
// Enhanced plugin metadata with git tracking, dependencies, and conflicts
PluginMetadata :: struct {
    name:           string,
    url:            string,
    enabled:        bool,
    shell:          ShellCompat,
    installed_path: string,
    entry_file:     string,
    git:            GitMetadata,
    dependencies:   [dynamic]string,
    priority:       int,
    config:         map[string]string,
    conflicts:      ConflictInfo,
}

// Git metadata for update tracking
GitMetadata :: struct {
    branch:        string,           // Current branch (default: "master" or "main")
    commit:        string,            // Local commit SHA (short form)
    last_checked:  string,            // ISO 8601 timestamp of last update check
    remote_commit: string,            // Remote commit SHA (short form)
}

// Conflict detection information
ConflictInfo :: struct {
    env_vars:       [dynamic]string,  // Environment variables this plugin sets
    functions:      [dynamic]string,  // Functions this plugin defines
    aliases_:       [dynamic]string,  // Aliases this plugin creates (renamed to avoid keyword)
    detected:       bool,              // Whether conflicts were detected
    conflicting_plugins: [dynamic]string, // Names of plugins with conflicts
}

// Root configuration structure
PluginConfig :: struct {
    version:      string,
    last_updated: string,             // ISO 8601 timestamp
    plugins:      [dynamic]PluginMetadata,
}
```

#### 1.2 JSON5 Parsing and Marshalling

Add JSON5 operations using `core:encoding/json`:

```odin
import "core:encoding/json"

// Read JSON5 configuration file
read_plugin_config_json :: proc() -> (config: PluginConfig, ok: bool) {
    config_file := fmt.aprintf("%s/plugins.json", WAYU_CONFIG)
    defer delete(config_file)

    if !os.exists(config_file) {
        // Return empty config on first run
        config.version = "1.0"
        config.last_updated = get_iso8601_timestamp()
        config.plugins = make([dynamic]PluginMetadata)
        return config, true
    }

    data, read_ok := os.read_entire_file_from_filename(config_file)
    if !read_ok {
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

    return config, true
}

// Write JSON5 configuration file
write_plugin_config_json :: proc(config: ^PluginConfig) -> bool {
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

    config_file := fmt.aprintf("%s/plugins.json", WAYU_CONFIG)
    defer delete(config_file)

    write_ok := os.write_entire_file(config_file, data)
    if !write_ok {
        fmt.eprintln("Error: Failed to write plugins.json")
        return false
    }

    return true
}

// Helper: Get current timestamp in ISO 8601 format
get_iso8601_timestamp :: proc() -> string {
    // Odin's time package provides this
    now := time.now()
    return time.time_to_string(now) // Format: "2025-10-16T18:00:00Z"
}
```

#### 1.3 Migration from Old Format

Add migration function to convert `plugins.conf` to `plugins.json`:

```odin
// Migrate from old pipe-delimited format to JSON5
migrate_plugin_config :: proc() -> bool {
    old_file := fmt.aprintf("%s/plugins.conf", WAYU_CONFIG)
    defer delete(old_file)

    new_file := fmt.aprintf("%s/plugins.json", WAYU_CONFIG)
    defer delete(new_file)

    // Skip if new file exists or old file doesn't exist
    if os.exists(new_file) || !os.exists(old_file) {
        return true
    }

    fmt.println("Migrating plugins.conf to plugins.json...")

    // Read old config
    old_config := read_plugin_config() // Existing function

    // Convert to new format
    new_config := PluginConfig{
        version = "1.0",
        last_updated = get_iso8601_timestamp(),
        plugins = make([dynamic]PluginMetadata),
    }

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
        return false
    }

    // Backup old config
    backup_file := fmt.aprintf("%s.backup", old_file)
    defer delete(backup_file)

    os.rename(old_file, backup_file)

    fmt.println("✓ Migration complete! Old config backed up to plugins.conf.backup")
    return true
}

// Get git information for an installed plugin
get_git_info :: proc(plugin_dir: string) -> GitMetadata {
    info := GitMetadata{}

    if !os.exists(plugin_dir) {
        return info
    }

    // Get current branch
    branch_cmd := fmt.aprintf("git -C \"%s\" rev-parse --abbrev-ref HEAD 2>/dev/null", plugin_dir)
    defer delete(branch_cmd)
    info.branch = exec_command_output(branch_cmd)

    // Get local commit (short SHA)
    commit_cmd := fmt.aprintf("git -C \"%s\" rev-parse --short HEAD 2>/dev/null", plugin_dir)
    defer delete(commit_cmd)
    info.commit = exec_command_output(commit_cmd)

    // Remote commit will be fetched during check/update
    info.remote_commit = info.commit
    info.last_checked = get_iso8601_timestamp()

    return info
}

// Execute command and return trimmed output
exec_command_output :: proc(cmd: string) -> string {
    // Use temporary file for output
    temp_file := "/tmp/wayu_cmd_output.txt"
    full_cmd := fmt.aprintf("%s > %s 2>&1", cmd, temp_file)
    defer delete(full_cmd)

    cmd_cstr := strings.clone_to_cstring(full_cmd)
    defer delete(cmd_cstr)

    result := libc.system(cmd_cstr)

    if result != 0 {
        return ""
    }

    data, ok := os.read_entire_file_from_filename(temp_file)
    if !ok {
        return ""
    }
    defer delete(data)

    output := string(data)
    return strings.trim_space(output)
}
```

#### 1.4 Update Command Handlers

Modify existing commands to use new JSON5 config:

```odin
// Add plugin command - updated for JSON5
handle_plugin_add :: proc(args: []string, shell_type: ShellType, dry_run: bool) {
    if len(args) < 2 {
        fmt.eprintln("Error: Plugin name required")
        fmt.eprintln("Usage: wayu plugin add <name> [url]")
        os.exit(EXIT_USAGE)
    }

    // Run migration if needed
    if !migrate_plugin_config() {
        os.exit(EXIT_CONFIG)
    }

    config, ok := read_plugin_config_json()
    if !ok {
        os.exit(EXIT_CONFIG)
    }
    defer cleanup_plugin_config(&config)

    plugin_name := args[1]
    plugin_url := ""

    // Check if URL provided or if it's a popular plugin
    if len(args) >= 3 {
        plugin_url = args[2]
    } else if popular, found := POPULAR_PLUGINS[plugin_name]; found {
        plugin_url = popular.url
        fmt.printfln("Using popular plugin: %s", popular.description)
    } else {
        fmt.eprintfln("Error: URL required for unknown plugin '%s'", plugin_name)
        fmt.eprintln("Or use one of the popular plugins:")
        list_popular_plugins()
        os.exit(EXIT_USAGE)
    }

    // Check if already installed
    for plugin in config.plugins {
        if plugin.name == plugin_name {
            fmt.eprintfln("Error: Plugin '%s' already installed", plugin_name)
            os.exit(EXIT_DATAERR)
        }
    }

    plugins_dir := fmt.aprintf("%s/plugins", WAYU_CONFIG)
    defer delete(plugins_dir)

    plugin_dir := fmt.aprintf("%s/%s", plugins_dir, plugin_name)
    defer delete(plugin_dir)

    if dry_run {
        fmt.println("[DRY RUN] Would clone plugin:")
        fmt.printfln("  URL: %s", plugin_url)
        fmt.printfln("  Destination: %s", plugin_dir)
        return
    }

    // Clone repository
    fmt.printfln("Cloning %s...", plugin_name)
    if !git_clone(plugin_url, plugin_dir) {
        fmt.eprintln("Error: Failed to clone repository")
        os.exit(EXIT_IOERR)
    }

    // Detect entry file
    entry := detect_entry_file(plugin_dir)
    if entry == "" {
        fmt.eprintln("Warning: No entry file detected, using plugin directory")
        entry = plugin_name
    }

    // Get git info
    git_info := get_git_info(plugin_dir)

    // Create plugin metadata
    new_plugin := PluginMetadata{
        name = strings.clone(plugin_name),
        url = strings.clone(plugin_url),
        enabled = true,
        shell = shell_type == .ZSH ? .ZSH : .BASH,
        installed_path = strings.clone(plugin_dir),
        entry_file = strings.clone(entry),
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

    append(&config.plugins, new_plugin)

    // Write config
    if !write_plugin_config_json(&config) {
        fmt.eprintln("Error: Failed to save configuration")
        os.exit(EXIT_CANTCREAT)
    }

    // Regenerate plugin loader
    if !generate_plugin_loader(&config, shell_type) {
        fmt.eprintln("Error: Failed to generate plugin loader")
        os.exit(EXIT_CANTCREAT)
    }

    fmt.printfln("✓ Plugin '%s' installed successfully", plugin_name)
}

// Cleanup helper for PluginConfig
cleanup_plugin_config :: proc(config: ^PluginConfig) {
    for &plugin in config.plugins {
        delete(plugin.name)
        delete(plugin.url)
        delete(plugin.installed_path)
        delete(plugin.entry_file)
        delete(plugin.git.branch)
        delete(plugin.git.commit)
        delete(plugin.git.last_checked)
        delete(plugin.git.remote_commit)
        delete(plugin.dependencies)
        delete(plugin.config)
        delete(plugin.conflicts.env_vars)
        delete(plugin.conflicts.functions)
        delete(plugin.conflicts.aliases_)
        delete(plugin.conflicts.conflicting_plugins)
    }
    delete(config.plugins)
}
```

---

### Phase 2: Update System (3-4 days)

#### 2.1 Check for Updates

Implement `wayu plugin check` command:

```odin
// Check for available updates
handle_plugin_check :: proc(args: []string, dry_run: bool) {
    config, ok := read_plugin_config_json()
    if !ok {
        os.exit(EXIT_CONFIG)
    }
    defer cleanup_plugin_config(&config)

    if len(config.plugins) == 0 {
        fmt.println("No plugins installed")
        return
    }

    fmt.println("Checking for plugin updates...")
    fmt.println()

    updates_available := false

    for &plugin in config.plugins {
        if !plugin.enabled {
            continue
        }

        fmt.printfln("Checking %s...", plugin.name)

        // Fetch remote commit
        remote_commit := get_remote_commit(plugin.url, plugin.git.branch)
        if remote_commit == "" {
            fmt.println("  ⚠ Failed to check remote")
            continue
        }

        // Update metadata
        plugin.git.remote_commit = remote_commit
        plugin.git.last_checked = get_iso8601_timestamp()

        // Compare commits
        if plugin.git.commit != remote_commit {
            fmt.printfln("  ↑ Update available: %s → %s",
                plugin.git.commit[0:7], remote_commit[0:7])
            updates_available = true
        } else {
            fmt.println("  ✓ Up to date")
        }
    }

    // Save updated last_checked timestamps
    if !dry_run {
        write_plugin_config_json(&config)
    }

    fmt.println()
    if updates_available {
        fmt.println("Run 'wayu plugin update <name>' or 'wayu plugin update --all' to update")
    } else {
        fmt.println("All plugins are up to date!")
    }
}

// Get remote commit SHA for a git repository
get_remote_commit :: proc(url: string, branch: string) -> string {
    branch_ref := branch != "" ? branch : "HEAD"

    cmd := fmt.aprintf("git ls-remote %s %s 2>/dev/null | cut -f1", url, branch_ref)
    defer delete(cmd)

    full_sha := exec_command_output(cmd)
    if full_sha == "" {
        return ""
    }

    // Return short SHA (first 7 chars)
    return full_sha[0:min(7, len(full_sha))]
}
```

#### 2.2 Update Plugins

Implement `wayu plugin update <name>` and `wayu plugin update --all`:

```odin
// Update plugin(s)
handle_plugin_update :: proc(args: []string, shell_type: ShellType, dry_run: bool) {
    if len(args) < 2 {
        fmt.eprintln("Error: Plugin name required, or use --all")
        fmt.eprintln("Usage: wayu plugin update <name|--all>")
        os.exit(EXIT_USAGE)
    }

    config, ok := read_plugin_config_json()
    if !ok {
        os.exit(EXIT_CONFIG)
    }
    defer cleanup_plugin_config(&config)

    update_all := args[1] == "--all"

    if update_all {
        update_all_plugins(&config, shell_type, dry_run)
    } else {
        plugin_name := args[1]
        update_single_plugin(&config, plugin_name, shell_type, dry_run)
    }
}

// Update a single plugin
update_single_plugin :: proc(config: ^PluginConfig, name: string, shell_type: ShellType, dry_run: bool) {
    // Find plugin
    plugin_idx := -1
    for plugin, idx in config.plugins {
        if plugin.name == name {
            plugin_idx = idx
            break
        }
    }

    if plugin_idx == -1 {
        fmt.eprintfln("Error: Plugin '%s' not found", name)
        os.exit(EXIT_DATAERR)
    }

    plugin := &config.plugins[plugin_idx]

    if dry_run {
        fmt.printfln("[DRY RUN] Would update plugin '%s'", name)
        return
    }

    fmt.printfln("Updating %s...", name)

    // Pull latest changes
    if !git_update(plugin.installed_path) {
        fmt.eprintln("  ✗ Failed to update")
        os.exit(EXIT_IOERR)
    }

    // Update git metadata
    new_git_info := get_git_info(plugin.installed_path)
    delete(plugin.git.commit)
    delete(plugin.git.branch)
    plugin.git = new_git_info

    fmt.printfln("  ✓ Updated to commit %s", plugin.git.commit)

    // Save config
    if !write_plugin_config_json(config) {
        fmt.eprintln("Error: Failed to save configuration")
        os.exit(EXIT_CANTCREAT)
    }

    // Regenerate loader (entry file might have changed)
    if !generate_plugin_loader(config, shell_type) {
        fmt.eprintln("Warning: Failed to regenerate plugin loader")
    }
}

// Update all plugins
update_all_plugins :: proc(config: ^PluginConfig, shell_type: ShellType, dry_run: bool) {
    if len(config.plugins) == 0 {
        fmt.println("No plugins installed")
        return
    }

    updated_count := 0
    failed_count := 0

    for &plugin in config.plugins {
        if !plugin.enabled {
            fmt.printfln("Skipping %s (disabled)", plugin.name)
            continue
        }

        if dry_run {
            fmt.printfln("[DRY RUN] Would update plugin '%s'", plugin.name)
            continue
        }

        fmt.printfln("Updating %s...", plugin.name)

        if !git_update(plugin.installed_path) {
            fmt.println("  ✗ Failed to update")
            failed_count += 1
            continue
        }

        // Update git metadata
        new_git_info := get_git_info(plugin.installed_path)
        delete(plugin.git.commit)
        delete(plugin.git.branch)
        plugin.git = new_git_info

        fmt.printfln("  ✓ Updated to commit %s", plugin.git.commit)
        updated_count += 1
    }

    // Save config
    if !dry_run && updated_count > 0 {
        if !write_plugin_config_json(config) {
            fmt.eprintln("Error: Failed to save configuration")
            os.exit(EXIT_CANTCREAT)
        }

        // Regenerate loader
        if !generate_plugin_loader(config, shell_type) {
            fmt.eprintln("Warning: Failed to regenerate plugin loader")
        }
    }

    fmt.println()
    fmt.printfln("Updated: %d, Failed: %d", updated_count, failed_count)
}
```

---

### Phase 3: Enable/Disable (1-2 days)

#### 3.1 Enable/Disable Commands

```odin
// Enable a disabled plugin
handle_plugin_enable :: proc(args: []string, shell_type: ShellType, dry_run: bool) {
    if len(args) < 2 {
        fmt.eprintln("Error: Plugin name required")
        fmt.eprintln("Usage: wayu plugin enable <name>")
        os.exit(EXIT_USAGE)
    }

    config, ok := read_plugin_config_json()
    if !ok {
        os.exit(EXIT_CONFIG)
    }
    defer cleanup_plugin_config(&config)

    plugin_name := args[1]

    // Find plugin
    found := false
    for &plugin in config.plugins {
        if plugin.name == plugin_name {
            if plugin.enabled {
                fmt.printfln("Plugin '%s' is already enabled", plugin_name)
                return
            }

            if dry_run {
                fmt.printfln("[DRY RUN] Would enable plugin '%s'", plugin_name)
                return
            }

            plugin.enabled = true
            found = true
            break
        }
    }

    if !found {
        fmt.eprintfln("Error: Plugin '%s' not found", plugin_name)
        os.exit(EXIT_DATAERR)
    }

    // Save config
    if !write_plugin_config_json(&config) {
        fmt.eprintln("Error: Failed to save configuration")
        os.exit(EXIT_CANTCREAT)
    }

    // Regenerate loader
    if !generate_plugin_loader(&config, shell_type) {
        fmt.eprintln("Error: Failed to regenerate plugin loader")
        os.exit(EXIT_CANTCREAT)
    }

    fmt.printfln("✓ Plugin '%s' enabled", plugin_name)
    fmt.println("Restart your shell or run: source ~/.config/wayu/init.{zsh,bash}")
}

// Disable a plugin without removing it
handle_plugin_disable :: proc(args: []string, shell_type: ShellType, dry_run: bool) {
    if len(args) < 2 {
        fmt.eprintln("Error: Plugin name required")
        fmt.eprintln("Usage: wayu plugin disable <name>")
        os.exit(EXIT_USAGE)
    }

    config, ok := read_plugin_config_json()
    if !ok {
        os.exit(EXIT_CONFIG)
    }
    defer cleanup_plugin_config(&config)

    plugin_name := args[1]

    // Find plugin
    found := false
    for &plugin in config.plugins {
        if plugin.name == plugin_name {
            if !plugin.enabled {
                fmt.printfln("Plugin '%s' is already disabled", plugin_name)
                return
            }

            if dry_run {
                fmt.printfln("[DRY RUN] Would disable plugin '%s'", plugin_name)
                return
            }

            plugin.enabled = false
            found = true
            break
        }
    }

    if !found {
        fmt.eprintfln("Error: Plugin '%s' not found", plugin_name)
        os.exit(EXIT_DATAERR)
    }

    // Save config
    if !write_plugin_config_json(&config) {
        fmt.eprintln("Error: Failed to save configuration")
        os.exit(EXIT_CANTCREAT)
    }

    // Regenerate loader
    if !generate_plugin_loader(&config, shell_type) {
        fmt.eprintln("Error: Failed to regenerate plugin loader")
        os.exit(EXIT_CANTCREAT)
    }

    fmt.printfln("✓ Plugin '%s' disabled", plugin_name)
    fmt.println("Restart your shell or run: source ~/.config/wayu/init.{zsh,bash}")
}
```

---

### Phase 4: Dependency Management (3-4 days)

#### 4.1 Dependency Resolution

```odin
// Resolve dependency order for plugins
resolve_dependencies :: proc(config: ^PluginConfig) -> (order: [dynamic]string, ok: bool) {
    order = make([dynamic]string)
    visited := make(map[string]bool)
    defer delete(visited)

    in_progress := make(map[string]bool)
    defer delete(in_progress)

    // DFS with cycle detection
    for plugin in config.plugins {
        if !plugin.enabled {
            continue
        }

        if !visit_plugin(config, plugin.name, &visited, &in_progress, &order) {
            delete(order)
            return order, false
        }
    }

    return order, true
}

// DFS visit for dependency resolution
visit_plugin :: proc(config: ^PluginConfig, name: string, visited: ^map[string]bool, in_progress: ^map[string]bool, order: ^[dynamic]string) -> bool {
    if visited[name] {
        return true
    }

    if in_progress[name] {
        fmt.eprintfln("Error: Circular dependency detected involving '%s'", name)
        return false
    }

    // Find plugin
    plugin_ptr: ^PluginMetadata = nil
    for &plugin in config.plugins {
        if plugin.name == name {
            plugin_ptr = &plugin
            break
        }
    }

    if plugin_ptr == nil {
        fmt.eprintfln("Error: Dependency '%s' not found", name)
        return false
    }

    in_progress[name] = true

    // Visit dependencies first
    for dep in plugin_ptr.dependencies {
        if !visit_plugin(config, dep, visited, in_progress, order) {
            return false
        }
    }

    delete_key(in_progress, name)
    visited[name] = true
    append(order, strings.clone(name))

    return true
}

// Updated plugin loader generation with dependency order
generate_plugin_loader :: proc(config: ^PluginConfig, shell_type: ShellType) -> bool {
    ext := shell_type == .ZSH ? "zsh" : "bash"
    loader_file := fmt.aprintf("%s/plugins/loader.%s", WAYU_CONFIG, ext)
    defer delete(loader_file)

    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)

    // Header
    strings.write_string(&sb, "# Wayu Plugin Loader\n")
    strings.write_string(&sb, "# Generated automatically - do not edit manually\n")
    strings.write_string(&sb, fmt.aprintf("# Last updated: %s\n\n", get_iso8601_timestamp()))

    // Resolve load order
    load_order, ok := resolve_dependencies(config)
    if !ok {
        fmt.eprintln("Error: Failed to resolve plugin dependencies")
        return false
    }
    defer delete(load_order)

    // Load plugins in dependency order
    for plugin_name in load_order {
        // Find plugin metadata
        plugin_ptr: ^PluginMetadata = nil
        for &plugin in config.plugins {
            if plugin.name == plugin_name && plugin.enabled {
                plugin_ptr = &plugin
                break
            }
        }

        if plugin_ptr == nil {
            continue
        }

        plugin := plugin_ptr^

        // Set config variables
        if len(plugin.config) > 0 {
            strings.write_string(&sb, fmt.aprintf("# Config for %s\n", plugin.name))
            for key, value in plugin.config {
                strings.write_string(&sb, fmt.aprintf("export %s=\"%s\"\n", key, value))
            }
            strings.write_string(&sb, "\n")
        }

        // Source plugin
        entry_path := fmt.aprintf("%s/%s", plugin.installed_path, plugin.entry_file)
        strings.write_string(&sb, fmt.aprintf("# Load %s\n", plugin.name))

        if os.exists(entry_path) {
            strings.write_string(&sb, fmt.aprintf("source \"%s\"\n", entry_path))
        } else {
            strings.write_string(&sb, fmt.aprintf("# Warning: Entry file not found: %s\n", entry_path))
        }

        strings.write_string(&sb, "\n")
    }

    // Write file
    content := strings.to_string(sb)
    write_ok := os.write_entire_file(loader_file, transmute([]byte)content)

    if !write_ok {
        fmt.eprintln("Error: Failed to write plugin loader")
        return false
    }

    return true
}
```

#### 4.2 Add Dependency Command

```odin
// Add dependency to a plugin
handle_plugin_add_dependency :: proc(args: []string, shell_type: ShellType, dry_run: bool) {
    if len(args) < 3 {
        fmt.eprintln("Error: Plugin name and dependency required")
        fmt.eprintln("Usage: wayu plugin dependency add <plugin> <dependency>")
        os.exit(EXIT_USAGE)
    }

    config, ok := read_plugin_config_json()
    if !ok {
        os.exit(EXIT_CONFIG)
    }
    defer cleanup_plugin_config(&config)

    plugin_name := args[2]
    dependency := args[3]

    // Find plugin
    plugin_ptr: ^PluginMetadata = nil
    for &plugin in config.plugins {
        if plugin.name == plugin_name {
            plugin_ptr = &plugin
            break
        }
    }

    if plugin_ptr == nil {
        fmt.eprintfln("Error: Plugin '%s' not found", plugin_name)
        os.exit(EXIT_DATAERR)
    }

    // Check if dependency exists
    dep_found := false
    for plugin in config.plugins {
        if plugin.name == dependency {
            dep_found = true
            break
        }
    }

    if !dep_found {
        fmt.eprintfln("Error: Dependency '%s' is not installed", dependency)
        fmt.eprintln("Install it first with: wayu plugin add")
        os.exit(EXIT_DATAERR)
    }

    // Check if already in dependencies
    for dep in plugin_ptr.dependencies {
        if dep == dependency {
            fmt.eprintfln("Dependency '%s' already exists for '%s'", dependency, plugin_name)
            return
        }
    }

    if dry_run {
        fmt.printfln("[DRY RUN] Would add dependency '%s' to '%s'", dependency, plugin_name)
        return
    }

    // Add dependency
    append(&plugin_ptr.dependencies, strings.clone(dependency))

    // Verify no circular dependencies
    _, resolve_ok := resolve_dependencies(&config)
    if !resolve_ok {
        // Remove the dependency we just added
        pop(&plugin_ptr.dependencies)
        fmt.eprintln("Error: Adding this dependency would create a circular dependency")
        os.exit(EXIT_DATAERR)
    }

    // Save config
    if !write_plugin_config_json(&config) {
        fmt.eprintln("Error: Failed to save configuration")
        os.exit(EXIT_CANTCREAT)
    }

    // Regenerate loader
    if !generate_plugin_loader(&config, shell_type) {
        fmt.eprintln("Error: Failed to regenerate plugin loader")
        os.exit(EXIT_CANTCREAT)
    }

    fmt.printfln("✓ Added dependency '%s' to '%s'", dependency, plugin_name)
}
```

---

### Phase 5: Load Prioritization (2 days)

#### 5.1 Priority Management

```odin
// Set plugin load priority
handle_plugin_priority :: proc(args: []string, shell_type: ShellType, dry_run: bool) {
    if len(args) < 3 {
        fmt.eprintln("Error: Plugin name and priority required")
        fmt.eprintln("Usage: wayu plugin priority <name> <number>")
        fmt.eprintln("Lower numbers load first (default: 100)")
        os.exit(EXIT_USAGE)
    }

    config, ok := read_plugin_config_json()
    if !ok {
        os.exit(EXIT_CONFIG)
    }
    defer cleanup_plugin_config(&config)

    plugin_name := args[1]

    priority, parse_ok := strconv.parse_int(args[2])
    if !parse_ok {
        fmt.eprintfln("Error: Invalid priority number '%s'", args[2])
        os.exit(EXIT_USAGE)
    }

    // Find plugin
    plugin_ptr: ^PluginMetadata = nil
    for &plugin in config.plugins {
        if plugin.name == plugin_name {
            plugin_ptr = &plugin
            break
        }
    }

    if plugin_ptr == nil {
        fmt.eprintfln("Error: Plugin '%s' not found", plugin_name)
        os.exit(EXIT_DATAERR)
    }

    if dry_run {
        fmt.printfln("[DRY RUN] Would set priority of '%s' to %d", plugin_name, priority)
        return
    }

    old_priority := plugin_ptr.priority
    plugin_ptr.priority = priority

    // Save config
    if !write_plugin_config_json(&config) {
        fmt.eprintln("Error: Failed to save configuration")
        os.exit(EXIT_CANTCREAT)
    }

    // Regenerate loader (load order changed)
    if !generate_plugin_loader(&config, shell_type) {
        fmt.eprintln("Error: Failed to regenerate plugin loader")
        os.exit(EXIT_CANTCREAT)
    }

    fmt.printfln("✓ Updated priority for '%s': %d → %d", plugin_name, old_priority, priority)
    fmt.println("Restart your shell for changes to take effect")
}

// Updated dependency resolution with priority support
resolve_dependencies_with_priority :: proc(config: ^PluginConfig) -> (order: [dynamic]string, ok: bool) {
    // First resolve dependencies
    order, dep_ok := resolve_dependencies(config)
    if !dep_ok {
        return order, false
    }

    // Create map of name -> priority
    priorities := make(map[string]int)
    defer delete(priorities)

    for plugin in config.plugins {
        priorities[plugin.name] = plugin.priority
    }

    // Sort by priority (stable sort preserves dependency order for same priority)
    slice.stable_sort_by(order[:], proc(a, b: string) -> bool {
        return priorities[a] < priorities[b]
    })

    return order, true
}
```

---

### Phase 6: Conflict Detection (3 days)

#### 6.1 Conflict Scanning

```odin
// Scan plugin for potential conflicts
scan_plugin_conflicts :: proc(plugin: ^PluginMetadata) -> bool {
    entry_path := fmt.aprintf("%s/%s", plugin.installed_path, plugin.entry_file)
    defer delete(entry_path)

    if !os.exists(entry_path) {
        return true
    }

    content, read_ok := os.read_entire_file_from_filename(entry_path)
    if !read_ok {
        return false
    }
    defer delete(content)

    script := string(content)
    lines := strings.split(script, "\n")
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

        // Skip comments
        if strings.has_prefix(trimmed, "#") {
            continue
        }

        // Check for exports
        if strings.has_prefix(trimmed, "export ") {
            parts := strings.split(trimmed, "=")
            if len(parts) >= 2 {
                var_name := strings.trim_space(parts[0][7:]) // Skip "export "
                append(&plugin.conflicts.env_vars, strings.clone(var_name))
            }
            delete(parts)
        }

        // Check for functions (bash/zsh syntax)
        if strings.contains(trimmed, "function ") || strings.contains(trimmed, "() {") {
            // Extract function name
            func_name := ""
            if strings.has_prefix(trimmed, "function ") {
                parts := strings.split(trimmed, " ")
                if len(parts) >= 2 {
                    func_name = strings.trim_right(parts[1], "()")
                }
                delete(parts)
            } else {
                parts := strings.split(trimmed, "()")
                if len(parts) >= 1 {
                    func_name = strings.trim_space(parts[0])
                }
                delete(parts)
            }

            if func_name != "" {
                append(&plugin.conflicts.functions, strings.clone(func_name))
            }
        }

        // Check for aliases
        if strings.has_prefix(trimmed, "alias ") {
            parts := strings.split(trimmed, "=")
            if len(parts) >= 2 {
                alias_name := strings.trim_space(parts[0][6:]) // Skip "alias "
                append(&plugin.conflicts.aliases_, strings.clone(alias_name))
            }
            delete(parts)
        }
    }

    return true
}

// Detect conflicts between plugins
detect_conflicts :: proc(config: ^PluginConfig) {
    // Scan all enabled plugins
    for &plugin in config.plugins {
        if !plugin.enabled {
            continue
        }

        scan_plugin_conflicts(&plugin)
    }

    // Compare plugins for conflicts
    for i := 0; i < len(config.plugins); i += 1 {
        plugin_a := &config.plugins[i]

        if !plugin_a.enabled {
            continue
        }

        // Clear conflict tracking
        delete(plugin_a.conflicts.conflicting_plugins)
        plugin_a.conflicts.conflicting_plugins = make([dynamic]string)
        plugin_a.conflicts.detected = false

        for j := i + 1; j < len(config.plugins); j += 1 {
            plugin_b := &config.plugins[j]

            if !plugin_b.enabled {
                continue
            }

            has_conflict := false

            // Check env var conflicts
            for var_a in plugin_a.conflicts.env_vars {
                for var_b in plugin_b.conflicts.env_vars {
                    if var_a == var_b {
                        has_conflict = true
                        break
                    }
                }
            }

            // Check function conflicts
            for func_a in plugin_a.conflicts.functions {
                for func_b in plugin_b.conflicts.functions {
                    if func_a == func_b {
                        has_conflict = true
                        break
                    }
                }
            }

            // Check alias conflicts
            for alias_a in plugin_a.conflicts.aliases_ {
                for alias_b in plugin_b.conflicts.aliases_ {
                    if alias_a == alias_b {
                        has_conflict = true
                        break
                    }
                }
            }

            if has_conflict {
                plugin_a.conflicts.detected = true
                plugin_b.conflicts.detected = true
                append(&plugin_a.conflicts.conflicting_plugins, strings.clone(plugin_b.name))
                append(&plugin_b.conflicts.conflicting_plugins, strings.clone(plugin_a.name))
            }
        }
    }
}

// Generate loader with conflict warnings
generate_plugin_loader_with_warnings :: proc(config: ^PluginConfig, shell_type: ShellType) -> bool {
    // Detect conflicts
    detect_conflicts(config)

    ext := shell_type == .ZSH ? "zsh" : "bash"
    loader_file := fmt.aprintf("%s/plugins/loader.%s", WAYU_CONFIG, ext)
    defer delete(loader_file)

    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)

    // Header
    strings.write_string(&sb, "# Wayu Plugin Loader\n")
    strings.write_string(&sb, "# Generated automatically - do not edit manually\n")
    strings.write_string(&sb, fmt.aprintf("# Last updated: %s\n\n", get_iso8601_timestamp()))

    // Conflict warnings
    has_conflicts := false
    for plugin in config.plugins {
        if plugin.enabled && plugin.conflicts.detected {
            has_conflicts = true
            break
        }
    }

    if has_conflicts {
        strings.write_string(&sb, "# ⚠️  CONFLICT WARNINGS\n")
        strings.write_string(&sb, "# The following plugins have potential conflicts:\n")

        for plugin in config.plugins {
            if plugin.enabled && plugin.conflicts.detected {
                strings.write_string(&sb, fmt.aprintf("#   - %s conflicts with: %s\n",
                    plugin.name, strings.join(plugin.conflicts.conflicting_plugins[:], ", ")))
            }
        }

        strings.write_string(&sb, "# This may cause unexpected behavior. Review your plugin configuration.\n\n")
    }

    // Resolve load order
    load_order, ok := resolve_dependencies_with_priority(config)
    if !ok {
        fmt.eprintln("Error: Failed to resolve plugin dependencies")
        return false
    }
    defer delete(load_order)

    // Load plugins in priority/dependency order
    for plugin_name in load_order {
        plugin_ptr: ^PluginMetadata = nil
        for &plugin in config.plugins {
            if plugin.name == plugin_name && plugin.enabled {
                plugin_ptr = &plugin
                break
            }
        }

        if plugin_ptr == nil {
            continue
        }

        plugin := plugin_ptr^

        // Conflict warning for this plugin
        if plugin.conflicts.detected {
            strings.write_string(&sb, fmt.aprintf("# ⚠️  WARNING: %s has conflicts\n", plugin.name))
        }

        // Set config variables
        if len(plugin.config) > 0 {
            strings.write_string(&sb, fmt.aprintf("# Config for %s\n", plugin.name))
            for key, value in plugin.config {
                strings.write_string(&sb, fmt.aprintf("export %s=\"%s\"\n", key, value))
            }
            strings.write_string(&sb, "\n")
        }

        // Source plugin
        entry_path := fmt.aprintf("%s/%s", plugin.installed_path, plugin.entry_file)
        strings.write_string(&sb, fmt.aprintf("# Load %s (priority: %d)\n", plugin.name, plugin.priority))

        if os.exists(entry_path) {
            strings.write_string(&sb, fmt.aprintf("source \"%s\"\n", entry_path))
        } else {
            strings.write_string(&sb, fmt.aprintf("# Warning: Entry file not found: %s\n", entry_path))
        }

        strings.write_string(&sb, "\n")
    }

    // Write file
    content := strings.to_string(sb)
    write_ok := os.write_entire_file(loader_file, transmute([]byte)content)

    if !write_ok {
        fmt.eprintln("Error: Failed to write plugin loader")
        return false
    }

    return true
}
```

---

## Command Routing Updates

**File**: `src/main.odin`

Add new command routing for plugin subcommands:

```odin
// In handle_plugin_command()
handle_plugin_command :: proc(parsed: ^ParsedCommand) {
    if len(parsed.args) == 0 {
        print_plugin_help()
        os.exit(EXIT_USAGE)
    }

    // Run migration on any plugin command
    migrate_plugin_config()

    action_str := parsed.args[0]

    switch action_str {
    case "add":
        handle_plugin_add(parsed.args, parsed.shell_type, parsed.dry_run)
    case "remove", "rm":
        handle_plugin_remove(parsed.args, parsed.shell_type, parsed.dry_run)
    case "list", "ls":
        handle_plugin_list(parsed.args, parsed.dry_run)
    case "get":
        handle_plugin_get(parsed.args)
    case "check":
        handle_plugin_check(parsed.args, parsed.dry_run)
    case "update":
        handle_plugin_update(parsed.args, parsed.shell_type, parsed.dry_run)
    case "enable":
        handle_plugin_enable(parsed.args, parsed.shell_type, parsed.dry_run)
    case "disable":
        handle_plugin_disable(parsed.args, parsed.shell_type, parsed.dry_run)
    case "priority":
        handle_plugin_priority(parsed.args, parsed.shell_type, parsed.dry_run)
    case "dependency", "dep":
        handle_plugin_dependency(parsed.args, parsed.shell_type, parsed.dry_run)
    case "help", "--help", "-h":
        print_plugin_help()
    case:
        fmt.eprintfln("Error: Unknown plugin command '%s'", action_str)
        print_plugin_help()
        os.exit(EXIT_USAGE)
    }
}

// Dependency subcommand handler
handle_plugin_dependency :: proc(args: []string, shell_type: ShellType, dry_run: bool) {
    if len(args) < 2 {
        fmt.eprintln("Error: Dependency action required")
        fmt.eprintln("Usage: wayu plugin dependency <add|remove|list> ...")
        os.exit(EXIT_USAGE)
    }

    dep_action := args[1]

    switch dep_action {
    case "add":
        handle_plugin_add_dependency(args, shell_type, dry_run)
    case "remove", "rm":
        handle_plugin_remove_dependency(args, shell_type, dry_run)
    case "list", "ls":
        handle_plugin_list_dependencies(args)
    case:
        fmt.eprintfln("Error: Unknown dependency action '%s'", dep_action)
        os.exit(EXIT_USAGE)
    }
}
```

---

## Testing Strategy

### Unit Tests

**File**: `tests/unit/test_plugin.odin`

Add tests for new functionality:

```odin
@(test)
test_json5_config_roundtrip :: proc(t: ^testing.T) {
    // Create config
    config := PluginConfig{
        version = "1.0",
        last_updated = "2025-10-16T18:00:00Z",
        plugins = make([dynamic]PluginMetadata),
    }
    defer cleanup_plugin_config(&config)

    plugin := PluginMetadata{
        name = "test-plugin",
        url = "https://github.com/test/plugin",
        enabled = true,
        shell = .ZSH,
        git = GitMetadata{
            branch = "main",
            commit = "abc123",
            last_checked = "2025-10-16T18:00:00Z",
            remote_commit = "abc123",
        },
        priority = 100,
    }

    append(&config.plugins, plugin)

    // Marshal to JSON5
    data, err := json.marshal(config, {pretty = true, spec = .JSON5})
    testing.expect(t, err == nil, "Should marshal successfully")
    defer delete(data)

    // Unmarshal back
    config2: PluginConfig
    err2 := json.unmarshal(data, &config2, spec = .JSON5)
    testing.expect(t, err2 == nil, "Should unmarshal successfully")
    defer cleanup_plugin_config(&config2)

    // Verify
    testing.expect_value(t, len(config2.plugins), 1)
    testing.expect_value(t, config2.plugins[0].name, "test-plugin")
}

@(test)
test_dependency_resolution :: proc(t: ^testing.T) {
    config := PluginConfig{
        plugins = make([dynamic]PluginMetadata),
    }
    defer cleanup_plugin_config(&config)

    // Plugin A depends on B, B depends on C
    append(&config.plugins, PluginMetadata{
        name = "plugin-a",
        enabled = true,
        dependencies = make([dynamic]string),
    })
    append(&config.plugins[0].dependencies, "plugin-b")

    append(&config.plugins, PluginMetadata{
        name = "plugin-b",
        enabled = true,
        dependencies = make([dynamic]string),
    })
    append(&config.plugins[1].dependencies, "plugin-c")

    append(&config.plugins, PluginMetadata{
        name = "plugin-c",
        enabled = true,
        dependencies = make([dynamic]string),
    })

    // Resolve
    order, ok := resolve_dependencies(&config)
    testing.expect(t, ok, "Should resolve dependencies")
    defer delete(order)

    // Should be: C, B, A
    testing.expect_value(t, len(order), 3)
    testing.expect_value(t, order[0], "plugin-c")
    testing.expect_value(t, order[1], "plugin-b")
    testing.expect_value(t, order[2], "plugin-a")
}

@(test)
test_circular_dependency_detection :: proc(t: ^testing.T) {
    config := PluginConfig{
        plugins = make([dynamic]PluginMetadata),
    }
    defer cleanup_plugin_config(&config)

    // Plugin A depends on B, B depends on A (circular)
    append(&config.plugins, PluginMetadata{
        name = "plugin-a",
        enabled = true,
        dependencies = make([dynamic]string),
    })
    append(&config.plugins[0].dependencies, "plugin-b")

    append(&config.plugins, PluginMetadata{
        name = "plugin-b",
        enabled = true,
        dependencies = make([dynamic]string),
    })
    append(&config.plugins[1].dependencies, "plugin-a")

    // Should fail
    order, ok := resolve_dependencies(&config)
    defer delete(order)
    testing.expect(t, !ok, "Should detect circular dependency")
}

@(test)
test_conflict_detection :: proc(t: ^testing.T) {
    config := PluginConfig{
        plugins = make([dynamic]PluginMetadata),
    }
    defer cleanup_plugin_config(&config)

    // Two plugins defining same env var
    append(&config.plugins, PluginMetadata{
        name = "plugin-a",
        enabled = true,
        conflicts = ConflictInfo{
            env_vars = make([dynamic]string),
        },
    })
    append(&config.plugins[0].conflicts.env_vars, "MY_VAR")

    append(&config.plugins, PluginMetadata{
        name = "plugin-b",
        enabled = true,
        conflicts = ConflictInfo{
            env_vars = make([dynamic]string),
        },
    })
    append(&config.plugins[1].conflicts.env_vars, "MY_VAR")

    // Detect conflicts
    detect_conflicts(&config)

    // Should mark both as having conflicts
    testing.expect(t, config.plugins[0].conflicts.detected, "Plugin A should have conflicts")
    testing.expect(t, config.plugins[1].conflicts.detected, "Plugin B should have conflicts")
}
```

### Integration Tests

**File**: `tests/integration/test_plugin_enhanced.rb`

```ruby
#!/usr/bin/env ruby
require_relative 'test_helper'

class TestPluginEnhanced < Minitest::Test
  def setup
    @temp_home = Dir.mktmpdir("wayu-plugin-test-")
    @wayu_config = File.join(@temp_home, ".config", "wayu")
    FileUtils.mkdir_p(@wayu_config)
    ENV["HOME"] = @temp_home
    ENV["WAYU_CONFIG"] = @wayu_config
  end

  def teardown
    FileUtils.rm_rf(@temp_home)
  end

  def test_json5_migration
    # Create old format config
    old_config = File.join(@wayu_config, "plugins.conf")
    File.write(old_config, "test-plugin|https://example.com/plugin|true|zsh\n")

    # Run any plugin command to trigger migration
    output, status = run_wayu("plugin list")

    assert status.success?, "Migration should succeed"
    assert File.exist?(File.join(@wayu_config, "plugins.json")), "Should create plugins.json"
    assert File.exist?(File.join(@wayu_config, "plugins.conf.backup")), "Should backup old config"

    # Verify JSON5 content
    json_content = File.read(File.join(@wayu_config, "plugins.json"))
    config = JSON.parse(json_content)

    assert_equal "1.0", config["version"]
    assert_equal 1, config["plugins"].length
    assert_equal "test-plugin", config["plugins"][0]["name"]
  end

  def test_enable_disable_workflow
    # Add plugin
    output, status = run_wayu("plugin add test-plugin https://example.com/plugin")
    assert status.success?

    # Disable
    output, status = run_wayu("plugin disable test-plugin")
    assert status.success?
    assert_match(/disabled/, output)

    # Verify in config
    config = read_plugin_config_json
    plugin = config["plugins"].find { |p| p["name"] == "test-plugin" }
    assert_equal false, plugin["enabled"]

    # Enable
    output, status = run_wayu("plugin enable test-plugin")
    assert status.success?
    assert_match(/enabled/, output)

    # Verify
    config = read_plugin_config_json
    plugin = config["plugins"].find { |p| p["name"] == "test-plugin" }
    assert_equal true, plugin["enabled"]
  end

  def test_priority_setting
    # Add two plugins
    run_wayu("plugin add plugin-a https://example.com/a")
    run_wayu("plugin add plugin-b https://example.com/b")

    # Set priorities
    run_wayu("plugin priority plugin-a 10")
    run_wayu("plugin priority plugin-b 20")

    # Verify
    config = read_plugin_config_json
    plugin_a = config["plugins"].find { |p| p["name"] == "plugin-a" }
    plugin_b = config["plugins"].find { |p| p["name"] == "plugin-b" }

    assert_equal 10, plugin_a["priority"]
    assert_equal 20, plugin_b["priority"]

    # Check loader order (plugin-a should load before plugin-b)
    loader = File.read(File.join(@wayu_config, "plugins", "loader.zsh"))
    a_pos = loader.index("plugin-a")
    b_pos = loader.index("plugin-b")

    assert a_pos < b_pos, "plugin-a should load before plugin-b"
  end

  private

  def run_wayu(args)
    cmd = "#{WAYU_BIN} #{args}"
    output = `#{cmd} 2>&1`
    [output, $?]
  end

  def read_plugin_config_json
    json_file = File.join(@wayu_config, "plugins.json")
    JSON.parse(File.read(json_file))
  end
end
```

---

## Migration Guide

### For Users

**Automatic Migration**:
- Run any `wayu plugin` command
- `plugins.conf` will be automatically converted to `plugins.json`
- Old config backed up to `plugins.conf.backup`
- No manual action required

**New Commands**:
```bash
# Check for updates
wayu plugin check

# Update plugins
wayu plugin update <name>
wayu plugin update --all

# Enable/disable without removing
wayu plugin enable <name>
wayu plugin disable <name>

# Set load priority
wayu plugin priority <name> <number>

# Manage dependencies
wayu plugin dependency add <plugin> <dependency>
wayu plugin dependency list <plugin>
```

---

## Success Criteria

### Phase 1: JSON5 Configuration
- ✅ JSON5 reading/writing works
- ✅ Migration from old format succeeds
- ✅ All existing commands work with new format

### Phase 2: Update System
- ✅ `wayu plugin check` shows available updates
- ✅ `wayu plugin update <name>` updates single plugin
- ✅ `wayu plugin update --all` updates all plugins
- ✅ Git metadata tracked correctly

### Phase 3: Enable/Disable
- ✅ `wayu plugin enable/disable` toggles plugin state
- ✅ Disabled plugins don't load
- ✅ Config persists across operations

### Phase 4: Dependencies
- ✅ Dependency resolution works correctly
- ✅ Circular dependencies detected and rejected
- ✅ Load order respects dependencies

### Phase 5: Prioritization
- ✅ Priority numbers control load order
- ✅ Dependencies override priorities when needed
- ✅ Loader generated in correct order

### Phase 6: Conflicts
- ✅ Conflict scanning detects env vars, functions, aliases
- ✅ Warnings shown in loader file
- ✅ Conflicts don't block loading (warnings only)

---

## Timeline

- **Phase 1**: 2-3 days (JSON5 foundation)
- **Phase 2**: 3-4 days (Update system)
- **Phase 3**: 1-2 days (Enable/disable)
- **Phase 4**: 3-4 days (Dependencies)
- **Phase 5**: 2 days (Prioritization)
- **Phase 6**: 3 days (Conflicts)

**Total**: 14-18 days

---

## Risk Mitigation

1. **Migration failures**: Extensive testing with backup creation
2. **Git operations**: Proper error handling for network issues
3. **Circular dependencies**: DFS cycle detection prevents infinite loops
4. **Performance**: Conflict detection cached, only runs when needed

---

## Next Steps

1. Review and approve this implementation plan
2. Create feature branch: `feature/prp-15-plugin-enhancement`
3. Implement Phase 1 (JSON5 foundation)
4. Add unit tests for Phase 1
5. Iterate through remaining phases with test coverage
6. Integration testing with real plugins
7. Documentation updates
8. Release as v3.0.0 (breaking change with new config format)
