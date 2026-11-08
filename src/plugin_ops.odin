package wayu
import "core:fmt"
import "core:os"
import "core:strings"
import "core:slice"
import "core:strconv"
import "core:path/filepath"
// ── Network git ─────────────────────────────────────────────────────────
// Every git command that talks to a remote (clone, fetch, ls-remote) goes
// through run_git_network: no terminal (new session, stdin /dev/null, no
// prompts), ssh in batch mode with a connect timeout, https aborted when a
// transfer stalls, and an overall deadline after which git and its helpers
// are killed.

GIT_CLONE_TIMEOUT_MS      :: 10 * 60 * 1000 // clone / fetch: repos can be large
GIT_LS_REMOTE_TIMEOUT_MS  :: 60 * 1000      // `plugin check`: one small request
GIT_SSH_BATCH_COMMAND     :: "ssh -o BatchMode=yes -o ConnectTimeout=10"
// http.lowSpeedLimit/Time: abort an https transfer that stays below
// 1000 bytes/s for 30 s.
GIT_HTTP_LOW_SPEED_LIMIT  :: "1000"
GIT_HTTP_LOW_SPEED_TIME   :: "30"

// Overall deadline for a network git command: WAYU_GIT_TIMEOUT (whole
// seconds, > 0) when set and valid, else `default_ms`.
git_network_timeout_ms :: proc(default_ms: int) -> int {
	raw := os.get_env("WAYU_GIT_TIMEOUT", context.temp_allocator)
	if raw == "" {
		return default_ms
	}
	secs, ok := strconv.parse_int(raw)
	if !ok || secs <= 0 || secs > 24 * 60 * 60 {
		return default_ms
	}
	return secs * 1000
}

// Child-env defaults for network git (each applied only when the user's
// environment does not set it). GIT_SSH_COMMAND would also override a
// configured core.sshCommand (or GIT_SSH), so it is only added when neither
// is set — the user's ssh setup always wins; without a terminal it still
// cannot prompt. `repo_dir` ("" = none) is where repo-local config is read.
git_network_env :: proc(repo_dir: string) -> []Env_Default {
	env := make([dynamic]Env_Default, context.temp_allocator)
	append(&env, Env_Default{"GIT_HTTP_LOW_SPEED_LIMIT", GIT_HTTP_LOW_SPEED_LIMIT})
	append(&env, Env_Default{"GIT_HTTP_LOW_SPEED_TIME", GIT_HTTP_LOW_SPEED_TIME})

	if os.get_env("GIT_SSH", context.temp_allocator) == "" {
		configured: string
		if repo_dir == "" {
			configured = capture_command([]string{"git", "config", "--get", "core.sshCommand"})
		} else {
			configured = capture_command([]string{"git", "-C", repo_dir, "config", "--get", "core.sshCommand"})
		}
		defer delete(configured)
		if configured == "" {
			append(&env, Env_Default{"GIT_SSH_COMMAND", GIT_SSH_BATCH_COMMAND})
		}
	}
	return env[:]
}

// Run a git command that contacts a remote (see the section comment above).
// On timeout, stderr explains it. Result strings are ALLOCATED — release
// with command_result_destroy.
run_git_network :: proc(args: []string, default_timeout_ms: int, repo_dir := "") -> Command_Result {
	timeout_ms := git_network_timeout_ms(default_timeout_ms)
	result := run_command_timeout(args, timeout_ms, git_network_env(repo_dir))
	if result.timed_out {
		delete(result.stderr)
		result.stderr = fmt.aprintf(
			"git timed out after %ds and was stopped (set WAYU_GIT_TIMEOUT=<seconds> to allow longer)",
			timeout_ms / 1000)
	}
	return result
}

// Clone a plugin repository (shallow). `--` ends option parsing so a URL or
// destination starting with '-' can never be read as a git option.
// err_text is ALLOCATED (git's stderr, possibly empty) — caller must delete.
git_clone :: proc(url: string, dest: string) -> (ok: bool, err_text: string) {
	if wayu.dry_run {
		print_info("[DRY RUN] Would execute: git clone --depth=1 --quiet -- %s %s", url, dest)
		return true, strings.clone("")
	}

	r := run_git_network([]string{"git", "clone", "--depth=1", "--quiet", "--", url, dest}, GIT_CLONE_TIMEOUT_MS)
	delete(r.stdout)
	return r.ok, r.stderr
}

