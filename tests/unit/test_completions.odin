// test_completions.odin - Tests for completions module

package test_wayu

import wayu "../../src"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_extract_completion_items_empty :: proc(t: ^testing.T) {
	// Test with non-existent directory
	original_config := wayu.wayu.config
	defer {wayu.wayu.config = original_config; wayu.wayu.data = original_config}

	wayu.wayu.config = test_tmp("wayu-test-nonexistent")
	wayu.wayu.data = test_tmp("wayu-test-nonexistent")
	items := wayu.extract_completion_items()
	defer {
		for item in items {
			delete(item)
		}
		delete(items)
	}

	testing.expect(t, len(items) == 0, "Should return empty array for non-existent directory")
}

@(test)
test_extract_completion_items_single :: proc(t: ^testing.T) {
	// Create temporary test directory
	test_dir := test_tmp("wayu-test-completions")
	completions_dir := fmt.aprintf("%s/completions", test_dir)
	defer delete(completions_dir)

	// Create test directories
	os.make_directory(test_dir)
	os.make_directory(completions_dir)

	// Create a test completion file
	test_file := fmt.aprintf("%s/_test", completions_dir)
	defer delete(test_file)
	test_content := "#compdef test\n_test() {\n  echo test\n}"
	_ = os.write_entire_file(test_file, transmute([]byte)test_content)

	// Test extraction
	original_config := wayu.wayu.config
	defer {wayu.wayu.config = original_config; wayu.wayu.data = original_config}
	wayu.wayu.config = test_dir
	wayu.wayu.data = test_dir
	items := wayu.extract_completion_items()
	defer {
		for item in items {
			delete(item)
		}
		delete(items)
	}

	testing.expect(t, len(items) == 1, "Should find one completion")
	testing.expect(t, items[0] == "test", "Should extract name without underscore")
}

@(test)
test_extract_completion_items_multiple :: proc(t: ^testing.T) {
	// Create temporary test directory
	test_dir := test_tmp("wayu-test-completions-multi")
	completions_dir := fmt.aprintf("%s/completions", test_dir)
	defer delete(completions_dir)

	// Create test directories
	os.make_directory(test_dir)
	os.make_directory(completions_dir)

	// Create multiple test completion files
	files := []string{"_git", "_docker", "_kubectl"}
	for file in files {
		file_path := fmt.aprintf("%s/%s", completions_dir, file)
		completion_content := "#compdef\ntest completion"
		_ = os.write_entire_file(file_path, transmute([]byte)completion_content)
		delete(file_path)
	}

	// Test extraction
	original_config := wayu.wayu.config
	defer {wayu.wayu.config = original_config; wayu.wayu.data = original_config}
	wayu.wayu.config = test_dir
	wayu.wayu.data = test_dir
	items := wayu.extract_completion_items()
	defer {
		for item in items {
			delete(item)
		}
		delete(items)
	}

	testing.expect(t, len(items) == 3, "Should find three completions")

	// Check that all expected items are present (order may vary)
	expected := []string{"git", "docker", "kubectl"}
	for exp in expected {
		found := false
		for item in items {
			if item == exp {
				found = true
				break
			}
		}
		msg := fmt.aprintf("Should find completion: %s", exp)
		testing.expect(t, found, msg)
		delete(msg)
	}
}

