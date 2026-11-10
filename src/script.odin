// script.odin - `wayu script {new,edit,list,remove,import,build}`
//
// Scripts are standalone executables in any language of the table in
// script_langs.odin. Sources live in <data>/scripts/NAME.<ext> (the
// directory is the source of truth: there is no list of names elsewhere);
// <data>/bin/NAME is what runs, and core.<ext> puts <data>/bin first among
// wayu's PATH entries (see script_path_value):
//   interpreted: bin/NAME is a relative symlink to ../scripts/NAME.<ext>
//                and the source is 0755 (its shebang runs it);
//   compiled:    bin/NAME is the compiler's output, and bin/.NAME.hash holds
//                the FNV-1a hash of the source it was built from. The build
//                is stale when the hash differs or the binary is missing.
// Strings are temp-allocated throughout (short-lived CLI work; the watcher
// frees its temp allocator per poll).

package wayu

import "core:fmt"
import "core:hash"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"

// Seconds a compiler may run before it is killed (swiftc cold starts are slow).
SCRIPT_COMPILE_TIMEOUT_MS :: 10 * 60 * 1000

ScriptInfo :: struct {
	name:   string, // command name (bin/NAME)
	source: string, // <data>/scripts/<file>
	bin:    string, // <data>/bin/NAME
	lang:   ^ScriptLang, // nil: unknown (no shebang, unknown extension)
}

scripts_dir :: proc() -> string {return fmt.tprintf("%s/scripts", wayu.data)}
scripts_bin_dir :: proc() -> string {return fmt.tprintf("%s/bin", wayu.data)}

@(private = "file")
script_hash_file :: proc(name: string) -> string {
	return fmt.tprintf("%s/.%s.hash", scripts_bin_dir(), name)
}

// The value core.<ext> / path_sync put first among wayu's PATH entries, ""
// while <data>/bin holds no script: PATH is unchanged until the first
// script exists, and the PATH signature changes then, so open shells pick
// the dir up at their next prompt (script_sync_path). Temp-allocated.
script_path_value :: proc() -> string {
	dir := scripts_bin_dir()
	if !is_path_entry_safe(dir) {
		return ""
	}
	handle, err := os.open(dir)
	if err != nil {
		return ""
	}
	defer os.close(handle)
	infos, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil {
		return ""
	}
	for info in infos {
		if !strings.has_prefix(info.name, ".") {
			return dir
		}
	}
	return ""
}

// Regenerate the init files when <data>/bin went on or off PATH since
// `had_bin` (script_path_value before the change).
script_sync_path :: proc(had_bin: bool) {
	if had_bin != (len(script_path_value()) > 0) {
		regenerate_init_core_silently()
	}
}

// Name and extension of a source file name: `foo.py` → ("foo", "py");
// an extension no language uses stays part of the name (`foo.bar`, "").
script_split_file_name :: proc(file: string) -> (name: string, ext: string) {
	dot := strings.last_index_byte(file, '.')
	if dot > 0 && script_lang_by_ext(file[dot + 1:]) != nil {
		return file[:dot], file[dot + 1:]
	}
	return file, ""
}

// First line of `content` (no newline).
@(private = "file")
first_line :: proc(content: string) -> string {
	if i := strings.index_byte(content, '\n'); i >= 0 {
		return content[:i]
	}
	return content
}

// Language of a source: its shebang's interpreter, else its extension.
script_lang_of :: proc(file_name: string, content: string) -> ^ScriptLang {
	if interp := script_shebang_interpreter(first_line(content)); len(interp) > 0 {
		if l := script_lang_by_interpreter(script_basename(interp)); l != nil {
			return l
		}
	}
	_, ext := script_split_file_name(file_name)
	if len(ext) > 0 {
		return script_lang_by_ext(ext)
	}
	return nil
}

// Up to 4 KiB of the head of `path` (enough for a shebang and the binary
// check). Temp-allocated; "" when unreadable.
@(private = "file")
read_head :: proc(path: string, limit := 4096) -> string {
	f, err := os.open(path)
	if err != nil {
		return ""
	}
	defer os.close(f)
	buf := make([]byte, limit, context.temp_allocator)
	n, _ := os.read(f, buf)
	if n < 0 {
		n = 0
	}
	return string(buf[:n])
}

// Every script in <data>/scripts, sorted by name. Temp-allocated.
script_list_all :: proc() -> [dynamic]ScriptInfo {
	out := make([dynamic]ScriptInfo, context.temp_allocator)
	dir := scripts_dir()
	handle, err := os.open(dir)
	if err != nil {
		return out
	}
	defer os.close(handle)
	infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
	if read_err != nil {
		return out
	}
	for info in infos {
		if info.type != .Regular || strings.has_prefix(info.name, ".") {
			continue
		}
		name, _ := script_split_file_name(info.name)
		src := fmt.tprintf("%s/%s", dir, info.name)
		append(
			&out,
			ScriptInfo {
				name = strings.clone(name, context.temp_allocator),
				source = src,
				bin = fmt.tprintf("%s/%s", scripts_bin_dir(), name),
				lang = script_lang_of(info.name, read_head(src)),
			},
		)
	}
	slice.sort_by(out[:], proc(a, b: ScriptInfo) -> bool {return a.name < b.name})
	return out
}