// Clone a plugin repository and check out `commit` (detached). Full clone:
// an arbitrary commit cannot be fetched shallowly from every server. After
// checkout HEAD must start with `commit`, otherwise the clone is rejected.
// `commit` must already have passed is_valid_commit_sha.
// err_text is ALLOCATED (possibly empty) — caller must delete.
git_clone_at_commit :: proc(url: string, dest: string, commit: string) -> (ok: bool, err_text: string) {
	if wayu.dry_run {
		print_info("[DRY RUN] Would execute: git clone --no-checkout --quiet -- %s %s", url, dest)
		print_info("[DRY RUN] Would execute: git -C %s checkout --quiet --detach %s", dest, commit)
		return true, strings.clone("")
	}
	if !is_valid_commit_sha(commit) {
		return false, fmt.aprintf("invalid commit '%s'", commit)
	}

	cloned := run_git_network([]string{"git", "clone", "--no-checkout", "--quiet", "--", url, dest}, GIT_CLONE_TIMEOUT_MS)
	delete(cloned.stdout)
	if !cloned.ok {
		return false, cloned.stderr
	}
	delete(cloned.stderr)

	checked_out, co_err := run_command_capture_stderr([]string{"git", "-C", dest, "checkout", "--quiet", "--detach", commit})
	if !checked_out {
		return false, co_err
	}
	delete(co_err)

	head := capture_command([]string{"git", "-C", dest, "rev-parse", "HEAD"})
	defer delete(head)
	if !strings.has_prefix(head, strings.to_lower(commit, context.temp_allocator)) {
		return false, fmt.aprintf("checked out %s, expected %s", head, commit)
	}
	return true, strings.clone("")
}

// A commit SHA as accepted by `plugin add <url>@<sha>`: 7-40 hex digits.
is_valid_commit_sha :: proc(s: string) -> bool {
	if len(s) < 7 || len(s) > 40 {
		return false
	}
	for c in s {
		is_hex := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
		if !is_hex {
			return false
		}
	}
	return true
}

// Split "<url>@<sha>" into url + commit. Only a trailing '@' followed by a
// valid SHA (and after the last '/' or ':') counts, so scp-style URLs like
// "git@host:user/repo" are left intact. commit is "" when there is no pin.
// Both results are slices of `arg`.
split_plugin_commit_pin :: proc(arg: string) -> (url: string, commit: string) {
	at := strings.last_index_byte(arg, '@')
	if at <= 0 {
		return arg, ""
	}
	sep := max(strings.last_index_byte(arg, '/'), strings.last_index_byte(arg, ':'))
	if at < sep {
		return arg, ""
	}
	if !is_valid_commit_sha(arg[at + 1:]) {
		return arg, ""
	}
	return arg[:at], arg[at + 1:]
}

GitUpdateResult :: enum {
	Failed,
	Updated,       // fast-forward (or already up to date)
	Reset,         // upstream rewrote history; checkout reset to the remote
}