@(test)
test_extract_completion_items_filters :: proc(t: ^testing.T) {
	// Create temporary test directory
	test_dir := test_tmp("wayu-test-completions-filter")
	completions_dir := fmt.aprintf("%s/completions", test_dir)
	defer delete(completions_dir)

	// Create test directories
	os.make_directory(test_dir)
	os.make_directory(completions_dir)

	// Create various files (only underscored ones should be included)
	files := []string{"_valid", "invalid", "_another", "README.md", "_third"}
	for file in files {
		file_path := fmt.aprintf("%s/%s", completions_dir, file)
		test_data := "test"
		_ = os.write_entire_file(file_path, transmute([]byte)test_data)
		delete(file_path)
	}

	// Create a subdirectory (should be ignored)
	subdir := fmt.aprintf("%s/_subdir", completions_dir)
	defer delete(subdir)
	os.make_directory(subdir)

	// Test extraction
	original_config := wayu.wayu.config
	defer {wayu.wayu.config = original_config; wayu.wayu.data = original_config}
	wayu.wayu.config = test_dir
	wayu.wayu.data = test_dir
	items := wayu.extract_completion_items()
	defer {
		for item in items {
			delete(item)
		}
		delete(items)
	}

	testing.expect(t, len(items) == 3, "Should find only underscored files")

	// Check that only valid items are present
	valid_items := []string{"valid", "another", "third"}
	for valid in valid_items {
		found := false
		for item in items {
			if item == valid {
				found = true
				break
			}
		}
		msg := fmt.aprintf("Should find valid completion: %s", valid)
		testing.expect(t, found, msg)
		delete(msg)
	}

	// Check that invalid items are not present
	for item in items {
		testing.expect(t, item != "invalid", "Should not include non-underscored files")
		testing.expect(t, item != "README.md", "Should not include non-completion files")
		testing.expect(t, item != "_subdir", "Should not include directories")
	}
}

@(test)
test_completion_name_normalization :: proc(t: ^testing.T) {
	// Test that names are properly normalized (underscore added if missing)

	// This would be tested in the actual add_completion function
	// For now, we test the logic conceptually

	names := []string{"git", "_git", "docker", "_docker"}
	expected := []string{"_git", "_git", "_docker", "_docker"}

	for name, i in names {
		normalized := name
		needs_delete := false
		if !strings.has_prefix(name, "_") {
			normalized = fmt.aprintf("_%s", name)
			needs_delete = true
		}

		msg := fmt.aprintf(
			"Name '%s' should normalize to '%s', got '%s'",
			name,
			expected[i],
			normalized,
		)
		testing.expect(t, normalized == expected[i], msg)
		delete(msg)
		if needs_delete do delete(normalized)
	}
}

@(test)
test_completion_validation_basic :: proc(t: ^testing.T) {
	// Test basic completion name validation logic

	valid_names := []string{"git", "_git", "my_completion", "tool123"}
	for name in valid_names {
		// Basic validation - no spaces, valid characters
		is_valid := !strings.contains(name, " ") && len(name) > 0
		msg := fmt.aprintf("Name '%s' should be valid", name)
		testing.expect(t, is_valid, msg)
		delete(msg)
	}

	invalid_names := []string{"", "name with spaces", "name-with-dashes"}
	for name in invalid_names {
		// These would fail in real validation
		has_issues := len(name) == 0 || strings.contains(name, " ") || strings.contains(name, "-")
		msg := fmt.aprintf("Name '%s' should be invalid", name)
		testing.expect(t, has_issues, msg)
		delete(msg)
	}
}

@(test)
test_completion_file_operations :: proc(t: ^testing.T) {
	// Test file operation concepts for completions

	test_content := "#compdef mycommand\n_mycommand() {\n  _describe 'commands' '(help:show help)'\n}"

	// Test content validation
	has_compdef := strings.contains(test_content, "#compdef")
	testing.expect(t, has_compdef, "Completion should contain #compdef directive")

	has_function := strings.contains(test_content, "_mycommand")
	testing.expect(t, has_function, "Completion should contain completion function")

	// Test size validation
	size := len(test_content)
	testing.expect(t, size > 0, "Completion content should not be empty")
	testing.expect(t, size < 10000, "Completion content should be reasonable size")
}

