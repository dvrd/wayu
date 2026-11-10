// function.odin - Implementation of `wayu function {add,list,remove}`
//
// Manages custom shell functions stored as individual files in the
// `functions/` directory under the wayu data dir (<data>/functions; wayu
// manages them, like scripts/). `function add <name>` seeds a skeleton file
// if it does not exist and opens it in $EDITOR; the shell init loads every
// file in this directory at startup.

package wayu

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

handle_function_command :: proc(action: Action, args: []string) {
	#partial switch action {
	case .ADD:
		if len(args) < 1 {
			print_error_simple("Function name required. Usage: wayu function add <name>")
			os.exit(EXIT_USAGE)
		}
		add_function(args[0])
	case .REMOVE:
		if len(args) < 1 {
			print_error_simple("Function name required. Usage: wayu function remove <name>")
			os.exit(EXIT_USAGE)
		}
		remove_function(args[0])
	case .LIST:
		list_functions()
	case .HELP:
		print_function_usage()
	case:
		fmt.eprintln("Unknown function action")
		print_function_usage()
		os.exit(EXIT_USAGE)
	}
}

// Resolve the absolute path to a function file for the active shell.
// Caller owns the returned string.
function_file_path :: proc(name: string) -> string {
	return fmt.aprintf("%s/functions/%s.%s", wayu.data, name, wayu.shell_ext)
}

// Ensure <data>/functions exists. Exits on failure.
ensure_functions_dir :: proc() -> string {
	dir := fmt.aprintf("%s/functions", wayu.data)
	if !os.exists(dir) {
		if err := make_directory_all(dir); err != nil {
			print_error_simple("Failed to create functions directory: %s", dir)
			os.exit(EXIT_CANTCREAT)
		}
	}
	return dir
}

add_function :: proc(name: string) {
	result := validate_identifier(name, "Function")
	if !result.valid {
		print_error("%s", result.error_message)
		delete(result.error_message)
		os.exit(EXIT_DATAERR)
	}

	if wayu.dry_run {
		func_file := function_file_path(name)
		defer delete(func_file)
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		if os.exists(func_file) {
			fmt.printfln("Would open %s in $EDITOR", func_file)
		} else {
			fmt.printfln("Would create %s and open it in $EDITOR", func_file)
		}
		return
	}

	dir := ensure_functions_dir()
	defer delete(dir)

	func_file := function_file_path(name)
	defer delete(func_file)

	// Seed a skeleton if the file does not already exist.
	if !os.exists(func_file) {
		skeleton := function_skeleton(name)
		defer delete(skeleton)
		if write_ok := os.write_entire_file_from_string(func_file, skeleton); write_ok != nil {
			print_error_simple("Failed to create function file: %s", func_file)
			os.exit(EXIT_CANTCREAT)
		}
		print_success("Created function: %s", func_file)
	}

	// No $EDITOR/$VISUAL and no terminal: print the file instead of running
	// vi (like `script new`).
	opened, edit_ok := editor_maybe_open(func_file)
	if !edit_ok {
		os.exit(EXIT_FAILURE)
	}
	if opened {
		print_info("Reload your shell to load '%s'", name)
	}
}

// Open the editor unless there is none to open: no $EDITOR/$VISUAL and no
// terminal (scripts, CI), where the file's path is printed instead.
// ok=false when the editor failed.
editor_maybe_open :: proc(file: string) -> (opened: bool, ok: bool) {
	has_editor :=
		len(strings.trim_space(os.get_env("EDITOR", context.temp_allocator))) > 0 ||
		len(strings.trim_space(os.get_env("VISUAL", context.temp_allocator))) > 0
	if !has_editor && !(is_tty(0) && is_tty(1)) {
		fmt.println(file)
		return false, true
	}
	return true, launch_editor(file)
}

// Build a shell-appropriate skeleton for a new function.
// Caller owns the returned string.
function_skeleton :: proc(name: string) -> string {
	if wayu.shell == .FISH {
		return strings.concatenate(
			[]string {
				"# ",
				name,
				" - custom shell function (managed by wayu)\n",
				"# Edit with: wayu function edit ",
				name,
				"\n\n",
				"function ",
				name,
				"\n    # TODO: implement\nend\n",
			},
		)
	}
	return strings.concatenate(
		[]string {
			"# ",
			name,
			" - custom shell function (managed by wayu)\n",
			"# Edit with: wayu function edit ",
			name,
			"\n\n",
			name,
			"() {\n    # TODO: implement\n}\n",
		},
	)
}