// Update a managed plugin checkout to the tip of `branch` on origin
// ("" / "HEAD" = the remote's default branch).
//
// 1. git fetch origin <ref>
// 2. git merge --ff-only FETCH_HEAD          — the normal case
// 3. ff impossible (upstream force-pushed / rewrote history): reset --hard to
//    FETCH_HEAD, but ONLY for a clean checkout that wayu owns. A symlinked
//    plugin dir (a user's working copy), one with local modifications, or one
//    whose HEAD has commits that were never on the remote is never reset —
//    the update fails with an explanation instead.
//
// Git's stderr is returned on failure. err_text is ALLOCATED (possibly
// empty) — caller must delete. Not called in dry-run.
git_update :: proc(plugin_dir: string, branch: string) -> (result: GitUpdateResult, err_text: string) {
	ref := (branch == "" || branch == "HEAD") ? "HEAD" : branch
	if strings.has_prefix(ref, "-") {
		return .Failed, fmt.aprintf("invalid branch name '%s'", branch)
	}

	// Before the fetch moves the remote-tracking ref: is every commit of HEAD
	// already on the remote? If not, the checkout has local commits and a
	// reset would discard them. Any git error also counts as "not safe".
	tracking := ref == "HEAD" ? "refs/remotes/origin/HEAD" : fmt.tprintf("refs/remotes/origin/%s", ref)
	head_on_remote := run_command([]string{"git", "-C", plugin_dir, "merge-base", "--is-ancestor", "HEAD", tracking})

	fetched := run_git_network([]string{"git", "-C", plugin_dir, "fetch", "--quiet", "origin", ref}, GIT_CLONE_TIMEOUT_MS, plugin_dir)
	delete(fetched.stdout)
	if !fetched.ok {
		return .Failed, fetched.stderr
	}
	delete(fetched.stderr)

	merged, merge_err := run_command_capture_stderr([]string{"git", "-C", plugin_dir, "merge", "--ff-only", "--quiet", "FETCH_HEAD"})
	if merged {
		delete(merge_err)
		return .Updated, strings.clone("")
	}
	delete(merge_err)

	if is_symlink(plugin_dir) {
		return .Failed, strings.clone("upstream history diverged from this symlinked checkout; update it manually")
	}
	dirty := capture_command([]string{"git", "-C", plugin_dir, "status", "--porcelain", "--untracked-files=no"})
	defer delete(dirty)
	if len(dirty) > 0 {
		return .Failed, strings.clone("checkout has local modifications and cannot be fast-forwarded; commit/discard them or reinstall the plugin")
	}
	if !head_on_remote {
		return .Failed, strings.clone("checkout has local commits that are not on the remote and cannot be fast-forwarded; push/rebase them or reinstall the plugin")
	}

	reset, reset_err := run_command_capture_stderr([]string{"git", "-C", plugin_dir, "reset", "--hard", "--quiet", "FETCH_HEAD"})
	if !reset {
		return .Failed, reset_err
	}
	delete(reset_err)
	return .Reset, strings.clone("")
}

// True when `path` itself is a symbolic link (not followed).
is_symlink :: proc(path: string) -> bool {
	fi, err := os.lstat(path, context.temp_allocator)
	if err != nil {
		return false
	}
	return fi.type == .Symlink
}

// Check if directory is git repo
is_git_repo :: proc(dir: string) -> bool {
	git_dir := fmt.aprintf("%s/.git", dir)
	defer delete(git_dir)

	return os.exists(git_dir)
}

// The shells whose plugin loader would source at least one file of the
// checkout at `dir` (see get_plugin_files_to_source). With `use` globs the
// matched files' extensions decide: .fish → fish, .zsh/.zsh-theme → zsh,
// .bash → bash, anything else (.sh, no extension) → zsh and bash.
plugin_loadable_shells :: proc(name: string, dir: string, use: []string) -> bit_set[ShellType] {
	shells: bit_set[ShellType]
	if len(use) > 0 {
		files := match_files_with_globs(dir, use)
		defer {
			for f in files {
				delete(f)
			}
			delete(files)
		}
		for f in files {
			switch {
			case strings.has_suffix(f, ".fish"):
				shells += {.FISH}
			case strings.has_suffix(f, ".zsh"), strings.has_suffix(f, ".zsh-theme"):
				shells += {.ZSH}
			case strings.has_suffix(f, ".bash"):
				shells += {.BASH}
			case:
				shells += {.ZSH, .BASH}
			}
		}
		return shells
	}

	probe := PluginMetadata{name = name, installed_path = dir}
	for shell in ([]ShellType{.ZSH, .BASH, .FISH}) {
		if plugin_has_files_to_source(probe, shell) {
			shells += {shell}
		}
	}
	return shells
}

