// test_cli_doc.odin - docs/cli.md matches WAYU_COMMAND_SPECS (OKAMI-190)
//
// docs/cli.md is written by hand; these tests fail when it misses a command,
// command alias, action word, command flag or --json support from the spec
// table, documents a command the table doesn't have, or misses an exit code.

package test_wayu

import wayu "../../src"
import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
CLI_DOC_TEXT :: #load("../../docs/cli.md", string)

@(private = "file")
CLI_DOC := CLI_DOC_TEXT

// The text of the `### \`wayu <name>\`` section (heading included), "" when
// there is none. Ends at the next heading of level 2 or 3.
@(private = "file")
cli_doc_section :: proc(name: string) -> string {
	heading := fmt.tprintf("\n### `wayu %s`", name)
	start := strings.index(CLI_DOC, heading)
	if start < 0 {
		return ""
	}
	rest := CLI_DOC[start + 1:]
	end := len(rest)
	if i := strings.index(rest[1:], "\n### "); i >= 0 {
		end = i + 1
	}
	if i := strings.index(rest[1:], "\n## "); i >= 0 && i + 1 < end {
		end = i + 1
	}
	return rest[:end]
}

@(test)
test_cli_doc_covers_command_specs :: proc(t: ^testing.T) {
	for spec in wayu.WAYU_COMMAND_SPECS {
		name := spec.names[0]
		section := cli_doc_section(name)
		if !testing.expectf(t, len(section) > 0, "docs/cli.md: no '### `wayu %s`' section", name) {
			continue
		}
		heading :=
			section[:strings.index_byte(section, '\n')] if \
				strings.contains(section, "\n") else \
				section
		for alias in spec.names[1:] {
			testing.expectf(
				t,
				strings.contains(heading, fmt.tprintf("`%s`", alias)),
				"docs/cli.md: '%s' heading does not name alias `%s`",
				name,
				alias,
			)
		}
		for a in spec.actions {
			if len(a.desc) == 0 {
				continue
			} // parser-only synonym
			testing.expectf(
				t,
				strings.contains(section, fmt.tprintf("`%s`", a.word)),
				"docs/cli.md: '%s' section does not list action `%s`",
				name,
				a.word,
			)
		}
		for f in spec.flags {
			if len(f.desc) == 0 {
				continue
			} // hidden spelling
			testing.expectf(
				t,
				strings.contains(section, fmt.tprintf("`%s", f.flag)),
				"docs/cli.md: '%s' section does not list flag `%s`",
				name,
				f.flag,
			)
		}
		if spec.json != {} {
			testing.expectf(
				t,
				strings.contains(section, "--json"),
				"docs/cli.md: '%s' supports --json but its section doesn't say so",
				name,
			)
		}
	}
}

@(test)
test_cli_doc_has_no_unknown_commands :: proc(t: ^testing.T) {
	marker :: "\n### `wayu "
	rest := CLI_DOC
	for {
		i := strings.index(rest, marker)
		if i < 0 {
			break
		}
		rest = rest[i + len(marker):]
		end := strings.index_byte(rest, '`')
		if end < 0 {
			break
		}
		name := rest[:end]
		testing.expectf(
			t,
			wayu.find_command_spec_by_name(name) != nil,
			"docs/cli.md documents `wayu %s`, which WAYU_COMMAND_SPECS doesn't have",
			name,
		)
	}
}

@(test)
test_cli_doc_lists_exit_codes :: proc(t: ^testing.T) {
	codes := [?]struct {
		value: int,
		name:  string,
	} {
		{wayu.EXIT_SUCCESS, "EXIT_SUCCESS"},
		{wayu.EXIT_FAILURE, "EXIT_FAILURE"},
		{wayu.EXIT_USAGE, "EXIT_USAGE"},
		{wayu.EXIT_DATAERR, "EXIT_DATAERR"},
		{wayu.EXIT_NOINPUT, "EXIT_NOINPUT"},
		{wayu.EXIT_OSERR, "EXIT_OSERR"},
		{wayu.EXIT_CANTCREAT, "EXIT_CANTCREAT"},
		{wayu.EXIT_IOERR, "EXIT_IOERR"},
		{wayu.EXIT_NOPERM, "EXIT_NOPERM"},
		{wayu.EXIT_CONFIG, "EXIT_CONFIG"},
	}
	for c in codes {
		row := fmt.tprintf("| %d | `%s` |", c.value, c.name)
		testing.expectf(
			t,
			strings.contains(CLI_DOC, row),
			"docs/cli.md exit code table lacks %q",
			row,
		)
	}
}
