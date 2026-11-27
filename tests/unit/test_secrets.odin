// test_secrets.odin - Secret handling: masking heuristic, exact-only get
// suggestions, and owner-only file modes for backups (OKAMI-206/207/208).

package test_wayu

import wayu "../../src"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

GROUP_OTHER_BITS :: os.Permissions {
	.Read_Group,
	.Write_Group,
	.Execute_Group,
	.Read_Other,
	.Write_Other,
	.Execute_Other,
}

@(test)
test_looks_secret_name :: proc(t: ^testing.T) {
	secret := []string {
		"FIREWORKS_AI_API_KEY",
		"GITHUB_TOKEN",
		"aws_secret_access_key",
		"DB_PASSWORD",
		"MY_PASS",
		"OAUTH_CLIENT",
		"PRIVATE_PEM",
		"Credentials_File",
	}
	for name in secret {
		testing.expectf(t, wayu.looks_secret_name(name), "%s should look secret", name)
	}
	plain := []string{"EDITOR", "LANG", "PATH", "GOPATH", "HOMEBREW_PREFIX"}
	for name in plain {
		testing.expectf(t, !wayu.looks_secret_name(name), "%s should not look secret", name)
	}
}

@(test)
test_looks_secret_value :: proc(t: ^testing.T) {
	testing.expect(t, wayu.looks_secret_value("sk-test-not-real"))
	testing.expect(t, wayu.looks_secret_value("ghp_notarealtoken"))
	testing.expect(t, wayu.looks_secret_value("postgres://user:pw@db.local:5432/app"))
	testing.expect(t, !wayu.looks_secret_value("postgres://db.local:5432/app"))
	testing.expect(
		t,
		!wayu.looks_secret_value("https://example.com/a@b"),
		"@ after the path is not userinfo",
	)
	testing.expect(t, !wayu.looks_secret_value("nvim"))
	testing.expect(t, !wayu.looks_secret_value("en_US.UTF-8"))
}

@(test)
test_mask_secret_value :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.mask_secret_value("API_TOKEN", "fake-value"), wayu.SECRET_MASK)
	testing.expect_value(
		t,
		wayu.mask_secret_value("DATABASE_URL", "mysql://a:b@h/d"),
		wayu.SECRET_MASK,
	)
	testing.expect_value(t, wayu.mask_secret_value("EDITOR", "nvim"), "nvim")
	testing.expect_value(t, wayu.mask_secret_value("API_TOKEN", ""), "")
}

@(test)
test_suggest_similar_names_names_only :: proc(t: ^testing.T) {
	names := []string{"EDITOR", "FIREWORKS_AI_API_KEY", "FIREFOX_PROFILE", "LANG"}
	got := wayu.suggest_similar_names("FIRE", names, 5)
	defer delete(got)
	testing.expect(t, len(got) >= 2)
	if len(got) >= 2 {
		// Prefix matches rank first, ties broken alphabetically.
		testing.expect_value(t, got[0], "FIREFOX_PROFILE")
		testing.expect_value(t, got[1], "FIREWORKS_AI_API_KEY")
	}
	limited := wayu.suggest_similar_names("FIRE", names, 1)
	defer delete(limited)
	testing.expect_value(t, len(limited), 1)

	none := wayu.suggest_similar_names("FIRE", []string{}, 5)
	defer delete(none)
	testing.expect_value(t, len(none), 0)
}

