# QA Test Plan — wayu v3.0.0

**Goal:** Close critical test coverage gaps in the two backbone modules (`config_entry.odin`, `config_specs.odin`), systematically verify exit codes, and add missing unit tests for PATH clean/dedup logic.

**Design:** Self-contained — this document is both the audit and the plan.

**Date:** 2026-02-18

---

## 1. Audit Summary

### 1.1 What Exists (272 tests total)

| Layer | Count | Files | Quality |
|-------|-------|-------|---------|
| Unit (Odin) | 235 | 17 test files in `tests/unit/` | Mixed — some thorough, some shallow |
| Integration (Odin) | 27 | 4 standalone files in `tests/integration/` | Good E2E coverage of happy paths |
| UI (Odin) | 10 | 3 files in `tests/ui/` | Adequate for visual regression |

### 1.2 What's Shallow

**Existing unit tests bypass the actual production functions.** The test files do manual string parsing that duplicates (and diverges from) the real implementation:

- **`test_alias.odin`** (6 tests): Manually splits `alias ll="ls -la"` with `strings.index` instead of calling `parse_alias_line()`. Tests the test, not the code.
- **`test_path.odin`** (7 tests): Manually extracts paths from `"  \"/usr/local/bin\""` instead of calling `parse_path_line()`. Same problem.
- **`test_constants.odin`** (6 tests): Manually parses `export FOO="bar"` instead of calling `parse_constant_line()`. Same problem.

**Impact:** If `parse_*_line()` has a bug, these tests won't catch it. They test a parallel implementation that happens to produce the same result today.

### 1.3 What's Missing Entirely

| Source File | Lines | Tests | Risk |
|-------------|-------|-------|------|
| `config_entry.odin` | 815 | **0** | **CRITICAL** — backbone of all commands |
| `config_specs.odin` | 420 | **0** | **CRITICAL** — all parse/format/validate functions |
| `exit_codes.odin` | 57 | **0** | **HIGH** — `error_to_exit_code` mapping untested |
| `path.odin` (clean/dedup) | ~200 | **0** unit | **HIGH** — complex logic, only partial integration |
| `form.odin` | 545 | **0** | LOW — TUI-only, hard to unit test |
| `layout.odin` | 523 | **0** | LOW — `visual_width` is testable |
| `theme.odin` | 508 | **0** | LOW — mostly constants |

---

## 2. Critical Gaps (P0)

### 2.1 `config_specs.odin` — Pure Functions with Zero Tests

These are **pure functions** (no I/O, no side effects) that are trivially testable:

| Function | Signature | What It Does |
|----------|-----------|--------------|
| `parse_path_line` | `proc(string) -> (ConfigEntry, bool)` | Extracts path from `"  \"/usr/local/bin\""` |
| `format_path_line` | `proc(ConfigEntry) -> string` | Produces `  "/usr/local/bin"` |
| `validate_path_entry` | `proc(ConfigEntry) -> ValidationResult` | Checks path format + existence |
| `parse_alias_line` | `proc(string) -> (ConfigEntry, bool)` | Extracts name+command from `alias ll="ls -la"` |
| `format_alias_line` | `proc(ConfigEntry) -> string` | Produces `alias ll="ls -la"` |
| `validate_alias_entry` | `proc(ConfigEntry) -> ValidationResult` | Delegates to `validate_alias` |
| `parse_constant_line` | `proc(string) -> (ConfigEntry, bool)` | Extracts name+value from `export FOO="bar"` |
| `format_constant_line` | `proc(ConfigEntry) -> string` | Produces `export FOO="bar"` |
| `validate_constant_entry` | `proc(ConfigEntry) -> ValidationResult` | Delegates to `validate_constant` |
| `validate_path_input` | `proc(string) -> InputValidation` | Interactive path validation |
| `validate_alias_name_input` | `proc(string) -> InputValidation` | Interactive alias name validation |
| `validate_alias_command_input` | `proc(string) -> InputValidation` | Interactive alias command validation |
| `validate_constant_name_input` | `proc(string) -> InputValidation` | Interactive constant name validation (with lowercase warning) |
| `validate_constant_value_input` | `proc(string) -> InputValidation` | Interactive constant value validation |