script_find :: proc(name: string) -> (ScriptInfo, bool) {
	for s in script_list_all() {
		if s.name == name {
			return s, true
		}
	}
	return {}, false
}

script_is_compiled :: proc(s: ScriptInfo) -> bool {
	if s.lang == nil {
		return false
	}
	_, ok := s.lang.compile.?
	return ok
}

// FNV-1a of the source as hex, "" when unreadable. Temp-allocated.
@(private = "file")
script_source_hash :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return ""
	}
	return fmt.tprintf("%x", hash.fnv64a(data))
}

// Relative symlink target of an interpreted script's bin entry.
@(private = "file")
script_link_target :: proc(s: ScriptInfo) -> string {
	return fmt.tprintf("../scripts/%s", script_basename(s.source))
}

// Does bin/NAME need (re)building?
script_is_stale :: proc(s: ScriptInfo) -> bool {
	info, err := os.lstat(s.bin, context.temp_allocator)
	if err != nil {
		return true
	}
	if script_is_compiled(s) {
		if info.type != .Regular {
			return true
		}
		stored, rerr := os.read_entire_file_from_path(
			script_hash_file(s.name),
			context.temp_allocator,
		)
		if rerr != nil {
			return true
		}
		return strings.trim_space(string(stored)) != script_source_hash(s.source)
	}
	if info.type != .Symlink {
		return true
	}
	target, lerr := os.read_link(s.bin, context.temp_allocator)
	if lerr != nil || target != script_link_target(s) {
		return true
	}
	// The symlink is fine, but the source must stay executable.
	return !script_is_executable(s.source)
}

@(private = "file")
script_is_executable :: proc(path: string) -> bool {
	return posix.access(strings.clone_to_cstring(path, context.temp_allocator), {.X_OK}) == .OK
}

// Absolute path of `cmd` on $PATH (an executable regular file), else "".
// Temp-allocated.
script_find_on_path :: proc(cmd: string) -> string {
	if len(cmd) == 0 {
		return ""
	}
	if strings.contains_rune(cmd, '/') {
		return cmd if os.is_file(cmd) && script_is_executable(cmd) else ""
	}
	path_env := os.get_env("PATH", context.temp_allocator)
	for dir in strings.split(path_env, ":", context.temp_allocator) {
		if len(dir) == 0 {
			continue
		}
		full := fmt.tprintf("%s/%s", dir, cmd)
		if os.is_file(full) && script_is_executable(full) {
			return full
		}
	}
	return ""
}

// Create <data>/scripts and <data>/bin. Returns false after printing why.
script_ensure_dirs :: proc() -> bool {
	for dir in ([]string{scripts_dir(), scripts_bin_dir()}) {
		if os.is_dir(dir) {
			continue
		}
		if err := make_directory_all(dir); err != nil {
			print_error_simple("Failed to create directory: %s", dir)
			return false
		}
	}
	return true
}

// Remove bin/NAME (and its hash) whatever it is. Missing is fine.
@(private = "file")
script_remove_bin :: proc(name: string) {
	bin := fmt.tprintf("%s/%s", scripts_bin_dir(), name)
	if _, err := os.lstat(bin, context.temp_allocator); err == nil {
		_ = os.remove(bin)
	}
	if os.exists(script_hash_file(name)) {
		_ = os.remove(script_hash_file(name))
	}
}

