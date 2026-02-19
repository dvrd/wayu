// errors.odin - Enhanced error handling with context and suggestions

package wayu

import "core:os"
import "core:fmt"
import "core:strings"

// Error types for better categorization
ErrorType :: enum {
	FILE_NOT_FOUND,
	PERMISSION_DENIED,
	FILE_READ_ERROR,
	FILE_WRITE_ERROR,
	INVALID_INPUT,
	CONFIG_NOT_INITIALIZED,
	DIRECTORY_NOT_FOUND,
}

// Enhanced error message with context and suggestions
print_error_with_context :: proc(
	error_type: ErrorType,
	resource: string,
	context_msg: string = "",
) {
	fmt.eprintf("%s%sERROR:%s ", BOLD, ERROR, RESET)

	switch error_type {
	case .FILE_NOT_FOUND:
		fmt.eprintfln("File not found: %s%s%s", BRIGHT_YELLOW, resource, RESET)

		if strings.contains(resource, ".config/wayu") {
			fmt.eprintfln("\n%sSuggestion:%s Run %swayu init%s to create configuration files",
				BRIGHT_CYAN, RESET, BOLD, RESET)
			fmt.eprintfln("            This will set up all required configuration files in ~/.config/wayu/")
		} else {
			fmt.eprintfln("\n%sSuggestion:%s Check the file path and try again",
				BRIGHT_CYAN, RESET)
		}

	case .PERMISSION_DENIED:
		fmt.eprintfln("Permission denied: %s%s%s", BRIGHT_YELLOW, resource, RESET)
		fmt.eprintfln("\n%sSuggestion:%s Check file permissions with:", BRIGHT_CYAN, RESET)
		fmt.eprintfln("            %sls -la %s%s", MUTED, resource, RESET)
		fmt.eprintfln("            You may need to run:")
		fmt.eprintfln("            %schmod 644 %s%s", MUTED, resource, RESET)

	case .FILE_READ_ERROR:
		fmt.eprintfln("Failed to read file: %s%s%s", BRIGHT_YELLOW, resource, RESET)
		if len(context_msg) > 0 {
			fmt.eprintfln("Details: %s", context_msg)
		}
		fmt.eprintfln("\n%sSuggestion:%s Ensure the file is not corrupted or locked by another process",
			BRIGHT_CYAN, RESET)
		fmt.eprintfln("            Try closing other applications that may be using this file")

	case .FILE_WRITE_ERROR:
		fmt.eprintfln("Failed to write file: %s%s%s", BRIGHT_YELLOW, resource, RESET)
		if len(context_msg) > 0 {
			fmt.eprintfln("Details: %s", context_msg)
		}
		fmt.eprintfln("\n%sSuggestion:%s Check disk space and file permissions:", BRIGHT_CYAN, RESET)
		fmt.eprintfln("            %sdf -h%s  # Check disk space", MUTED, RESET)
		fmt.eprintfln("            %sls -la %s%s  # Check permissions", MUTED, resource, RESET)

	case .INVALID_INPUT:
		fmt.eprintfln("Invalid input: %s%s%s", BRIGHT_YELLOW, resource, RESET)
		if len(context_msg) > 0 {
			fmt.eprintfln("Reason: %s", context_msg)
		}
		// Determine command type from resource
		if strings.contains(resource, "alias") {
			fmt.eprintfln("\n%sSuggestion:%s Use %swayu alias help%s for usage information",
				BRIGHT_CYAN, RESET, MUTED, RESET)
		} else if strings.contains(resource, "constant") {
			fmt.eprintfln("\n%sSuggestion:%s Use %swayu constants help%s for usage information",
				BRIGHT_CYAN, RESET, MUTED, RESET)
		} else if strings.contains(resource, "path") {
			fmt.eprintfln("\n%sSuggestion:%s Use %swayu path help%s for usage information",
				BRIGHT_CYAN, RESET, MUTED, RESET)
		} else {
			fmt.eprintfln("\n%sSuggestion:%s Use %swayu help%s for usage information",
				BRIGHT_CYAN, RESET, MUTED, RESET)
		}

	case .CONFIG_NOT_INITIALIZED:
		fmt.eprintfln("Wayu configuration not found in: %s%s%s",
			BRIGHT_YELLOW, resource, RESET)
		fmt.eprintfln("\n%sFirst time using wayu?%s Run the following command:",
			BRIGHT_CYAN, RESET)
		fmt.eprintfln("  %swayu init%s", BOLD, RESET)
		fmt.eprintfln("\nThis will:")
		fmt.eprintfln("  • Create ~/.config/wayu/ directory")
		fmt.eprintfln("  • Initialize all configuration files")
		fmt.eprintfln("  • Set up shell integration")

	case .DIRECTORY_NOT_FOUND:
		fmt.eprintfln("Directory not found: %s%s%s", BRIGHT_YELLOW, resource, RESET)
		if len(context_msg) > 0 {
			fmt.eprintfln("Details: %s", context_msg)
		}
		fmt.eprintfln("\n%sSuggestion:%s Verify the directory exists or create it:", BRIGHT_CYAN, RESET)
		fmt.eprintfln("            %smkdir -p %s%s", MUTED, resource, RESET)
	}

	fmt.eprintln()
}