### 2.2 `config_entry.odin` — Helper Functions with Zero Tests

These helpers are testable without I/O:

| Function | Signature | What It Does |
|----------|-----------|--------------|
| `parse_args_to_entry` | `proc(^ConfigEntrySpec, []string) -> ConfigEntry` | Converts CLI args to ConfigEntry |
| `is_entry_complete` | `proc(ConfigEntry) -> bool` | Checks if entry has required fields |
| `cleanup_entry` | `proc(^ConfigEntry)` | Frees entry memory |
| `cleanup_entries` | `proc(^[]ConfigEntry)` | Frees entry array memory |

### 2.3 `exit_codes.odin` — Mapping Function Untested

| Function | Signature | What It Does |
|----------|-----------|--------------|
| `error_to_exit_code` | `proc(ErrorType) -> int` | Maps ErrorType enum to BSD exit code |

This is a pure function with 7 enum variants. Zero tests.

### 2.4 Exit Code Verification in Integration Tests

The Ruby integration tests (`test_errors.rb`) check error **messages** but do NOT systematically verify **exit codes**. The Odin standalone integration tests use `libc.system()` which returns the raw status (exit code × 256 on POSIX), but only a few tests check it.

**Missing exit code verification:**
- `wayu path add` with no args → should exit 64 (USAGE)
- `wayu alias add` with no args → should exit 64 (USAGE)
- `wayu constants add` with no args → should exit 64 (USAGE)
- `wayu path add /nonexistent` → should exit 65 (DATAERR)
- `wayu path list` without init → should exit 78 (CONFIG)
- `wayu <unknown_command>` → should exit 64 (USAGE)
- `wayu path <unknown_action>` → should exit 64 (USAGE)

---

## 3. Important Gaps (P1)

### 3.1 PATH `clean_missing_paths()` — No Unit Tests

Located in `path.odin` lines 34-120. Complex logic:
1. Reads all PATH entries
2. Expands env vars for each
3. Checks `os.exists()` for each expanded path
4. Requires `--yes` flag (or exits with error)
5. Creates backup before removal
6. Removes missing entries and writes back

**Testable aspects (without filesystem):**
- The `--yes` flag requirement (exits without it)
- Dry-run mode output
- The "no missing directories" happy path

**Integration test needed:** Create temp dir, add it as PATH, delete temp dir, run `wayu path clean --yes`, verify it's removed.

### 3.2 PATH `remove_duplicate_paths()` — No Unit Tests

Located in `path.odin` lines ~130-210. Similar structure to clean:
1. Reads all PATH entries
2. Finds duplicates by name
3. Requires `--yes` flag
4. Creates backup, removes dupes, writes back

**Integration test needed:** Add same path twice (manually edit file), run `wayu path dedup --yes`, verify only one remains.

### 3.3 Error Path Coverage

Several error paths in `config_entry.odin` are untested:
- `add_config_entry` when validation fails (line 255-259)
- `add_config_entry` when file read fails (line 282)
- `remove_config_entry` when entry not found (line 432-435)
- `handle_config_command` with `.UNKNOWN` action (line 131-134)
- `handle_config_command` with `.CLEAN` on non-PATH spec (line 116-119)
- `handle_config_command` with `.DEDUP` on non-PATH spec (line 122-127)

### 3.4 Backup Edge Cases

`test_backup.odin` has 9 tests but misses:
- Backup when config directory doesn't exist
- Backup cleanup with fewer than 5 backups (should keep all)
- Backup cleanup with exactly 5 backups (should keep all)
- Backup cleanup with 6+ backups (should keep 5)
- Restore when no backups exist

---

## 4. Nice-to-Have (P2)

### 4.1 `layout.odin` — `visual_width` is Testable