// (Re)build one script. Prints the reason and returns false on failure; a
// failed compile keeps the previous binary.
script_build :: proc(s: ScriptInfo, quiet := false) -> bool {
	if s.lang == nil {
		print_error_simple("%s: unknown language (no shebang and no known extension)", s.source)
		return false
	}
	if !script_ensure_dirs() {
		return false
	}

	if comp, ok := s.lang.compile.?; ok {
		compiler := script_find_on_path(comp.compiler)
		if len(compiler) == 0 {
			print_error_simple("Cannot build '%s': %s not found on PATH", s.name, comp.compiler)
			return false
		}
		// Hash the source as it is before the compiler reads it (OKAMI-311):
		// an edit saved during the compile then leaves the binary stale
		// instead of recording the new source as built.
		src_hash := script_source_hash(s.source)
		tmp := fmt.tprintf("%s/.%s.build", scripts_bin_dir(), s.name)
		args := make([dynamic]string, context.temp_allocator)
		append(&args, compiler)
		append(&args, ..comp.args)
		append(&args, "-o", tmp, s.source)
		if !quiet {
			print_info("Compiling %s (%s)...", s.name, comp.compiler)
		}
		res := run_command_timeout(args[:], SCRIPT_COMPILE_TIMEOUT_MS)
		defer command_result_destroy(&res)
		if !res.ok || !os.is_file(tmp) {
			if os.exists(tmp) {
				_ = os.remove(tmp)
			}
			print_error_simple(
				"Build of '%s' failed%s",
				s.name,
				" (timed out)" if res.timed_out else "",
			)
			if len(res.stderr) > 0 {
				fmt.eprintln(res.stderr)
			}
			if len(res.stdout) > 0 {
				fmt.eprintln(res.stdout)
			}
			return false
		}
		if bin_info, err := os.lstat(s.bin, context.temp_allocator);
		   err == nil && bin_info.type != .Regular {
			_ = os.remove(s.bin)
		}
		if err := os.rename(tmp, s.bin); err != nil {
			_ = os.remove(tmp)
			print_error_simple("Failed to install %s", s.bin)
			return false
		}
		_ = os.chmod(s.bin, os.perm_number(0o755))
		if write_file_atomic(script_hash_file(s.name), transmute([]byte)src_hash) != nil {
			print_warning("Failed to write %s", script_hash_file(s.name))
		}
		if !quiet {
			print_success("Built %s", s.bin)
		}
		return true
	}

	if err := os.chmod(s.source, os.perm_number(0o755)); err != nil {
		print_error_simple("Failed to make %s executable", s.source)
		return false
	}
	script_remove_bin(s.name)
	if err := os.symlink(script_link_target(s), s.bin); err != nil {
		print_error_simple("Failed to link %s", s.bin)
		return false
	}
	if !quiet {
		print_success("Linked %s -> %s", s.bin, script_link_target(s))
	}
	return true
}

// Rebuild every stale script (wayu build, the watcher, script build).
// Returns how many were built and how many failed.
scripts_build_stale :: proc(quiet := false) -> (built: int, failed: int) {
	if wayu.dry_run {
		return
	}
	for s in script_list_all() {
		if !script_is_stale(s) {
			continue
		}
		if script_build(s, quiet) {
			built += 1
		} else {
			failed += 1
		}
	}
	return
}

// [scripts] default_lang, else SCRIPT_DEFAULT_LANG.
script_default_lang :: proc() -> string {
	content, ok := get_cached_toml_content()
	if !ok {
		return SCRIPT_DEFAULT_LANG
	}
	doc, _ := toml_doc_parse_alloc(content, context.temp_allocator)
	scripts, has := doc.values["scripts"]
	if !has || scripts == nil || scripts.type != .TABLE {
		return SCRIPT_DEFAULT_LANG
	}
	if v, found := scripts.table_val["default_lang"]; found {
		if v != nil && v.type == .STRING {
			return v.str_val
		}
	}
	return SCRIPT_DEFAULT_LANG
}

// toml_schema_issues hook: the error for a bad `[scripts] default_lang`,
// "" when `p` is another key or the value is fine. Temp-allocated.
script_default_lang_issue :: proc(p: []string, v: ^TomlValue) -> string {
	if len(p) != 2 || p[0] != "scripts" || p[1] != "default_lang" {
		return ""
	}
	if v == nil || v.type != .STRING {
		return "scripts.default_lang must be a string"
	}
	if script_lang_by_name(v.str_val) == nil {
		return fmt.tprintf(
			"scripts.default_lang: unknown language '%s' (expected one of: %s)",
			v.str_val,
			script_lang_names(),
		)
	}
	return ""
}

// Validate a script name (it becomes a file name and a command). Exits.
@(private = "file")
script_require_valid_name :: proc(name: string) {
	result := validate_identifier(name, "Script", allow_hyphen = true)
	if !result.valid {
		print_error("%s", result.error_message)
		delete(result.error_message)
		os.exit(EXIT_DATAERR)
	}
}

@(private = "file")
script_require_existing :: proc(name: string) -> ScriptInfo {
	script_require_valid_name(name)
	s, ok := script_find(name)
	if !ok {
		print_error_simple("Script not found: %s", name)
		os.exit(EXIT_DATAERR)
	}
	return s
}

// ---------------------------------------------------------------------------
// Command handlers
// ---------------------------------------------------------------------------

// Command-line options of `wayu script` (parsed from the handler's args).
@(private = "file")
ScriptOpts :: struct {
	lang:  string,
	copy:  bool,
	words: [dynamic]string, // positional arguments
}

@(private = "file")
script_parse_opts :: proc(args: []string) -> ScriptOpts {
	o := ScriptOpts {
		words = make([dynamic]string, context.temp_allocator),
	}
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		switch {
		case a == "--copy":
			o.copy = true
		case a == "--lang":
			if i + 1 >= len(args) {
				print_error_simple("--lang needs a value (one of: %s)", script_lang_names())
				os.exit(EXIT_USAGE)
			}
			o.lang = args[i + 1]
			i += 1
		case strings.has_prefix(a, "--lang="):
			o.lang = strings.trim_prefix(a, "--lang=")
		case:
			append(&o.words, a)
		}
	}
	if len(o.lang) > 0 && script_lang_by_name(o.lang) == nil {
		print_error_simple(
			"Unknown --lang '%s' (expected one of: %s)",
			o.lang,
			script_lang_names(),
		)
		os.exit(EXIT_USAGE)
	}
	return o
}