remove_function :: proc(name: string) {
	// Validate first: the name becomes a path component, so `../../x` must
	// never reach function_file_path / os.remove.
	result := validate_identifier(name, "Function")
	if !result.valid {
		print_error("%s", result.error_message)
		delete(result.error_message)
		os.exit(EXIT_DATAERR)
	}

	func_file := function_file_path(name)
	defer delete(func_file)

	if !os.exists(func_file) {
		print_error_simple("Function not found: %s", name)
		os.exit(EXIT_NOINPUT)
	}

	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.printfln("Would delete function file: %s", func_file)
		return
	}

	if !wayu.yes_flag {
		fmt.printfln("This will delete %s. Pass --yes to confirm.", func_file)
		os.exit(EXIT_USAGE)
	}

	// Backup before deleting so the user can recover the function body.
	// No backup → no delete (the file is the only copy of the user's code).
	if !create_backup_cli(func_file) {
		os.exit(EXIT_IOERR)
	}

	if err := os.remove(func_file); err != nil {
		print_error_simple("Failed to remove function file: %s", func_file)
		os.exit(EXIT_IOERR)
	}
	print_success("Removed function: %s", name)
}

list_functions :: proc() {
	dir := fmt.aprintf("%s/functions", wayu.data)
	defer delete(dir)

	if !os.exists(dir) {
		print_info("No functions directory yet. Add one with: wayu function add <name>")
		return
	}

	handle, open_err := os.open(dir)
	if open_err != nil {
		print_error_simple("Failed to open functions directory: %s", dir)
		os.exit(EXIT_IOERR)
	}
	defer os.close(handle)

	entries, read_err := os.read_dir(handle, -1, context.allocator)
	if read_err != nil {
		print_error_simple("Failed to read functions directory: %s", dir)
		os.exit(EXIT_IOERR)
	}
	defer os.file_info_slice_delete(entries, context.allocator)

	suffix := fmt.aprintf(".%s", wayu.shell_ext)
	defer delete(suffix)

	count := 0
	print_header("Custom Functions", "🔧")
	for entry in entries {
		if entry.type == .Directory do continue
		if !strings.has_suffix(entry.name, suffix) do continue
		name := strings.trim_suffix(entry.name, suffix)
		fmt.printfln("  %s", name)
		count += 1
	}
	if count == 0 {
		print_info("No functions defined. Add one with: wayu function add <name>")
	}
}

// The editor wayu opens files in: $EDITOR, else $VISUAL, else vi.
editor_command :: proc() -> string {
	if e := os.get_env("EDITOR", context.temp_allocator); len(strings.trim_space(e)) > 0 {
		return e
	}
	if v := os.get_env("VISUAL", context.temp_allocator); len(strings.trim_space(v)) > 0 {
		return v
	}
	return "vi"
}

// Open `file` in editor_command() and wait for it. The editor string runs
// through `sh -c '<editor> "$1"'` (like git), so a command with arguments
// (`code --wait`, `subl -w`) works; the file name is passed as "$1", never
// re-parsed. The editor inherits our stdin/stdout/stderr (a TUI editor
// needs the terminal; don't route this through run_command*). Returns
// false, after printing why, when the editor can't start or exits non-zero:
// callers exit EXIT_FAILURE instead of reporting success.
launch_editor :: proc(file: string) -> bool {
	editor := editor_command()
	script := fmt.ctprintf(`%s "$1"`, editor)
	cfile := strings.clone_to_cstring(file, context.temp_allocator)
	argv := []cstring{"sh", "-c", script, "sh", cfile, nil}

	pid := posix.fork()
	if pid < 0 {
		print_error_simple("Failed to start editor '%s'", editor)
		return false
	}
	if pid == 0 {
		posix.execvp("sh", raw_data(argv))
		posix._exit(127)
	}

	status: c.int = 0
	for posix.waitpid(pid, &status, {}) < 0 {
		if posix.errno() != .EINTR {
			print_error_simple("Lost track of editor '%s'", editor)
			return false
		}
	}
	if !posix.WIFEXITED(status) {
		print_error_simple(
			"Editor '%s' was killed by a signal - set EDITOR to a working editor",
			editor,
		)
		return false
	}
	if code := posix.WEXITSTATUS(status); code != 0 {
		print_error_simple(
			"Editor '%s' exited with status %d - set EDITOR to a working editor",
			editor,
			code,
		)
		return false
	}
	return true
}

print_function_usage :: proc() {
	fmt.println()
	fmt.printfln("%swayu function - Manage custom shell functions%s", BOLD, RESET)
	fmt.println()
	fmt.printfln("%sUSAGE:%s", get_primary(), RESET)
	fmt.println("  wayu function add <name>     Create/edit a function file in $EDITOR")
	fmt.println("  wayu function list           List defined functions")
	fmt.println("  wayu function remove <name>  Delete a function file (needs --yes)")
	fmt.println()
	fmt.printfln("%sDESCRIPTION:%s", get_primary(), RESET)
	fmt.printfln("  Functions live as individual files in %s/functions/", wayu.data)
	fmt.println("  and are sourced when your shell starts. 'add' seeds a skeleton")
	fmt.println("  matching your shell and opens it in your editor.")
	fmt.println()
	fmt.printfln("%sEXAMPLES:%s", get_primary(), RESET)
	fmt.println("  wayu function add mkcd")
	fmt.println("  wayu function list")
	fmt.println("  wayu function remove mkcd --yes")
	fmt.println()
}