// Check if file exists and is readable
check_file_access :: proc(file_path: string) -> (ok: bool, error_type: ErrorType) {
	if !os.exists(file_path) {
		return false, .FILE_NOT_FOUND
	}

	// Try to open for reading
	handle, err := os.open(file_path, os.O_RDONLY)
	if err != nil {
		return false, .PERMISSION_DENIED
	}
	os.close(handle)

	return true, .FILE_NOT_FOUND // Won't be used when ok=true
}

// Safe file read with detailed error reporting
safe_read_file :: proc(file_path: string) -> (content: []byte, ok: bool) {
	// Check access first
	access_ok, error_type := check_file_access(file_path)
	if !access_ok {
		print_error_with_context(error_type, file_path)
		return nil, false
	}

	// Attempt read
	data, read_err := os.read_entire_file(file_path, context.allocator)
	if read_err != nil {
		print_error_with_context(.FILE_READ_ERROR, file_path)
		return nil, false
	}

	return data, true
}

// Safe file write with detailed error reporting
safe_write_file :: proc(file_path: string, content: []byte) -> bool {
	write_err := os.write_entire_file(file_path, content)
	if write_err != nil {
		// Check specific failure reason
		dir_path := get_directory(file_path)
		defer delete(dir_path)

		if !os.exists(dir_path) {
			print_error_with_context(.DIRECTORY_NOT_FOUND, dir_path,
				"Parent directory does not exist")
		} else {
			// Check disk space
			print_error_with_context(.FILE_WRITE_ERROR, file_path)
		}
		return false
	}
	return true
}

// Helper to get directory from file path
get_directory :: proc(file_path: string) -> string {
	last_slash := -1
	for char, i in file_path {
		if char == '/' {
			last_slash = i
		}
	}

	if last_slash == -1 {
		return "."
	}

	return strings.clone(file_path[:last_slash])
}

// Print formatted error (simple version for backwards compatibility)
print_error_simple :: proc(format: string, args: ..any) {
	fmt.eprintf("%s%sERROR:%s ", BOLD, ERROR, RESET)
	fmt.eprintfln(format, ..args)
}

// Check if wayu is initialized
check_wayu_initialized :: proc() -> bool {
	if !os.exists(WAYU_CONFIG) {
		print_error_with_context(.CONFIG_NOT_INITIALIZED, WAYU_CONFIG)
		return false
	}

	// Check for essential files
	essential_files := []string{
		fmt.aprintf("%s/path.zsh", WAYU_CONFIG),
		fmt.aprintf("%s/aliases.zsh", WAYU_CONFIG),
		fmt.aprintf("%s/constants.zsh", WAYU_CONFIG),
		fmt.aprintf("%s/init.zsh", WAYU_CONFIG),
	}
	defer {
		for file in essential_files {
			delete(file)
		}
	}

	for file in essential_files {
		if !os.exists(file) {
			print_error_with_context(.FILE_NOT_FOUND, file)
			return false
		}
	}

	return true
}