// OKAMI-234: wayu's completions are generated from WAYU_COMMAND_SPECS; every
// dispatchable command must have a row, and every row name must parse to
// the command it claims (so the table can't drift from the parser).
@(test)
test_wayu_command_table_covers_dispatch :: proc(t: ^testing.T) {
	for c in wayu.Command {
		if c == .UNKNOWN do continue
		found := false
		for spec in wayu.WAYU_COMMAND_SPECS {
			if spec.command == c {
				found = true; break
			}
		}
		testing.expectf(
			t,
			found,
			"Command .%v has no row in WAYU_COMMAND_SPECS (no completion)",
			c,
		)
	}
	for spec in wayu.WAYU_COMMAND_SPECS {
		testing.expect(t, len(spec.names) > 0, "row without names")
		for name in spec.names {
			parsed := wayu.parse_args([]string{name})
			delete(parsed.args)
			testing.expectf(
				t,
				parsed.command == spec.command,
				"%q parses to %v, table says %v",
				name,
				parsed.command,
				spec.command,
			)
		}
	}
}

// Every command name and action word appears in all three generated scripts.
@(test)
test_wayu_completions_list_every_command :: proc(t: ^testing.T) {
	zsh := wayu.generate_wayu_completion_zsh()
	defer delete(zsh)
	bash := wayu.generate_wayu_completion_bash()
	defer delete(bash)
	fish := wayu.generate_wayu_completion_fish()
	defer delete(fish)

	bash_lines := strings.split_lines(bash, context.temp_allocator)
	bash_top: []string
	for l in bash_lines {
		if strings.has_prefix(strings.trim_space(l), `words="path `) {
			bash_top = strings.fields(
				strings.trim(strings.trim_space(l)[len(`words=`):], `"`),
				context.temp_allocator,
			)
			break
		}
	}

	for spec in wayu.WAYU_COMMAND_SPECS {
		for name in spec.names {
			testing.expectf(
				t,
				strings.contains(zsh, fmt.tprintf("'%s:", name)),
				"zsh completion misses %q",
				name,
			)
			in_bash := false
			for w in bash_top {
				if w == name {
					in_bash = true
				}
			}
			testing.expectf(t, in_bash, "bash completion misses %q", name)
			testing.expectf(
				t,
				strings.contains(fish, fmt.tprintf("-a %s -d", name)),
				"fish completion misses %q",
				name,
			)
		}
		case_label := fmt.tprintf("%s) ", strings.join(spec.names, "|", context.temp_allocator))
		bash_case := ""
		for l in bash_lines {
			if strings.has_prefix(strings.trim_space(l), case_label) {
				bash_case = l; break
			}
		}
		// Offered words: visible actions and flags (hidden synonyms have no desc).
		offered := make([dynamic]string, context.temp_allocator)
		for a in spec.actions {
			if len(a.desc) > 0 {
				append(&offered, a.word)
			}
		}
		for f in spec.flags {
			if len(f.desc) > 0 {
				append(&offered, f.flag)
			}
		}
		if spec.json != {} {
			append(&offered, "--json")
		}
		for word in offered {
			testing.expectf(
				t,
				strings.contains(zsh, fmt.tprintf("'%s:", word)),
				"zsh: %s misses %q",
				spec.names[0],
				word,
			)
			testing.expectf(
				t,
				strings.contains(bash_case, word),
				"bash: %s misses %q",
				spec.names[0],
				word,
			)
			testing.expectf(
				t,
				strings.contains(fish, fmt.tprintf("-a '%s' -d", word)) ||
				strings.contains(fish, fmt.tprintf("-a %s -d", word)),
				"fish: %s misses %q",
				spec.names[0],
				word,
			)
		}
	}
}

