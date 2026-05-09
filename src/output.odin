// output.odin - Minimal JSON escaping utility and shared types

package wayu

import "core:fmt"
import "core:strings"

// json_escape_string_builder escapes JSON-special characters into a strings.Builder.
@(private="file")
json_escape_string_builder :: proc(builder: ^strings.Builder, str: string) {
	for r in str {
		switch r {
		case '"':
			strings.write_string(builder, `\"`)
		case '\\':
			strings.write_string(builder, `\\`)
		case '\n':
			strings.write_string(builder, `\n`)
		case '\t':
			strings.write_string(builder, `\t`)
		case:
			if r < 0x20 {
				fmt.sbprintf(builder, "\\u%04x", r)
			} else {
				strings.write_rune(builder, r)
			}
		}
	}
}

// json_escape returns `str` with JSON-mandatory characters escaped.
// Caller owns the returned string and must `delete` it.
json_escape :: proc(str: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	json_escape_string_builder(&builder, str)
	return strings.clone(strings.to_string(builder))
}

// AliasEntry represents a single alias (used by init_generator and migrate_schema)
AliasEntry :: struct {
	name:    string,
	command: string,
}