handle_script_command :: proc(action: Action, args: []string) {
	opts := script_parse_opts(args)
	words := opts.words[:]
	need_name :: proc(words: []string, usage: string) -> string {
		if len(words) < 1 {
			print_error_simple("Script name required. Usage: wayu script %s", usage)
			os.exit(EXIT_USAGE)
		}
		return words[0]
	}
	#partial switch action {
	case .ADD:
		script_new(need_name(words, "new <name> [--lang <lang>]"), opts.lang)
	case .UPDATE:
		script_edit(need_name(words, "edit <name>"))
	case .LIST:
		script_list()
	case .REMOVE:
		script_remove(need_name(words, "remove <name> --yes"))
	case .IMPORT:
		if len(words) == 0 {
			print_error_simple("Nothing to import. Usage: wayu script import <file>... [--copy]")
			os.exit(EXIT_USAGE)
		}
		script_import(words, opts.copy)
	case .BUILD:
		script_build_command(words)
	case .HELP:
		print_script_usage()
	case:
		fmt.eprintln("Unknown script action")
		print_script_usage()
		os.exit(EXIT_USAGE)
	}
}

script_new :: proc(name: string, lang_flag: string) {
	script_require_valid_name(name)
	lang_name := lang_flag
	if len(lang_name) == 0 {
		lang_name = script_default_lang()
		if script_lang_by_name(lang_name) == nil {
			print_error_simple(
				"wayu.toml [scripts] default_lang: unknown language '%s' (expected one of: %s)",
				lang_name,
				script_lang_names(),
			)
			os.exit(EXIT_CONFIG)
		}
	}
	lang := script_lang_by_name(lang_name)

	if existing, ok := script_find(name); ok {
		print_error_simple(
			"Script '%s' already exists: %s (open it with: wayu script edit %s)",
			name,
			existing.source,
			name,
		)
		os.exit(EXIT_DATAERR)
	}

	// Shebang: the interpreter found on PATH now. A compiled language needs
	// its compiler; the interpreter there only documents direct runs.
	interp := ""
	for cand in lang.interpreters {
		if p := script_find_on_path(cand); len(p) > 0 {
			interp = p; break
		}
	}
	if comp, ok := lang.compile.?; ok {
		if len(script_find_on_path(comp.compiler)) == 0 {
			print_error_simple(
				"%s scripts need %s, which is not on PATH",
				lang.name,
				comp.compiler,
			)
			os.exit(EXIT_UNAVAILABLE)
		}
		if len(interp) == 0 {
			interp = fmt.tprintf("/usr/bin/env %s", lang.interpreters[0])
		}
	} else if len(interp) == 0 {
		print_error_simple(
			"No %s interpreter on PATH (looked for: %s)",
			lang.name,
			strings.join(lang.interpreters, ", ", context.temp_allocator),
		)
		os.exit(EXIT_UNAVAILABLE)
	}

	source := fmt.tprintf("%s/%s.%s", scripts_dir(), name, lang.ext)
	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.printfln(
			"Would create %s (#!%s), open it in $EDITOR and build %s/%s",
			source,
			interp,
			scripts_bin_dir(),
			name,
		)
		return
	}

	// The lock covers the skeleton write and the build, never the editor
	// (OKAMI-307): an editor session that runs wayu (`wayu alias add` from
	// :!) or simply stays open would otherwise block every other write.
	config_lock_acquire_or_exit()
	if existing, ok := script_find(name); ok {
		config_lock_release()
		print_error_simple(
			"Script '%s' already exists: %s (open it with: wayu script edit %s)",
			name,
			existing.source,
			name,
		)
		os.exit(EXIT_DATAERR)
	}
	if !script_ensure_dirs() {
		config_lock_release()
		os.exit(EXIT_CANTCREAT)
	}
	skeleton := script_skeleton(lang, name, context.temp_allocator)
	content := fmt.tprintf("#!%s\n%s", interp, skeleton)
	if write_file_atomic(source, transmute([]byte)content) != nil {
		config_lock_release()
		print_error_simple("Failed to create %s", source)
		os.exit(EXIT_CANTCREAT)
	}
	_ = os.chmod(source, os.perm_number(0o755))
	config_lock_release()
	print_success("Created script: %s", source)

	_, edit_ok := editor_maybe_open(source)
	if !edit_ok {
		os.exit(EXIT_FAILURE)
	}

	config_lock_acquire_or_exit()
	defer config_lock_release()
	s, found := script_find(name)
	if !found {
		print_error_simple("Script '%s' was removed while it was being edited", name)
		os.exit(EXIT_NOINPUT)
	}
	// had_bin: was <data>/bin on PATH before this script's bin entry?
	had_bin := len(script_path_value()) > 0
	ok := script_build(s)
	script_sync_path(had_bin)
	if !ok {
		os.exit(EXIT_FAILURE)
	}
}

