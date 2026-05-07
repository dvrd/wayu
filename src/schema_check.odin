// schema_check.odin - Detect obsolete wayu.toml schema and abort with a
// clear migration hint. Wayu used to use array-of-tables for paths,
// aliases and constants; v3.x uses a single inline-table per section.
// We don't auto-migrate or transparently parse the old form — running
// against a stale toml is a hard error so users notice and run
// `wayu migrate --schema` once.

package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// Section header tokens that no longer exist in the modern schema.
LEGACY_SECTION_HEADERS :: []string{
	"[[paths]]",
	"[[aliases]]",
	"[[constants]]",
	"[constants]",
}

// Returns the first legacy header found in `content`, or "" when the file
// is clean. Cheap line-by-line scan; we only need to detect, not parse.
detect_legacy_schema :: proc(content: string) -> string {
	for header in LEGACY_SECTION_HEADERS {
		if !strings.contains(content, header) { continue }
		// Confirm it's an actual section header (line-equal after trim),
		// not a substring inside a value.
		lines := strings.split(content, "\n")
		defer delete(lines)
		for line in lines {
			if strings.trim_space(line) == header { return header }
		}
	}
	return ""
}

// Print the user-visible "obsolete schema, run migrate" banner. Shared by
// the per-read guard and the global pre-dispatch guard.
print_legacy_schema_hint :: proc(header: string) {
	fmt.eprintln()
	fmt.eprintf("%sError:%s wayu.toml uses the obsolete %s%s%s schema.\n",
		BRIGHT_RED, RESET, BRIGHT_CYAN, header, RESET)
	fmt.eprintln()
	fmt.eprintln("v3.x replaced the array-of-tables forms with single inline tables:")
	fmt.eprintln()
	fmt.eprintln("  [paths]")
	fmt.eprintln("  odin = \"/Users/you/dev/Odin\"")
	fmt.eprintln()
	fmt.eprintln("  [aliases]")
	fmt.eprintln("  ll = \"ls -la\"")
	fmt.eprintln()
	fmt.eprintln("  [env]")
	fmt.eprintln("  EDITOR = \"nvim\"")
	fmt.eprintln()
	fmt.eprintf("Run %swayu migrate --schema%s to upgrade in place.\n", BRIGHT_CYAN, RESET)
	fmt.eprintln()
}

// Read wayu.toml and abort with a structured error if the schema is stale.
// Returns the file content (caller frees) on success. On legacy schema or
// I/O error, prints a message and exits — never returns.
must_read_modern_wayu_toml :: proc(path: string) -> []byte {
	content, ok := safe_read_file(path)
	if !ok {
		print_error("Could not read %s", path)
		os.exit(EXIT_NOINPUT)
	}
	if header := detect_legacy_schema(string(content)); len(header) > 0 {
		print_legacy_schema_hint(header)
		delete(content)
		os.exit(EXIT_CONFIG)
	}
	return content
}

// Pre-dispatch global guard. Aborts with the migration hint for any command
// that would touch wayu.toml while it's still on the obsolete schema. Safe
// commands (the ones that don't read the toml at all, plus the migration
// command itself) bypass the check.
enforce_modern_wayu_toml_or_exit :: proc(toml_path: string) {
	if !os.exists(toml_path) { return }
	content, ok := safe_read_file(toml_path)
	if !ok { return } // I/O failures bubble up at the actual call site
	defer delete(content)
	if header := detect_legacy_schema(string(content)); len(header) > 0 {
		print_legacy_schema_hint(header)
		os.exit(EXIT_CONFIG)
	}
}