@(test)
test_backup_is_owner_only :: proc(t: ^testing.T) {
	data_dir := test_tmp("wayu-test-secret-backup")
	original_data := wayu.wayu.data
	wayu.wayu.data = data_dir
	os.remove_all(data_dir)
	os.make_directory(data_dir)
	defer {wayu.wayu.data = original_data; os.remove_all(data_dir)}

	source := fmt.tprintf("%s/wayu.toml", data_dir)
	_ = os.write_entire_file(source, transmute([]byte)string("[env]\nAPI_TOKEN = \"fake\"\n"))

	backup_path, ok := wayu.create_backup(source)
	defer if ok do delete(backup_path)
	testing.expect(t, ok, "backup should succeed")
	if !ok {
		return
	}

	info, err := os.stat(backup_path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expectf(
		t,
		info.mode & GROUP_OTHER_BITS == {},
		"backup must be 0600, got %v",
		info.mode,
	)

	dir_info, dir_err := os.stat(fmt.tprintf("%s/backup", data_dir), context.temp_allocator)
	testing.expect(t, dir_err == nil)
	testing.expectf(
		t,
		dir_info.mode & GROUP_OTHER_BITS == {},
		"backup dir must be 0700, got %v",
		dir_info.mode,
	)
}

// ---------------------------------------------------------------------------
// List views mask secret-looking values unless revealed with `const list --reveal`. Values below are fake.
// ---------------------------------------------------------------------------

@(test)
test_list_display_value_masks_unless_revealed :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		wayu.list_display_value("FAKE_API_KEY", "fake-key-0001", false),
		wayu.SECRET_MASK,
	)
	testing.expect_value(
		t,
		wayu.list_display_value("FAKE_API_KEY", "fake-key-0001", true),
		"fake-key-0001",
	)
	testing.expect_value(
		t,
		wayu.list_display_value("SOME_URL", "postgres://u:fakepw@h/db", false),
		wayu.SECRET_MASK,
	)
	testing.expect_value(t, wayu.list_display_value("EDITOR", "vim", false), "vim")
	// Empty values stay empty: nothing to hide, and `********` would lie.
	testing.expect_value(t, wayu.list_display_value("FAKE_TOKEN", "", false), "")
}

@(test)
test_parse_args_reveal_flag :: proc(t: ^testing.T) {
	saved := wayu.wayu.reveal_secrets
	defer wayu.wayu.reveal_secrets = saved

	Case :: struct {
		args:    []string,
		unknown: string,
		reveal:  bool,
		action:  wayu.Action,
	}
	cases := []Case {
		{{"const", "list", "--reveal"}, "", true, .LIST},
		{{"--reveal", "const", "list", "--full"}, "", true, .LIST},
		{{"const", "--reveal", "list"}, "", true, .LIST},
		{{"toml", "show", "--reveal"}, "--reveal", false, .GET},
		{{"const", "list"}, "", false, .LIST},
		{{"path", "list", "--reveal"}, "--reveal", false, .LIST},
		{{"alias", "list", "--reveal"}, "--reveal", false, .LIST},
	}
	for c in cases {
		parsed := wayu.parse_args(c.args)
		testing.expectf(
			t,
			parsed.unknown_flag == c.unknown,
			"%v: unknown %q want %q",
			c.args,
			parsed.unknown_flag,
			c.unknown,
		)
		testing.expectf(
			t,
			wayu.wayu.reveal_secrets == c.reveal,
			"%v: reveal %v want %v",
			c.args,
			wayu.wayu.reveal_secrets,
			c.reveal,
		)
		testing.expectf(
			t,
			parsed.action == c.action,
			"%v: action %v want %v",
			c.args,
			parsed.action,
			c.action,
		)
		for a in parsed.args {
			testing.expectf(t, a != "--reveal", "%v: --reveal leaked into args", c.args)
		}
		if len(parsed.args) > 0 do delete(parsed.args)
	}
}

// A secret constant's name comes from entries.json and secrets.json; the
// "Did you mean" list shows it once.
@(test)
test_suggest_similar_names_dedupes :: proc(t: ^testing.T) {
	names := []string{"LINEAR_API", "GMKR_LINEAR_API", "LINEAR_API", "GMKR_LINEAR_API"}
	got := wayu.suggest_similar_names("linear", names, 5)
	defer delete(got)
	testing.expect_value(t, len(got), 2)
	if len(got) == 2 {
		testing.expect_value(t, got[0], "LINEAR_API")
		testing.expect_value(t, got[1], "GMKR_LINEAR_API")
	}
}