script_edit :: proc(name: string) {
	s := script_require_existing(name)
	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.printfln("Would open %s in $EDITOR and rebuild %s", s.source, s.bin)
		return
	}
	_, edit_ok := editor_maybe_open(s.source)
	if !edit_ok {
		os.exit(EXIT_FAILURE)
	}
	config_lock_acquire_or_exit()
	defer config_lock_release()
	// The language may have changed with the shebang.
	s, _ = script_find(name)
	if !script_is_stale(s) {
		print_info("%s is up to date", s.bin)
		return
	}
	if !script_build(s) {
		os.exit(EXIT_FAILURE)
	}
}

script_list :: proc() {
	scripts := script_list_all()
	if wayu.json_output {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"scripts": [`)
		for s, i in scripts {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			q :: proc(b: ^strings.Builder, s: string) {
				e := json_escape(s)
				defer delete(e)
				fmt.sbprintf(b, `"%s"`, e)
			}
			strings.write_string(&b, `{"name": `); q(&b, s.name)
			strings.write_string(&b, `, "lang": `); q(&b, s.lang.name if s.lang != nil else "")
			strings.write_string(&b, `, "source": `); q(&b, s.source)
			strings.write_string(&b, `, "bin": `); q(&b, s.bin)
			fmt.sbprintf(
				&b,
				`, "compiled": %v, "stale": %v}`,
				script_is_compiled(s),
				script_is_stale(s),
			)
		}
		fmt.sbprintf(&b, `], "count": %d}`, len(scripts))
		fmt.println(strings.to_string(b))
		return
	}
	if len(scripts) == 0 {
		print_info(
			"No scripts yet. Create one with: wayu script new <name> (or import: wayu script import <file>)",
		)
		return
	}
	print_header("Scripts", "📜")
	width := 0
	for s in scripts {width = max(width, len(s.name))}
	for s in scripts {
		state := "stale" if script_is_stale(s) else "ok"
		fmt.printfln(
			"  %s%s  %-6s  %-5s  %s",
			s.name,
			strings.repeat(" ", width - len(s.name), context.temp_allocator),
			s.lang.name if s.lang != nil else "?",
			state,
			s.source,
		)
	}
}

script_remove :: proc(name: string) {
	s := script_require_existing(name)
	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.printfln("Would delete %s and %s", s.source, s.bin)
		return
	}
	if !wayu.yes_flag {
		fmt.printfln("This will delete %s and %s. Pass --yes to confirm.", s.source, s.bin)
		os.exit(EXIT_USAGE)
	}
	config_lock_acquire_or_exit()
	defer config_lock_release()
	// The source is the only copy of the user's code: no backup, no delete.
	if !create_backup_cli(s.source) {
		os.exit(EXIT_IOERR)
	}
	had_bin := len(script_path_value()) > 0
	defer script_sync_path(had_bin)
	script_remove_bin(s.name)
	if err := os.remove(s.source); err != nil {
		print_error_simple("Failed to remove %s", s.source)
		os.exit(EXIT_IOERR)
	}
	print_success("Removed script: %s", name)
}

script_build_command :: proc(names: []string) {
	if len(names) > 0 {
		for name in names {
			s := script_require_existing(name)
			if wayu.dry_run {
				fmt.printfln("Would build %s", s.bin)
				continue
			}
			config_lock_acquire_or_exit()
			had_bin := len(script_path_value()) > 0
			ok := script_build(s)
			script_sync_path(had_bin)
			config_lock_release()
			if !ok {
				os.exit(EXIT_FAILURE)
			}
		}
		return
	}
	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		n := 0
		for s in script_list_all() {
			if script_is_stale(s) {
				fmt.printfln("Would build %s", s.bin); n += 1
			}
		}
		if n == 0 {
			print_info("All scripts are up to date")
		}
		return
	}
	config_lock_acquire_or_exit()
	defer config_lock_release()
	had_bin := len(script_path_value()) > 0
	built, failed := scripts_build_stale()
	script_sync_path(had_bin)
	if built == 0 && failed == 0 {
		print_info("All scripts are up to date")
	}
	if failed > 0 {
		os.exit(EXIT_FAILURE)
	}
}

// ---------------------------------------------------------------------------
// Import
// ---------------------------------------------------------------------------

// What `script import` does with one file: import it as NAME.<ext> in
// `lang`, or skip it for `reason`.
ScriptImportPlan :: struct {
	path:        string,
	name:        string,
	ext:         string,
	lang:        ^ScriptLang,
	reason:      string, // non-empty: skipped
	// Prepend this shebang when importing (file had none). "" = keep as is.
	add_shebang: string,
}

// Shebang paths that point inside a package manager's environment: the
// file is a generated launcher, not the user's script.
@(private = "file")
SCRIPT_MANAGED_SHEBANG_MARKERS :: []string {
	"/pipx/",
	"/uv/",
	"/.venv/",
	"/venv/",
	"/venvs/",
	"/virtualenvs/",
	"site-packages",
	"/.pyenv/versions/",
}

// Classify a file by name and content (the head is enough). Pure: the
// filesystem checks (symlink, regular file, existing names) are done by
// script_plan_import. Temp-allocated.
script_classify_content :: proc(
	file_name: string,
	content: string,
) -> (
	name: string,
	ext: string,
	lang: ^ScriptLang,
	reason: string,
) {
	if strings.index_byte(content, 0) >= 0 {
		return "", "", nil, "binary file"
	}
	if len(content) >= 4 {
		magic := content[:4]
		switch magic {
		case "\x7fELF",
		     "\xfe\xed\xfa\xce",
		     "\xfe\xed\xfa\xcf",
		     "\xce\xfa\xed\xfe",
		     "\xcf\xfa\xed\xfe",
		     "\xca\xfe\xba\xbe":
			return "", "", nil, "binary file"
		}
	}

	name, ext = script_split_file_name(file_name)
	line := first_line(content)
	if strings.has_prefix(line, "#!") {
		for m in SCRIPT_MANAGED_SHEBANG_MARKERS {
			if strings.contains(line, m) {
				return name, ext, nil, fmt.tprintf(
					"launcher generated by a package manager (%s)",
					strings.trim_space(line[2:]),
				)
			}
		}
		interp := script_shebang_interpreter(line)
		lang = script_lang_by_interpreter(script_basename(interp))
		if lang == nil {
			return name, ext, nil, fmt.tprintf("unknown interpreter '%s'", interp)
		}
	} else {
		if len(ext) == 0 {
			return name, ext, nil, "no shebang and no known extension"
		}
		lang = script_lang_by_ext(ext)
	}

	if target, ok := script_exec_launcher_target(content); ok {
		return name, ext, nil, fmt.tprintf("launcher for %s", target)
	}
	if lang.name == "python" && script_is_console_scripts_stub(content) {
		return name,
			ext,
			nil,
			"launcher generated by a package manager (console_scripts entry point)"
	}
	// Keep a known extension (bun runs .js as JS, not TS); else the language's.
	if len(ext) == 0 {
		ext = lang.ext
	}
	return name, ext, lang, ""
}

// Non-blank lines of `content` that are not `#` comments (the shebang
// included). Temp-allocated.
@(private = "file")
code_lines :: proc(content: string) -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	for raw in strings.split_lines(content, context.temp_allocator) {
		l := strings.trim_space(raw)
		if len(l) == 0 || l[0] == '#' {
			continue
		}
		append(&out, l)
	}
	return out
}