// The ShellCompat recorded for a plugin added by URL: the shells it has
// something to load for. ok = false when it has nothing for any shell.
// zsh+fish or bash+fish have no exact value and become ANY (the loader
// then simply finds nothing for the third shell).
shell_compat_from_loadable :: proc(shells: bit_set[ShellType]) -> (compat: ShellCompat, ok: bool) {
	s := shells & {.ZSH, .BASH, .FISH}
	if s == {}            { return .BOTH, false }
	if s == {.ZSH}        { return .ZSH, true }
	if s == {.BASH}       { return .BASH, true }
	if s == {.FISH}       { return .FISH, true }
	if s == {.ZSH, .BASH} { return .BOTH, true }
	return .ANY, true
}

// True when `compat` lets at least one shell in `shells` load the plugin.
plugin_compat_loads_any :: proc(compat: ShellCompat, shells: bit_set[ShellType]) -> bool {
	for shell in ([]ShellType{.ZSH, .BASH, .FISH}) {
		if shell in shells && plugin_compat_matches(compat, shell) {
			return true
		}
	}
	return false
}

// A `plugin add --use` glob: matched against file names at the plugin's
// repository root, so it must be a non-empty name pattern (no '/', no
// control characters, not "." or "..").
is_valid_use_glob :: proc(glob: string) -> bool {
	if glob == "" || glob == "." || glob == ".." {
		return false
	}
	for c in glob {
		if c == '/' || c < 0x20 || c == 0x7f {
			return false
		}
	}
	return true
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
// Plugin code is sourced into every shell, so it may only be fetched over an
// authenticated/encrypted transport (https, ssh, scp-style git@) or from the
// local filesystem (file://). Plaintext http:// and git:// are refused.
is_valid_git_url :: proc(url: string) -> bool {
	return plugin_url_problem(url) == ""
}

// True for URLs that look like git remotes but use a plaintext transport.
is_insecure_git_url :: proc(url: string) -> bool {
	return strings.has_prefix(url, "http://") || strings.has_prefix(url, "git://")
}

// Why `url` is not an acceptable plugin URL, or "" when it is. The result is
// a static string. Also used to validate plugins.json on load.
plugin_url_problem :: proc(url: string) -> string {
	if len(url) == 0 {
		return "URL is empty"
	}
	if strings.has_prefix(url, "-") {
		return "URL must not start with '-'"
	}
	for c in url {
		if c < 0x20 || c == 0x7f || c == ' ' {
			return "URL contains whitespace or control characters"
		}
	}
	if is_insecure_git_url(url) {
		return "plaintext http:// and git:// URLs are refused (use https:// or ssh)"
	}
	if !(strings.has_prefix(url, "https://") ||
	     strings.has_prefix(url, "ssh://") ||
	     strings.has_prefix(url, "git@") ||
	     strings.has_prefix(url, "file://")) {
		return "URL must start with https://, ssh://, git@ or file://"
	}
	if !is_safe_shell_arg(url) {
		return "URL contains shell metacharacters"
	}
	return ""
}

// Why a git ref-like field (branch/tag/commit) from plugins.json is unsafe to
// hand to git, or "" when it is fine. Empty values are allowed.
plugin_ref_problem :: proc(ref: string) -> string {
	if len(ref) == 0 {
		return ""
	}
	if strings.has_prefix(ref, "-") {
		return "must not start with '-'"
	}
	for c in ref {
		if c < 0x20 || c == 0x7f || c == ' ' {
			return "contains whitespace or control characters"
		}
	}
	return ""
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

PluginDirRemoval :: enum {
	Removed,  // directory deleted, or symlink unlinked (target untouched)
	Missing,  // nothing at that path
	Outside,  // refused: not strictly inside the plugins root
	Failed,
}

// Delete an installed plugin's directory without ever following a symlink.
//
// os.remove_all opendir()s its argument, which follows a symlink, so on a
// symlinked plugin dir (a user's working copy linked into plugins/) it would
// empty the link TARGET. Here a symlink is only unlinked. A real directory is
// removed only if its fully resolved path is still inside the resolved
// plugins root (catches symlinked parent components and "..").
remove_plugin_dir_safely :: proc(path: string, plugins_dir: string) -> PluginDirRemoval {
	if !is_path_inside_dir(path, plugins_dir) {
		return .Outside
	}

	fi, lerr := os.lstat(path, context.temp_allocator)
	if lerr != nil {
		if lerr == os.General_Error.Not_Exist {
			return .Missing
		}
		return .Failed
	}

	if fi.type == .Symlink {
		return os.remove(path) == nil ? .Removed : .Failed
	}

	real_path, perr := os.get_absolute_path(path, context.temp_allocator)
	real_root, rerr := os.get_absolute_path(plugins_dir, context.temp_allocator)
	if perr != nil || rerr != nil {
		return .Failed
	}
	if !is_path_inside_dir(real_path, real_root) {
		return .Outside
	}

	if fi.type != .Directory {
		return os.remove(path) == nil ? .Removed : .Failed
	}
	return os.remove_all(path) == nil ? .Removed : .Failed
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

// Find plugin in JSON config by EXACT name (or exact display name).
// Never prompts and never fuzzy-matches. User-facing commands go through
// find_plugin_or_exit, which adds the "did you mean" miss report.
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

// Exact lookup for every CLI plugin subcommand that takes a name (update,
// enable, disable, priority, get, rm). Same contract as `const get`: a miss
// never acts on a fuzzy guess (`plugin disable rig` used to disable
// `origin`); it prints the error plus up to GET_SUGGESTION_LIMIT similar
// plugin names on stderr, nothing on stdout, and exits EXIT_DATAERR.
find_plugin_or_exit :: proc(config: ^PluginConfigJSON, name: string) -> ^PluginMetadata {
	if p, ok := find_plugin_json(config, name); ok {
		return p
	}
	exit_plugin_not_found(config, name)
}

exit_plugin_not_found :: proc(config: ^PluginConfigJSON, query: string) -> ! {
	names := make([dynamic]string, 0, len(config.plugins), context.temp_allocator)
	for plugin in config.plugins {
		if plugin.name != "" { append(&names, plugin.name) }
	}
	print_error_simple("Plugin not found: %s", query)
	suggestions := suggest_similar_names(query, names[:], GET_SUGGESTION_LIMIT, context.temp_allocator)
	if len(suggestions) > 0 {
		fmt.eprintln("Did you mean:")
		for name in suggestions { fmt.eprintfln("  %s", name) }
	}
	fmt.eprintln("Run 'wayu plugin list' to see installed plugins")
	os.exit(EXIT_DATAERR)
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
	// Never hand git a value it could parse as an option (plugins.json is
	// validated on load; this is the last line of defence).
	if plugin_url_problem(url) != "" || plugin_ref_problem(branch) != "" {
		return ""
	}

	// Query the EXACT ref: ls-remote patterns match by tail, so a bare
	// "main" also matches refs/heads/aaa/main or refs/tags/main, which sort
	// first. HEAD (remote default branch) when no branch is recorded.
	ref := (branch == "" || branch == "HEAD") ? "HEAD" : fmt.tprintf("refs/heads/%s", branch)

	// Output format: "<40-char-SHA>\t<ref-name>\n" per matching ref.
	// `--` ends option parsing so the URL can never be read as an option.
	result := run_git_network([]string{"git", "ls-remote", "--", url, ref}, GIT_LS_REMOTE_TIMEOUT_MS)
	defer command_result_destroy(&result)
	if !result.ok {
		return ""
	}

	for line in strings.split_lines(result.stdout, context.temp_allocator) {
		tab := strings.index_byte(line, '\t')
		if tab <= 0 {
			continue
		}
		if strings.trim_space(line[tab + 1:]) != ref {
			continue
		}
		// Return the full SHA — ALLOCATED, caller must delete. Comparison
		// against the (abbreviated) local commit uses git_commits_match.
		return strings.clone(line[:tab])
	}
	return ""
}


// ============================================================================
// CLI command handlers (merged from plugin_operations.odin)
// ============================================================================




// Handle plugin check command - check for available updates
// CLI-only command (no interactive mode)
// Checks all enabled plugins for updates using git ls-remote