`visual_width :: proc(s: string) -> int` calculates display width accounting for ANSI escape sequences and Unicode. Pure function, easily testable:
- ASCII string → length
- String with ANSI codes → length minus escape sequences
- Unicode characters → proper width calculation
- Empty string → 0

### 4.2 `theme.odin` — Mostly Constants

508 lines of color palette definitions. Low value to test constants, but could verify:
- `get_primary()`, `get_secondary()`, etc. return non-empty strings
- Theme switching between light/dark

### 4.3 `form.odin` — TUI-Only

545 lines of interactive form handling. Requires terminal raw mode, not practical to unit test without significant mocking infrastructure.

---

## 5. Unit Test Specifications

### 5.1 NEW FILE: `tests/unit/test_config_specs.odin`

**Priority: P0 — These are pure functions that form the parsing backbone.**

```
package tests

import wayu "../../src"
import "core:testing"
import "core:strings"
```

#### PATH Parsing & Formatting (7 tests)

| Test Name | Input | Expected | Verifies |
|-----------|-------|----------|----------|
| `test_parse_path_line_valid` | `'  "/usr/local/bin"'` | `entry.name == "/usr/local/bin"`, `ok == true` | Normal quoted path extraction |
| `test_parse_path_line_with_env_var` | `'  "$HOME/.cargo/bin"'` | `entry.name == "$HOME/.cargo/bin"`, `ok == true` | Env var preserved (not expanded) |
| `test_parse_path_line_not_quoted` | `'WAYU_PATHS=('` | `ok == false` | Rejects non-entry lines |
| `test_parse_path_line_empty_quotes` | `'  ""'` | `ok == true`, `entry.name == ""` | Edge: empty path between quotes |
| `test_parse_path_line_comment` | `'# This is a comment'` | `ok == false` | Rejects comments |
| `test_format_path_line` | `ConfigEntry{name="/usr/local/bin"}` | `'  "/usr/local/bin"'` | Round-trip formatting |
| `test_format_parse_roundtrip_path` | Any valid path string | `format(parse(line)) == line` | Roundtrip consistency |

#### ALIAS Parsing & Formatting (8 tests)

| Test Name | Input | Expected | Verifies |
|-----------|-------|----------|----------|
| `test_parse_alias_line_simple` | `'alias ll="ls -la"'` | `name=="ll"`, `value=="ls -la"` | Basic alias |
| `test_parse_alias_line_with_spaces` | `'alias gs="git status"'` | `name=="gs"`, `value=="git status"` | Command with spaces |
| `test_parse_alias_line_escaped_quotes` | `'alias say="echo \"hello\""'` | `name=="say"`, `value contains escaped quotes` | Escaped quotes in command |
| `test_parse_alias_line_no_alias_prefix` | `'export FOO="bar"'` | `ok == false` | Rejects non-alias lines |
| `test_parse_alias_line_no_equals` | `'alias ll'` | `ok == false` | Rejects malformed alias |
| `test_parse_alias_line_no_quotes` | `'alias ll=ls'` | `ok == false` | Rejects unquoted value |
| `test_format_alias_line` | `ConfigEntry{name="ll", value="ls -la"}` | `'alias ll="ls -la"'` | Formatting |
| `test_format_alias_line_escapes_quotes` | `ConfigEntry{name="say", value='echo "hi"'}` | `'alias say="echo \"hi\""'` | Quote escaping in format |

#### CONSTANT Parsing & Formatting (9 tests)