// A shell wrapper whose only command is `exec "/abs/path" "$@"` (path
// quoted or not): returns the path.
script_exec_launcher_target :: proc(content: string) -> (string, bool) {
	lines := code_lines(content)
	if len(lines) != 1 {
		return "", false
	}
	l := lines[0]
	if !strings.has_prefix(l, "exec ") {
		return "", false
	}
	rest := strings.trim_space(l[len("exec "):])
	target: string
	if len(rest) > 0 && (rest[0] == '"' || rest[0] == '\'') {
		end := strings.index_byte(rest[1:], rest[0])
		if end < 0 {
			return "", false
		}
		target = rest[1:end + 1]
		rest = strings.trim_space(rest[end + 2:])
	} else {
		sp := strings.index_byte(rest, ' ')
		if sp < 0 {
			return "", false
		}
		target = rest[:sp]
		rest = strings.trim_space(rest[sp:])
	}
	if !strings.has_prefix(target, "/") {
		return "", false
	}
	if rest != `"$@"` && rest != `$@` && rest != `"${@}"` {
		return "", false
	}
	return target, true
}

// pip/uv/pipx console_scripts stub: `from PKG import FN` ... `sys.exit(FN())`
// in a handful of lines.
script_is_console_scripts_stub :: proc(content: string) -> bool {
	lines := code_lines(content)
	if len(lines) > 12 {
		return false
	}
	for l in lines {
		if !strings.has_prefix(l, "from ") {
			continue
		}
		i := strings.index(l, " import ")
		if i < 0 {
			continue
		}
		fn := strings.trim_space(l[i + len(" import "):])
		if len(fn) == 0 || strings.contains_any(fn, " ,()") {
			continue
		}
		call := fmt.tprintf("sys.exit(%s())", fn)
		for m in lines {
			if strings.contains(m, call) {
				return true
			}
		}
	}
	return false
}

