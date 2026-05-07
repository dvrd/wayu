// toml_section_writer.odin - Replace a single `[section]` table in a TOML
// file in place. Used by path/alias/env writers so each mutation rewrites
// only its own section and leaves the rest of wayu.toml byte-identical.

package wayu

import "core:fmt"
import "core:strings"

// Replace the existing `[<section>]` table (header + body up to the next
// section header) with the supplied body. When `body` is empty, the
// section is removed entirely. When the section doesn't exist yet, it's
// appended at the end. Caller owns the returned string.
//
// `body_lines` is rendered verbatim under a freshly emitted `[<section>]`
// header. Caller is responsible for ordering and formatting; this proc
// just splices.
replace_toml_table_section :: proc(content: string, section: string, body_lines: []string) -> string {
	header := fmt.aprintf("[%s]", section)
	defer delete(header)

	lines := strings.split(content, "\n")
	defer delete(lines)

	out := strings.builder_make()
	defer strings.builder_destroy(&out)

	emit_new_section :: proc(b: ^strings.Builder, section: string, body_lines: []string) {
		fmt.sbprintfln(b, "[%s]", section)
		for line in body_lines {
			fmt.sbprintln(b, line)
		}
	}

	in_target := false
	replaced := false
	for i := 0; i < len(lines); i += 1 {
		trimmed := strings.trim_space(lines[i])

		if trimmed == header {
			in_target = true
			if len(body_lines) > 0 {
				emit_new_section(&out, section, body_lines)
				replaced = true
			} else {
				replaced = true // we're "replacing" with nothing
			}
			continue
		}

		// Closing the target on the next section header (any `[...]`).
		if in_target && strings.has_prefix(trimmed, "[") {
			in_target = false
		}

		if in_target { continue }
		fmt.sbprintln(&out, lines[i])
	}

	result := strings.to_string(out)

	if !replaced && len(body_lines) > 0 {
		// Section didn't exist — append at end with a separator blank line.
		needs_nl := !strings.has_suffix(result, "\n")
		appended := strings.builder_make()
		defer strings.builder_destroy(&appended)
		fmt.sbprint(&appended, result)
		if needs_nl { fmt.sbprint(&appended, "\n") }
		fmt.sbprintln(&appended, "")
		emit_new_section(&appended, section, body_lines)
		return strings.clone(strings.to_string(appended))
	}

	// Tidy: collapse three+ consecutive blank lines into two and trim
	// trailing whitespace so repeated edits don't grow the file.
	return tidy_blank_runs(result)
}

// Collapse runs of 3+ consecutive blank lines into two. Caller owns return.
tidy_blank_runs :: proc(s: string) -> string {
	lines := strings.split(s, "\n")
	defer delete(lines)
	out := strings.builder_make()
	defer strings.builder_destroy(&out)
	blanks := 0
	for line in lines {
		if len(strings.trim_space(line)) == 0 {
			blanks += 1
			if blanks > 2 { continue }
		} else {
			blanks = 0
		}
		fmt.sbprintln(&out, line)
	}
	return strings.clone(strings.to_string(out))
}
