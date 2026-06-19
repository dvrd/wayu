// function.odin - Implementation of `wayu function {add,list,remove}`
//
// Manages custom shell functions stored as individual files in the
// `functions/` directory under the wayu config dir
// (~/.config/wayu/functions). `function add <name>` seeds a skeleton file
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
		print_function_usage()
	}
}

// Resolve the absolute path to a function file for the active shell.
// Caller owns the returned string.
function_file_path :: proc(name: string) -> string {
	return fmt.aprintf("%s/functions/%s.%s", wayu.config, name, wayu.shell_ext)
}

// Ensure ~/.config/wayu/functions exists. Exits on failure.
ensure_functions_dir :: proc() -> string {
	dir := fmt.aprintf("%s/functions", wayu.config)
	if !os.exists(dir) {
		if err := make_directory_all(dir); err != nil {
			print_error_simple("Failed to create functions directory: %s", dir)
			os.exit(EXIT_CANTCREAT)
		}
	}
	return dir
}

// Copy any function files from the legacy data-dir location
// (~/.local/share/wayu/functions) into the config-dir location
// (~/.config/wayu/functions) that the loader now sources. Existing files in
// the destination are never overwritten. Idempotent and safe to call often.
migrate_legacy_functions :: proc() {
	// When config and data resolve to the same directory (e.g. tests setting
	// WAYU_CONFIG_DIR), there is nothing to migrate.
	if wayu.config == wayu.data do return

	old_dir := fmt.aprintf("%s/functions", wayu.data)
	defer delete(old_dir)
	if !os.exists(old_dir) do return

	handle, open_err := os.open(old_dir)
	if open_err != nil do return
	defer os.close(handle)

	entries, read_err := os.read_dir(handle, -1, context.allocator)
	if read_err != nil do return
	defer os.file_info_slice_delete(entries, context.allocator)

	moved := 0
	for entry in entries {
		if entry.type == .Directory do continue

		dest := fmt.aprintf("%s/functions/%s", wayu.config, entry.name)
		defer delete(dest)
		if os.exists(dest) do continue // never clobber the new location

		src := fmt.aprintf("%s/%s", old_dir, entry.name)
		defer delete(src)

		data, read_err := os.read_entire_file(src, context.allocator)
		if read_err != nil do continue
		defer delete(data)

		// Make sure the destination directory exists before writing.
		new_dir := ensure_functions_dir()
		delete(new_dir)

		if os.write_entire_file(dest, data) == nil {
			moved += 1
		}
	}

	if moved > 0 {
		print_success("Migrated %d function(s) to %s/functions", moved, wayu.config)
		print_info("Originals left in %s for safety — remove them once verified", old_dir)
	}
}

add_function :: proc(name: string) {
	result := validate_identifier(name, "Function")
	if !result.valid {
		print_error(result.error_message)
		os.exit(EXIT_DATAERR)
	}

	dir := ensure_functions_dir()
	defer delete(dir)

	// Pull any functions from the legacy data-dir location into the new one.
	migrate_legacy_functions()

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

	launch_editor(func_file)
	print_info("Reload your shell to load '%s'", name)
}

// Build a shell-appropriate skeleton for a new function.
// Caller owns the returned string.
function_skeleton :: proc(name: string) -> string {
	if wayu.shell == .FISH {
		return strings.concatenate(
			[]string {
				"# ", name, " - custom shell function (managed by wayu)\n",
				"# Edit with: wayu function edit ", name, "\n\n",
				"function ", name, "\n    # TODO: implement\nend\n",
			},
		)
	}
	return strings.concatenate(
		[]string {
			"# ", name, " - custom shell function (managed by wayu)\n",
			"# Edit with: wayu function edit ", name, "\n\n",
			name, "() {\n    # TODO: implement\n}\n",
		},
	)
}

remove_function :: proc(name: string) {
	func_file := function_file_path(name)
	defer delete(func_file)

	if !os.exists(func_file) {
		print_error_simple("Function not found: %s", name)
		os.exit(EXIT_NOINPUT)
	}

	if !wayu.yes_flag {
		fmt.printfln("This will delete %s. Pass --yes to confirm.", func_file)
		os.exit(EXIT_USAGE)
	}

	// Backup before deleting so the user can recover the function body.
	backup_path, ok := create_backup(func_file)
	defer if ok do delete(backup_path)

	if err := os.remove(func_file); err != nil {
		print_error_simple("Failed to remove function file: %s", func_file)
		os.exit(EXIT_IOERR)
	}
	print_success("Removed function: %s", name)
}

list_functions :: proc() {
	// Pull any functions from the legacy data-dir location into the new one.
	migrate_legacy_functions()

	dir := fmt.aprintf("%s/functions", wayu.config)
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

// Launch $EDITOR (falling back to $VISUAL, then nvim) on the given file and
// wait for it to exit. Mirrors the fork/execvp pattern in config_command.odin.
launch_editor :: proc(file: string) {
	editor: string
	if e := os.get_env("EDITOR", context.temp_allocator); len(e) > 0 {
		editor = e
	} else if e := os.get_env("VISUAL", context.temp_allocator); len(e) > 0 {
		editor = e
	} else {
		editor = "nvim"
	}

	editor_args := []string{editor, file}

	argv := make([dynamic]cstring, len(editor_args) + 1)
	defer {
		for i in 0 ..< len(editor_args) {
			delete(argv[i])
		}
		delete(argv)
	}
	for arg, i in editor_args {
		argv[i] = strings.clone_to_cstring(arg)
	}
	argv[len(editor_args)] = nil

	pid := posix.fork()
	if pid < 0 {
		print_error_simple("Failed to fork process")
		os.exit(EXIT_IOERR)
	}

	if pid == 0 {
		posix.execvp(argv[0], raw_data(argv[:]))
		posix._exit(1)
	}

	status: c.int = 0
	posix.waitpid(pid, &status, {})
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
	fmt.println("  Functions live as individual files in ~/.config/wayu/functions/")
	fmt.println("  and are sourced when your shell starts. 'add' seeds a skeleton")
	fmt.println("  matching your shell and opens it in your editor.")
	fmt.println()
	fmt.printfln("%sEXAMPLES:%s", get_primary(), RESET)
	fmt.println("  wayu function add mkcd")
	fmt.println("  wayu function list")
	fmt.println("  wayu function remove mkcd --yes")
	fmt.println()
}