// Plan the import of `path` (filesystem checks + script_classify_content).
// `taken` holds names already used (existing scripts, earlier files).
script_plan_import :: proc(path: string, taken: []string) -> ScriptImportPlan {
	plan := ScriptImportPlan {
		path = path,
	}
	base := script_basename(path)
	info, err := os.lstat(path, context.temp_allocator)
	switch {
	case err != nil:
		plan.reason = "not found"
		return plan
	case info.type == .Symlink:
		plan.reason = "symlink"
		return plan
	case info.type != .Regular:
		plan.reason = "not a regular file"
		return plan
	}
	plan.name, plan.ext, plan.lang, plan.reason = script_classify_content(base, read_head(path))
	if len(plan.reason) > 0 {
		return plan
	}

	result := validate_identifier(plan.name, "Script", allow_hyphen = true)
	if !result.valid {
		plan.reason = fmt.tprintf("invalid name: %s", result.error_message)
		delete(result.error_message)
		return plan
	}
	if slice.contains(taken, plan.name) {
		plan.reason = fmt.tprintf("a script named '%s' already exists", plan.name)
		return plan
	}
	// No shebang (known extension only): an interpreted script needs one to
	// run from bin/; use the interpreter on PATH.
	if !strings.has_prefix(read_head(path, 2), "#!") {
		if _, compiled := plan.lang.compile.?; !compiled {
			for cand in plan.lang.interpreters {
				if p := script_find_on_path(cand); len(p) > 0 {
					plan.add_shebang = p; break
				}
			}
			if len(plan.add_shebang) == 0 {
				plan.reason = fmt.tprintf(
					"no shebang and no %s interpreter on PATH",
					plan.lang.name,
				)
			}
		}
	}
	return plan
}

script_import :: proc(paths: []string, keep_original: bool) {
	taken := make([dynamic]string, context.temp_allocator)
	for s in script_list_all() {append(&taken, s.name)}

	plans := make([dynamic]ScriptImportPlan, context.temp_allocator)
	for p in paths {
		plan := script_plan_import(p, taken[:])
		if len(plan.reason) == 0 {
			append(&taken, plan.name)
		}
		append(&plans, plan)
	}

	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		for plan in plans {
			if len(plan.reason) > 0 {
				fmt.printfln("  skip    %s: %s", plan.path, plan.reason)
			} else {
				fmt.printfln(
					"  import  %s -> %s/%s.%s (%s%s)",
					plan.path,
					scripts_dir(),
					plan.name,
					plan.ext,
					plan.lang.name,
					", copy" if keep_original else ", move",
				)
			}
		}
		return
	}

	config_lock_acquire_or_exit()
	defer config_lock_release()
	if !script_ensure_dirs() {
		os.exit(EXIT_CANTCREAT)
	}
	had_bin := len(script_path_value()) > 0

	imported, skipped := 0, 0
	for &plan in plans {
		if len(plan.reason) == 0 {
			script_import_one(&plan, keep_original)
		}
		if len(plan.reason) > 0 {
			skipped += 1
		} else {
			imported += 1
		}
	}

	script_sync_path(had_bin)
	fmt.println()
	fmt.printfln("Imported %d, skipped %d", imported, skipped)
	for plan in plans {
		if len(plan.reason) > 0 {
			fmt.printfln("  skipped  %s: %s", plan.path, plan.reason)
		} else {
			fmt.printfln("  imported %s -> %s", plan.path, plan.name)
		}
	}
	if imported == 0 && skipped > 0 {
		os.exit(EXIT_DATAERR)
	}
}

// Copy, build, then (unless keep_original) delete the original. Sets
// plan.reason when anything fails; the original is then left untouched.
@(private = "file")
script_import_one :: proc(plan: ^ScriptImportPlan, keep_original: bool) {
	data, err := os.read_entire_file_from_path(plan.path, context.temp_allocator)
	if err != nil {
		plan.reason = "unreadable"
		return
	}
	content := string(data)
	if len(plan.add_shebang) > 0 {
		content = fmt.tprintf("#!%s\n%s", plan.add_shebang, content)
	}
	dest := fmt.tprintf("%s/%s.%s", scripts_dir(), plan.name, plan.ext)
	if os.exists(dest) {
		plan.reason = fmt.tprintf("%s already exists", dest)
		return
	}
	if write_file_atomic(dest, transmute([]byte)content) != nil {
		plan.reason = fmt.tprintf("cannot write %s", dest)
		return
	}
	_ = os.chmod(dest, os.perm_number(0o755))
	s := ScriptInfo {
		name   = plan.name,
		source = dest,
		bin    = fmt.tprintf("%s/%s", scripts_bin_dir(), plan.name),
		lang   = plan.lang,
	}
	if !script_build(s, quiet = true) {
		_ = os.remove(dest)
		script_remove_bin(plan.name)
		plan.reason = "build failed (see above)"
		return
	}
	if !keep_original {
		if rerr := os.remove(plan.path); rerr != nil {
			print_warning("Imported %s but could not remove the original", plan.path)
		}
	}
}