| Test Name | Input | Expected | Verifies |
|-----------|-------|----------|----------|
| `test_parse_constant_line_quoted` | `'export MY_VAR="hello"'` | `name=="MY_VAR"`, `value=="hello"` | Quoted value |
| `test_parse_constant_line_unquoted` | `'export MY_VAR=hello'` | `name=="MY_VAR"`, `value=="hello"` | Unquoted value |
| `test_parse_constant_line_empty_value` | `'export MY_VAR=""'` | `name=="MY_VAR"`, `value==""` | Empty quoted value |
| `test_parse_constant_line_spaces_in_value` | `'export MSG="hello world"'` | `name=="MSG"`, `value=="hello world"` | Spaces in value |
| `test_parse_constant_line_no_export` | `'alias ll="ls"'` | `ok == false` | Rejects non-export lines |
| `test_parse_constant_line_no_equals` | `'export MY_VAR'` | `ok == false` | Rejects malformed export |
| `test_parse_constant_line_empty_name` | `'export ="value"'` | `ok == false` | Rejects empty name |
| `test_format_constant_line` | `ConfigEntry{name="FOO", value="bar"}` | `'export FOO="bar"'` | Formatting |
| `test_format_constant_line_escapes_quotes` | `ConfigEntry{name="MSG", value='say "hi"'}` | `'export MSG="say \"hi\""'` | Quote escaping |

#### Input Validators (8 tests)

| Test Name | Input | Expected | Verifies |
|-----------|-------|----------|----------|
| `test_validate_path_input_empty` | `""` | `valid == false` | Empty rejection |
| `test_validate_path_input_valid` | `"/usr/local/bin"` | `valid == true` | Valid path format |
| `test_validate_alias_name_input_empty` | `""` | `valid == false` | Empty rejection |
| `test_validate_alias_name_input_valid` | `"ll"` | `valid == true` | Valid identifier |
| `test_validate_alias_command_input_empty` | `""` | `valid == false` | Empty rejection |
| `test_validate_alias_command_input_whitespace_only` | `"   "` | `valid == false` | Whitespace-only rejection |
| `test_validate_constant_name_input_lowercase_warning` | `"my_var"` | `valid == true`, `warning != ""` | Lowercase convention warning |
| `test_validate_constant_value_input_valid` | `"hello"` | `valid == true` | Non-empty acceptance |

**Total: 32 tests**

---

### 5.2 NEW FILE: `tests/unit/test_config_entry.odin`

**Priority: P0 — Tests the helper functions that all commands depend on.**

#### `parse_args_to_entry` (6 tests)

| Test Name | Input | Expected | Verifies |
|-----------|-------|----------|----------|
| `test_parse_args_path_single` | `PATH_SPEC, ["/usr/bin"]` | `name=="/usr/bin"`, `value==""` | Single-field entry (PATH) |
| `test_parse_args_path_empty` | `PATH_SPEC, []` | `name==""`, `value==""` | No args |
| `test_parse_args_alias_two` | `ALIAS_SPEC, ["ll", "ls -la"]` | `name=="ll"`, `value=="ls -la"` | Two-field entry |
| `test_parse_args_alias_multi_word_value` | `ALIAS_SPEC, ["gc", "git", "commit", "-m"]` | `name=="gc"`, `value=="git commit -m"` | Remaining args joined as value |
| `test_parse_args_alias_one_arg` | `ALIAS_SPEC, ["ll"]` | `name==""`, `value==""` | Incomplete 2-field entry |
| `test_parse_args_constant` | `CONSTANTS_SPEC, ["FOO", "bar"]` | `name=="FOO"`, `value=="bar"` | Constants entry |

#### `is_entry_complete` (5 tests)

| Test Name | Input | Expected | Verifies |
|-----------|-------|----------|----------|
| `test_is_complete_path_with_name` | `{type=.PATH, name="/bin"}` | `true` | PATH only needs name |
| `test_is_complete_path_empty_name` | `{type=.PATH, name=""}` | `false` | PATH with empty name |
| `test_is_complete_alias_both` | `{type=.ALIAS, name="ll", value="ls"}` | `true` | Alias needs both |
| `test_is_complete_alias_no_value` | `{type=.ALIAS, name="ll", value=""}` | `false` | Alias missing value |
| `test_is_complete_constant_no_name` | `{type=.CONSTANT, name="", value="x"}` | `false` | Constant missing name |

**Total: 11 tests**

---

### 5.3 NEW FILE: `tests/unit/test_exit_codes.odin`

**Priority: P0 — Verifies the error-to-exit-code mapping is correct.**