// OKAMI-282: dispatch comes from WAYU_COMMAND_SPECS — every action word
// (synonyms included) parses to the action its row declares, a missing
// action word gives default_action, and an unlisted word is .UNKNOWN.
@(test)
test_wayu_command_table_drives_actions :: proc(t: ^testing.T) {
	for spec in wayu.WAYU_COMMAND_SPECS {
		if spec.command == .DOCTOR do continue // flags only
		for a in spec.actions {
			parsed := wayu.parse_args([]string{spec.names[0], a.word})
			delete(parsed.args)
			testing.expectf(
				t,
				parsed.command == spec.command && parsed.action == a.action,
				"%s %s parses to %v/%v, table says %v/%v",
				spec.names[0],
				a.word,
				parsed.command,
				parsed.action,
				spec.command,
				a.action,
			)
		}
		bare := wayu.parse_args([]string{spec.names[0]})
		delete(bare.args)
		if spec.command != .HELP && spec.command != .VERSION {
			testing.expectf(
				t,
				bare.action == spec.default_action,
				"%s: default %v, table says %v",
				spec.names[0],
				bare.action,
				spec.default_action,
			)
		}
		if len(spec.actions) > 0 {
			unk := wayu.parse_args([]string{spec.names[0], "no-such-action"})
			delete(unk.args)
			testing.expectf(
				t,
				unk.action == .UNKNOWN,
				"%s no-such-action parses to %v",
				spec.names[0],
				unk.action,
			)
		}
		for h in ([]string{"help", "-h", "--help"}) {
			parsed := wayu.parse_args([]string{spec.names[0], h})
			delete(parsed.args)
			if spec.command != .HELP && spec.command != .VERSION {
				testing.expectf(
					t,
					parsed.action == .HELP,
					"%s %s parses to %v",
					spec.names[0],
					h,
					parsed.action,
				)
			}
		}
	}
}

// The per-command flag allow-list is the table's `flags`.
@(test)
test_wayu_command_table_drives_flags :: proc(t: ^testing.T) {
	for spec in wayu.WAYU_COMMAND_SPECS {
		for f in spec.flags {
			flag := f.flag
			if strings.has_suffix(flag, "=") {
				flag = fmt.tprintf("%sx", flag)
			}
			testing.expectf(
				t,
				wayu.command_accepts_flag(spec.command, flag),
				"%s rejects its own flag %q",
				spec.names[0],
				flag,
			)
		}
		if !spec.any_flag {
			testing.expectf(
				t,
				!wayu.command_accepts_flag(spec.command, "--definitely-not-a-flag"),
				"%s accepts an unknown flag",
				spec.names[0],
			)
		}
	}
	testing.expect(t, wayu.command_accepts_flag(.DOCTOR, "--fix"), "doctor --fix")
	testing.expect(t, !wayu.command_accepts_flag(.PATH, "--fix"), "path --fix")
	testing.expect(
		t,
		wayu.command_accepts_flag(.PLUGIN, "--category=dev"),
		"plugin --category=dev",
	)
}

// --json is accepted only where the table says the output is JSON.
@(test)
test_wayu_command_table_drives_json :: proc(t: ^testing.T) {
	cases := []struct {
		args:        []string,
		unsupported: bool,
	} {
		{{"path", "list", "--json"}, false},
		{{"alias", "--json"}, false},
		{{"const", "ls", "--json"}, false},
		{{"backup", "list", "--json"}, false},
		{{"plugin", "list", "--json"}, false},
		{{"search", "x", "--json"}, false},
		{{"doctor", "--json"}, false},
		{{"path", "--help", "--json"}, false},
		{{"path", "add", "/tmp", "--json"}, true},
		{{"const", "get", "X", "--json"}, true},
		{{"hooks", "--json"}, true},
		{{"toml", "show", "--json"}, true},
	}
	for c in cases {
		saved := wayu.wayu.json_output
		parsed := wayu.parse_args(c.args)
		delete(parsed.args)
		wayu.wayu.json_output = saved
		testing.expectf(
			t,
			parsed.json_unsupported == c.unsupported,
			"%v: json_unsupported=%v",
			c.args,
			parsed.json_unsupported,
		)
	}
}