// ---------------------------------------------------------------------------
// Doctor + watcher
// ---------------------------------------------------------------------------

// Doctor: stale or broken scripts and bin entries without a script.
check_scripts :: proc(results: ^[dynamic]CheckResult) {
	scripts := script_list_all()
	problems := make([dynamic]string, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for s in scripts {
		append(&names, s.name)
		if s.lang == nil {
			append(&problems, fmt.tprintf("%s: unknown language", s.name))
			continue
		}
		if interp := script_shebang_interpreter(first_line(read_head(s.source)));
		   len(interp) > 0 && strings.has_prefix(interp, "/") {
			if !(os.is_file(interp) && script_is_executable(interp)) {
				append(&problems, fmt.tprintf("%s: interpreter %s not found", s.name, interp))
			}
		}
		if script_is_stale(s) {
			append(
				&problems,
				fmt.tprintf("%s: not built or stale (run: wayu script build)", s.name),
			)
		}
	}
	if handle, err := os.open(scripts_bin_dir()); err == nil {
		defer os.close(handle)
		if infos, rerr := os.read_dir(handle, -1, context.temp_allocator); rerr == nil {
			for info in infos {
				if strings.has_prefix(info.name, ".") {
					continue
				}
				if !slice.contains(names[:], info.name) {
					append(
						&problems,
						fmt.tprintf(
							"%s/%s: no script with that name (dangling)",
							scripts_bin_dir(),
							info.name,
						),
					)
				} else if info.type == .Symlink &&
				   !os.exists(fmt.tprintf("%s/%s", scripts_bin_dir(), info.name)) {
					append(&problems, fmt.tprintf("%s: broken link", info.name))
				}
			}
		}
	}
	if len(scripts) == 0 && len(problems) == 0 {
		return
	}
	if len(problems) == 0 {
		append(
			results,
			CheckResult {
				name = clone_arena("scripts"),
				status = .OK,
				message = clone_arena(fmt.tprintf("%d script(s) built", len(scripts))),
			},
		)
		return
	}
	append(
		results,
		CheckResult {
			name = clone_arena("scripts"),
			status = .WARNING,
			message = clone_arena(strings.join(problems[:], "; ", context.temp_allocator)),
		},
	)
}

// Files the watcher polls besides wayu.toml: the scripts dir (adds and
// removes) and every source. Heap-allocated like get_default_watch_paths.
script_watch_paths :: proc(out: ^[dynamic]string) {
	if os.is_dir(scripts_dir()) {
		append(out, strings.clone(scripts_dir()))
	}
	for s in script_list_all() {append(out, strings.clone(s.source))}
}

print_script_usage :: proc() {
	fmt.println()
	fmt.printfln("%swayu script - Manage standalone scripts on PATH%s", BOLD, RESET)
	fmt.println()
	fmt.printfln("%sUSAGE:%s", get_primary(), RESET)
	fmt.println(
		"  wayu script new <name> [--lang <lang>]  Create a script, open it in $EDITOR, build it",
	)
	fmt.println("  wayu script edit <name>                 Open in $EDITOR, rebuild")
	fmt.println("  wayu script list [--json]               List scripts")
	fmt.println("  wayu script remove <name> --yes         Delete the source and its bin entry")
	fmt.println(
		"  wayu script import <file>... [--copy]   Import existing scripts (moved unless --copy)",
	)
	fmt.println(
		"  wayu script build [<name>...]           Build stale scripts (or the ones named)",
	)
	fmt.println()
	fmt.printfln("%sDESCRIPTION:%s", get_primary(), RESET)
	fmt.printfln(
		"  Sources live in %s/scripts/, executables in %s/bin/ (first on",
		wayu.data,
		wayu.data,
	)
	fmt.println("  wayu's PATH entries). Interpreted scripts are linked; swift is compiled")
	fmt.println(
		"  with swiftc. Default language: [scripts] default_lang in wayu.toml, else swift.",
	)
	fmt.printfln("  Languages: %s", script_lang_names())
	fmt.println()
	fmt.printfln("%sEXAMPLES:%s", get_primary(), RESET)
	fmt.println("  wayu script new hello --lang python")
	fmt.println("  wayu script import ~/bin/* --dry-run")
	fmt.println("  wayu script remove hello --yes")
	fmt.println()
}

// Put <data>/bin (script_path_value) first in a PATH value list owned by
// the caller (values are heap strings), dropping a duplicate of it.
script_path_prepend :: proc(values: ^[dynamic]string) {
	bin := script_path_value()
	if len(bin) == 0 {
		return
	}
	for v, i in values {
		if v == bin {
			delete(v)
			ordered_remove(values, i)
			break
		}
	}
	inject_at(values, 0, strings.clone(bin))
}