| Test Name | Input | Expected | Verifies |
|-----------|-------|----------|----------|
| `test_error_to_exit_code_file_not_found` | `.FILE_NOT_FOUND` | `66` (EXIT_NOINPUT) | File not found mapping |
| `test_error_to_exit_code_permission_denied` | `.PERMISSION_DENIED` | `77` (EXIT_NOPERM) | Permission mapping |
| `test_error_to_exit_code_file_read_error` | `.FILE_READ_ERROR` | `74` (EXIT_IOERR) | Read error mapping |
| `test_error_to_exit_code_file_write_error` | `.FILE_WRITE_ERROR` | `74` (EXIT_IOERR) | Write error mapping |
| `test_error_to_exit_code_invalid_input` | `.INVALID_INPUT` | `65` (EXIT_DATAERR) | Invalid input mapping |
| `test_error_to_exit_code_config_not_init` | `.CONFIG_NOT_INITIALIZED` | `78` (EXIT_CONFIG) | Config error mapping |
| `test_error_to_exit_code_dir_not_found` | `.DIRECTORY_NOT_FOUND` | `66` (EXIT_NOINPUT) | Directory mapping |
| `test_exit_code_constants_values` | N/A | Verify constant values | EXIT_SUCCESS==0, EXIT_USAGE==64, etc. |

**Total: 8 tests**

---

### 5.4 UPDATED FILE: `tests/integration/test_exit_codes_standalone.odin`

**Priority: P0 — Verifies actual binary exit codes end-to-end.**

These tests build the binary and run it with `libc.system()`, checking the return status.

| Test Name | Command | Expected Exit Code | Verifies |
|-----------|---------|-------------------|----------|
| `test_exit_code_no_args` | `wayu` | `64` (USAGE) | No command given |
| `test_exit_code_unknown_command` | `wayu foobar` | `64` (USAGE) | Unknown command |
| `test_exit_code_path_add_no_args` | `wayu path add` | `64` (USAGE) | Missing required arg |
| `test_exit_code_alias_add_no_args` | `wayu alias add` | `64` (USAGE) | Missing required arg |
| `test_exit_code_constants_add_no_args` | `wayu constants add` | `64` (USAGE) | Missing required arg |
| `test_exit_code_path_rm_no_args` | `wayu path rm` | `64` (USAGE) | Missing required arg |
| `test_exit_code_path_unknown_action` | `wayu path foobar` | `64` (USAGE) | Unknown action |
| `test_exit_code_path_list_no_init` | `wayu path list` (no config dir) | `78` (CONFIG) | Config not initialized |
| `test_exit_code_help_success` | `wayu help` | `0` (SUCCESS) | Help exits cleanly |
| `test_exit_code_version_success` | `wayu version` | `0` (SUCCESS) | Version exits cleanly |
| `test_exit_code_path_add_success` | `wayu path add /tmp` (after init) | `0` (SUCCESS) | Successful add |

**Total: 11 tests**

**Note on exit code extraction:** `libc.system()` returns raw status. On POSIX, exit code = `(status >> 8) & 0xFF`. Tests must use this bit shift.

---

### 5.5 NEW FILE: `tests/unit/test_path_operations.odin`

**Priority: P1 — Tests PATH-specific clean/dedup logic.**

These tests require filesystem setup (temp directories) but test the actual functions.

| Test Name | Setup | Verifies |
|-----------|-------|----------|
| `test_clean_missing_paths_no_missing` | All paths exist | Prints "No missing directories" |
| `test_clean_missing_paths_dry_run` | Set DRY_RUN=true, some paths missing | Prints dry-run output, no file changes |
| `test_clean_missing_paths_requires_yes` | YES_FLAG=false | Prints error about --yes requirement |
| `test_dedup_no_duplicates` | All paths unique | Prints "No duplicate entries" |
| `test_dedup_dry_run` | Set DRY_RUN=true, has dupes | Prints dry-run output, no file changes |
| `test_dedup_requires_yes` | YES_FLAG=false | Prints error about --yes requirement |

