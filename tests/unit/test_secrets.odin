// test_secrets.odin - Secret handling: masking heuristic, exact-only get
// suggestions, and owner-only file modes for backups (OKAMI-206/207/208).

package test_wayu

import "core:testing"
import "core:os"
import "core:fmt"
import "core:strings"
import wayu "../../src"

GROUP_OTHER_BITS :: os.Permissions{.Read_Group, .Write_Group, .Execute_Group, .Read_Other, .Write_Other, .Execute_Other}

@(test)
test_looks_secret_name :: proc(t: ^testing.T) {
	secret := []string{"FIREWORKS_AI_API_KEY", "GITHUB_TOKEN", "aws_secret_access_key",
		"DB_PASSWORD", "MY_PASS", "OAUTH_CLIENT", "PRIVATE_PEM", "Credentials_File"}
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
	testing.expect(t, !wayu.looks_secret_value("https://example.com/a@b"), "@ after the path is not userinfo")
	testing.expect(t, !wayu.looks_secret_value("nvim"))
	testing.expect(t, !wayu.looks_secret_value("en_US.UTF-8"))
}

@(test)
test_mask_secret_value :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.mask_secret_value("API_TOKEN", "fake-value"), wayu.SECRET_MASK)
	testing.expect_value(t, wayu.mask_secret_value("DATABASE_URL", "mysql://a:b@h/d"), wayu.SECRET_MASK)
	testing.expect_value(t, wayu.mask_secret_value("EDITOR", "nvim"), "nvim")
	testing.expect_value(t, wayu.mask_secret_value("API_TOKEN", ""), "")
}

@(test)
test_mask_toml_env_section :: proc(t: ^testing.T) {
	content := "[shell]\ntype = \"zsh\"\n\n[aliases]\nkey = \"echo aliasval\"\n\n[env]\nEDITOR = \"nvim\"\nAPI_TOKEN = \"fake-tok-123\"\n"
	masked := wayu.mask_toml_env_section(content)
	defer delete(masked)
	testing.expect(t, !strings.contains(masked, "fake-tok-123"), "secret [env] value must be masked")
	testing.expect(t, strings.contains(masked, "API_TOKEN = \"********\""))
	testing.expect(t, strings.contains(masked, "EDITOR = \"nvim\""), "non-secret value kept")
	testing.expect(t, strings.contains(masked, "key = \"echo aliasval\""), "only [env] is masked")

	multi := "[env]\nBLOB = \"\"\"\nfake-line-1\nfake-line-2\"\"\"\nEDITOR = \"vim\"\n"
	masked_multi := wayu.mask_toml_env_section(multi)
	defer delete(masked_multi)
	testing.expect(t, !strings.contains(masked_multi, "fake-line"), "multi-line [env] body must be dropped")
	testing.expect(t, strings.contains(masked_multi, "BLOB = \"********\""))
	testing.expect(t, strings.contains(masked_multi, "EDITOR = \"vim\""), "lines after the block are kept")
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
	data_dir := fmt.tprintf("/tmp/wayu-test-secret-backup-%d", os.get_pid())
	original_data := wayu.wayu.data
	wayu.wayu.data = data_dir
	os.remove_all(data_dir)
	os.make_directory(data_dir)
	defer { wayu.wayu.data = original_data; os.remove_all(data_dir) }

	source := fmt.tprintf("%s/wayu.toml", data_dir)
	_ = os.write_entire_file(source, transmute([]byte)string("[env]\nAPI_TOKEN = \"fake\"\n"))

	backup_path, ok := wayu.create_backup(source)
	defer if ok do delete(backup_path)
	testing.expect(t, ok, "backup should succeed")
	if !ok { return }

	info, err := os.stat(backup_path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expectf(t, info.mode & GROUP_OTHER_BITS == {}, "backup must be 0600, got %v", info.mode)

	dir_info, dir_err := os.stat(fmt.tprintf("%s/backup", data_dir), context.temp_allocator)
	testing.expect(t, dir_err == nil)
	testing.expectf(t, dir_info.mode & GROUP_OTHER_BITS == {}, "backup dir must be 0700, got %v", dir_info.mode)
}

@(test)
test_backup_tightens_legacy_modes :: proc(t: ^testing.T) {
	data_dir := fmt.tprintf("/tmp/wayu-test-secret-legacy-%d", os.get_pid())
	original_data := wayu.wayu.data
	wayu.wayu.data = data_dir
	os.remove_all(data_dir)
	os.make_directory(data_dir)
	defer { wayu.wayu.data = original_data; os.remove_all(data_dir) }

	// Simulate a pre-fix install: world-readable dir + backup.
	backup_dir := fmt.tprintf("%s/backup", data_dir)
	os.make_directory(backup_dir, os.Permissions_Read_All + os.Permissions_Execute_All + {.Write_User})
	os.chmod(backup_dir, os.Permissions_Read_All + os.Permissions_Execute_All + {.Write_User})
	legacy := fmt.tprintf("%s/wayu.toml.backup.2020-01-01_00-00-00", backup_dir)
	_ = os.write_entire_file(legacy, transmute([]byte)string("old"))
	os.chmod(legacy, os.Permissions_Read_All + {.Write_User})

	source := fmt.tprintf("%s/wayu.toml", data_dir)
	_ = os.write_entire_file(source, transmute([]byte)string("[env]\n"))
	backup_path, ok := wayu.create_backup(source)
	defer if ok do delete(backup_path)
	testing.expect(t, ok)

	legacy_info, _ := os.stat(legacy, context.temp_allocator)
	testing.expectf(t, legacy_info.mode & GROUP_OTHER_BITS == {}, "legacy backup should be tightened, got %v", legacy_info.mode)
	dir_info, _ := os.stat(backup_dir, context.temp_allocator)
	testing.expectf(t, dir_info.mode & GROUP_OTHER_BITS == {}, "legacy backup dir should be tightened, got %v", dir_info.mode)
}