// OKAMI-181/182: every row that completes existing entries hands every
// CMD ACTION pair to `completions names <kind>` in all three scripts, and
// the hidden `names` word parses but is never offered.
@(test)
test_wayu_completions_offer_existing_entries :: proc(t: ^testing.T) {
	zsh := wayu.generate_wayu_completion_zsh()
	defer delete(zsh)
	bash := wayu.generate_wayu_completion_bash()
	defer delete(bash)
	fish := wayu.generate_wayu_completion_fish()
	defer delete(fish)

	rows := 0
	for spec in wayu.WAYU_COMMAND_SPECS {
		if spec.arg_names == .NONE {
			continue
		}
		rows += 1
		kind := wayu.COMPLETION_NAMES_KIND[spec.arg_names]
		testing.expectf(
			t,
			strings.contains(zsh, fmt.tprintf("_wayu_names %s ;;", kind)),
			"zsh misses names %s",
			kind,
		)
		testing.expectf(
			t,
			strings.contains(bash, fmt.tprintf("_wayu_names %s;", kind)),
			"bash misses names %s",
			kind,
		)
		testing.expectf(
			t,
			strings.contains(fish, fmt.tprintf("completions names %s 2>/dev/null", kind)),
			"fish misses names %s",
			kind,
		)
		for name in spec.names {
			for a in spec.actions {
				if a.action not_in spec.arg_name_actions {
					continue
				}
				pair := fmt.tprintf("\"%s %s\"", name, a.word)
				testing.expectf(t, strings.contains(zsh, pair), "zsh misses %s", pair)
				testing.expectf(t, strings.contains(bash, pair), "bash misses %s", pair)
			}
		}
	}
	testing.expect(t, rows >= 6, "path/alias/const/plugin/function/completions complete entries")

	parsed := wayu.parse_args([]string{"completions", "names", "alias"})
	defer delete(parsed.args)
	testing.expect(
		t,
		parsed.command == .COMPLETIONS && parsed.action == .SEARCH,
		"completions names parses",
	)
	testing.expect(t, !strings.contains(zsh, "'names:"), "hidden names word not offered")
}

@(test)
test_collect_completion_names :: proc(t: ^testing.T) {
	tmp := test_tmp("wayu_test_completion_names")
	os.remove_all(tmp)
	testing.expect(t, os.make_directory(tmp) == nil)
	defer os.remove_all(tmp)
	testing.expect(t, os.make_directory(fmt.tprintf("%s/completions", tmp)) == nil)

	saved_config, saved_data := wayu.wayu.config, wayu.wayu.data
	wayu.wayu.config, wayu.wayu.data = tmp, tmp
	defer {wayu.wayu.config, wayu.wayu.data = saved_config, saved_data}
	wayu.clear_toml_content_cache()
	defer wayu.clear_toml_content_cache()

	write_entries_json(
		t,
		tmp,
		`{"version": 1, "paths": [{"key": "bin", "dir": "$HOME/bin"}], "aliases": [{"name": "zz", "value": "ls"}, {"name": "ll", "value": "ls -la"}], "env": [{"name": "FOO", "value": "1"}]}`,
	)
	for f in ([]string{"_jj", "gh.bash-completion", "notes.txt"}) {
		testing.expect(
			t,
			wayu.safe_write_file(
				fmt.tprintf("%s/completions/%s", tmp, f),
				transmute([]byte)string("x"),
			),
		)
	}

	expect_names :: proc(t: ^testing.T, kind: wayu.CompletionNames, want: []string) {
		got := wayu.collect_completion_names(kind)
		defer {
			for n in got {delete(n)}
			delete(got)
		}
		testing.expectf(t, len(got) == len(want), "%v: got %v want %v", kind, got[:], want)
		if len(got) != len(want) {
			return
		}
		for w, i in want {
			testing.expectf(t, got[i] == w, "%v[%d]: got %s want %s", kind, i, got[i], w)
		}
	}
	expect_names(t, .PATH, {"$HOME/bin"})
	expect_names(t, .ALIAS, {"ll", "zz"})
	expect_names(t, .CONSTANT, {"FOO"})
	expect_names(t, .COMPLETION, {"gh", "jj"})
	expect_names(t, .PLUGIN, {})
	expect_names(t, .NONE, {})
}