**Total: 6 tests**

**Note:** Full clean/dedup with actual file modification is better tested via integration tests (see Section 6).

---

### 5.6 NEW FILE: `tests/unit/test_layout.odin`

**Priority: P2 — Tests the pure `visual_width` function.**

| Test Name | Input | Expected | Verifies |
|-----------|-------|----------|----------|
| `test_visual_width_ascii` | `"hello"` | `5` | Plain ASCII |
| `test_visual_width_empty` | `""` | `0` | Empty string |
| `test_visual_width_ansi_codes` | `"\033[31mred\033[0m"` | `3` | Strips ANSI |
| `test_visual_width_unicode_emoji` | `"🚀"` | `2` | Wide character |
| `test_visual_width_mixed` | `"\033[1mhello🌍\033[0m"` | `7` | Mixed content |

**Total: 5 tests**

---

## 6. E2E Test Scenarios

### 6.1 Full Workflow: Init → Add → List → Remove

**File:** `tests/integration/test_workflow_standalone.odin`
**Priority:** P1

| Test Name | Steps | Verifies |
|-----------|-------|----------|
| `test_path_full_workflow` | 1. `wayu init` 2. `wayu path add /tmp` 3. `wayu path list` (check output contains /tmp) 4. `wayu path rm /tmp` 5. `wayu path list` (check /tmp gone) | Complete PATH lifecycle |
| `test_alias_full_workflow` | 1. `wayu init` 2. `wayu alias add ll "ls -la"` 3. `wayu alias list` (check output) 4. `wayu alias rm ll` 5. `wayu alias list` (check gone) | Complete alias lifecycle |
| `test_constants_full_workflow` | 1. `wayu init` 2. `wayu constants add FOO bar` 3. `wayu constants list` (check output) 4. `wayu constants rm FOO` 5. `wayu constants list` (check gone) | Complete constants lifecycle |

### 6.2 Backup Create → Modify → Restore

**File:** `tests/integration/test_backup_workflow_standalone.odin`
**Priority:** P1

| Test Name | Steps | Verifies |
|-----------|-------|----------|
| `test_backup_auto_created_on_add` | 1. Init 2. Add path 3. Check backup dir has file | Auto-backup on modification |
| `test_backup_restore_reverts` | 1. Init 2. Add path A 3. Add path B (creates backup of A-only state) 4. `wayu backup restore path` 5. List paths (should have A only) | Restore reverts to pre-modification |
| `test_backup_cleanup_keeps_five` | 1. Init 2. Add 7 paths (creates 7 backups) 3. `wayu backup cleanup --yes` 4. Count backup files (should be 5) | Cleanup retention policy |

### 6.3 Dry-Run Verification

**File:** `tests/integration/test_dry_run_standalone.odin`
**Priority:** P1

| Test Name | Steps | Verifies |
|-----------|-------|----------|
| `test_dry_run_path_add` | 1. Init 2. `wayu --dry-run path add /tmp` 3. `wayu path list` (should be empty) | Dry-run doesn't modify |
| `test_dry_run_path_rm` | 1. Init 2. Add /tmp 3. `wayu --dry-run path rm /tmp` 4. List (should still have /tmp) | Dry-run doesn't remove |
| `test_dry_run_output_contains_preview` | 1. `wayu --dry-run path add /tmp` 2. Check stdout contains "DRY RUN" | Dry-run shows preview |

### 6.4 PATH Clean/Dedup Integration

**File:** `tests/integration/test_path_clean_dedup_standalone.odin`
**Priority:** P1

| Test Name | Steps | Verifies |
|-----------|-------|----------|
| `test_path_clean_removes_missing` | 1. Init 2. Create temp dir 3. Add temp dir as path 4. Delete temp dir 5. `wayu path clean --yes` 6. List (temp dir gone) | Clean removes non-existent |
| `test_path_clean_without_yes_fails` | 1. Init 2. `wayu path clean` (no --yes) 3. Check exit code != 0 | Requires --yes |
| `test_path_dedup_removes_duplicates` | 1. Init 2. Add /tmp 3. Manually edit file to duplicate /tmp 4. `wayu path dedup --yes` 5. List (only one /tmp) | Dedup works |

### 6.5 Shell Detection

**File:** Already partially covered in `tests/unit/test_shell.odin` (15 tests). No new E2E needed.

---

## 7. Execution Order

### Phase 1: P0 — Foundation (Week 1)

Execute in this order because later tests depend on earlier ones compiling:

| Order | File | Tests | Rationale |
|-------|------|-------|-----------|
| 1 | `tests/unit/test_exit_codes.odin` | 8 | Simplest — pure enum mapping, no dependencies |
| 2 | `tests/unit/test_config_specs.odin` | 32 | Pure functions — parse, format, validate |
| 3 | `tests/unit/test_config_entry.odin` | 11 | Helper functions — depends on specs working |
| 4 | `tests/integration/test_exit_codes_standalone.odin` | 11 | Binary-level exit code verification |

**Phase 1 total: 62 new tests**

### Phase 2: P1 — Error Paths & Integration (Week 2)

| Order | File | Tests | Rationale |
|-------|------|-------|-----------|
| 5 | `tests/unit/test_path_operations.odin` | 6 | PATH clean/dedup unit tests |
| 6 | `tests/integration/test_workflow_standalone.odin` | 3 | Full lifecycle E2E |
| 7 | `tests/integration/test_backup_workflow_standalone.odin` | 3 | Backup lifecycle E2E |
| 8 | `tests/integration/test_dry_run_standalone.odin` | 3 | Dry-run verification |
| 9 | `tests/integration/test_path_clean_dedup_standalone.odin` | 3 | Clean/dedup E2E |

**Phase 2 total: 18 new tests**

### Phase 3: P2 — Polish (Week 3, optional)

| Order | File | Tests | Rationale |
|-------|------|-------|-----------|
| 10 | `tests/unit/test_layout.odin` | 5 | visual_width pure function |

**Phase 3 total: 5 new tests**

---

## 8. Summary

| Phase | New Tests | Cumulative Total |
|-------|-----------|-----------------|
| Current | 0 | 272 |
| Phase 1 (P0) | 62 | 334 |
| Phase 2 (P1) | 18 | 352 |
| Phase 3 (P2) | 5 | 357 |

### Key Metrics After Full Execution

- **config_entry.odin**: 0 → 11 direct tests (+ covered by 32 config_specs tests that exercise the types)
- **config_specs.odin**: 0 → 32 direct tests
- **exit_codes.odin**: 0 → 8 unit + 11 integration = 19 tests
- **PATH clean/dedup**: 0 → 6 unit + 3 integration = 9 tests
- **Exit code coverage**: Systematic verification of all 9 exit codes across all commands

### Build & Run Commands

```bash
# Run new unit tests (after creating files)
task test

# Run new integration tests
task test:integration

# Run specific new test file
odin test tests/unit -test-name:test_parse_path_line_valid

# Run all tests
task test:all
```

---

## Appendix A: Existing Test Quality Notes

### Tests That Should Be Refactored (Not Blocked, But Recommended)

The existing shallow tests in `test_alias.odin`, `test_path.odin`, and `test_constants.odin` should eventually be refactored to call the actual `parse_*_line()` functions instead of duplicating parsing logic. However, this is **not blocking** — the new `test_config_specs.odin` will provide proper coverage of those functions. The old tests can remain as-is (they still verify string format expectations) and be refactored opportunistically.

### Integration Test Infrastructure

The Odin standalone integration tests use a pattern of:
1. Set `HOME` env var to a temp directory
2. Run `wayu init` via `libc.system()`
3. Run commands and check output in `/tmp/wayu_test_output.txt`
4. Clean up temp directory

New integration tests should follow this same pattern for consistency. The temp directory approach avoids polluting the real `~/.config/wayu/` directory.
