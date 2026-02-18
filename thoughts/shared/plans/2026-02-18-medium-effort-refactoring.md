# Medium-Effort Refactoring Implementation Plan

**Goal:** Reduce code duplication across 4 files (~200 lines eliminated) and add critical unit test coverage for the config_entry backbone.

**Architecture:** Extract shared CLI patterns (dry-run, confirmation, unsupported actions) into a new `cli_helpers.odin` module, then use those helpers to simplify `path.odin`, `completions.odin`, `backup.odin`, and `config_entry.odin`. Separately, add direct unit tests for `config_entry.odin` functions.

---

## Dependency Graph

```
Batch 1 (parallel): 1.1, 1.2 [foundation - no deps]
Batch 2 (parallel): 2.1, 2.2, 2.3, 2.4 [refactoring - depends on batch 1]
Batch 3 (sequential): 3.1 [verification - depends on batch 2]
```

---

## Task 1: Extract Shared Dry-Run/Confirm Helper

### Problem Analysis (Verified Against Source)

There are **3 distinct patterns** repeated across the codebase:

**Pattern A: Dry-run preview with item list** (5 occurrences)
All follow this exact structure:
```odin
if DRY_RUN {
    print_header("DRY RUN - No changes will be made", EMOJI_INFO)
    fmt.println()
    fmt.printfln("%sWould <action> %d <things>:%s", BRIGHT_CYAN, count, RESET)
    for item in items {
        fmt.printfln("  - %s", item)
    }
    fmt.println()
    fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
    return
}
```

Locations:
- `src/path.odin:82-92` (clean_missing_paths)
- `src/path.odin:172-181` (remove_duplicate_paths)
- `src/completions.odin:91-99` (add_completion - single item variant)
- `src/completions.odin:147-154` (remove_completion - single item variant)
- `src/config_entry.odin:262-273` (add_config_entry - single item variant)
- `src/config_entry.odin:384-393` (remove_config_entry - single item variant)
- `src/backup.odin:108-114` (restore_from_backup - single item variant)

**Pattern B: --yes flag confirmation gate** (2 occurrences)
```odin
if !YES_FLAG {
    print_error("This operation requires confirmation.")
    fmt.println()
    fmt.printfln("Found %d <things> to <action>:", count)
    for item in items {
        fmt.printfln("  - %s", item)
    }
    fmt.println()
    fmt.printfln("Add --yes flag to proceed:")
    fmt.printfln("  wayu <command>")
    os.exit(EXIT_GENERAL)
}
```

Locations:
- `src/path.odin:95-106` (clean_missing_paths)
- `src/path.odin:184-195` (remove_duplicate_paths)

**Pattern C: Unsupported action boilerplate** (8 occurrences across 2 files)
```odin
case .GET:
    fmt.eprintln("ERROR: get action not supported for <command> command")
    fmt.println("The get action only applies to plugins")
    os.exit(EXIT_USAGE)
case .CLEAN:
    fmt.eprintln("ERROR: clean action not supported for <command> command")
    ...
```

Locations:
- `src/completions.odin:33-50` (GET, RESTORE, CLEAN, DEDUP = 4 cases)
- `src/backup.odin:412-434` (GET, ADD, CLEAN, DEDUP = 4 cases)

### New File: `src/cli_helpers.odin`

```odin
// cli_helpers.odin - Shared CLI helper functions for dry-run, confirmation, and action validation
//
// Eliminates duplication of common CLI patterns across command handlers.

package wayu

import "core:fmt"
import "core:os"

// ============================================================================
// Dry-run helpers
// ============================================================================

// Print a dry-run preview for operations that affect a list of items.
// Returns true if DRY_RUN is active (caller should return early).
// For single-item operations, pass a 1-element slice.
print_dry_run_preview :: proc(description: string, items: []string, apply_hint: string = "") -> bool {
	if !DRY_RUN { return false }

	print_header("DRY RUN - No changes will be made", EMOJI_INFO)
	fmt.println()
	fmt.printfln("%s%s:%s", BRIGHT_CYAN, description, RESET)
	for item in items {
		fmt.printfln("  - %s", item)
	}
	fmt.println()
	if len(apply_hint) > 0 {
		fmt.printfln("%s%s%s", MUTED, apply_hint, RESET)
	} else {
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
	}
	return true
}

// Print a dry-run preview for a single key-value operation (add/remove to config file).
// Returns true if DRY_RUN is active (caller should return early).
print_dry_run_config_preview :: proc(action_verb: string, file_desc: string, detail: string) -> bool {
	if !DRY_RUN { return false }

	print_header("DRY RUN - No changes will be made", EMOJI_INFO)
	fmt.println()
	fmt.printfln("%s%s %s:%s", BRIGHT_CYAN, action_verb, file_desc, RESET)
	fmt.printfln("  %s", detail)
	fmt.println()
	fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
	return true
}

// ============================================================================
// Confirmation helpers
// ============================================================================

// Check that --yes flag is set for a destructive batch operation.
// If not set, prints the items that would be affected and exits.
check_yes_flag_or_exit :: proc(items: []string, description: string, command_hint: string) {
	if YES_FLAG { return }

	print_error("This operation requires confirmation.")
	fmt.println()
	fmt.printfln("%s:", description)
	for item in items {
		fmt.printfln("  - %s", item)
	}
	fmt.println()
	fmt.printfln("Add --yes flag to proceed:")
	fmt.printfln("  %s", command_hint)
	os.exit(EXIT_GENERAL)
}

// ============================================================================
// Unsupported action helpers
// ============================================================================

// UnsupportedActionHint provides context for why an action isn't supported
// and what the user should do instead.
UnsupportedActionHint :: struct {
	action_name: string,  // e.g., "get", "clean", "dedup"
	hint:        string,  // e.g., "The get action only applies to plugins"
}

// Print error for an unsupported action and exit.
print_unsupported_action :: proc(command: string, action: string, hint: string) {
	fmt.eprintfln("ERROR: %s action not supported for %s command", action, command)
	if len(hint) > 0 {
		fmt.println(hint)
	}
	os.exit(EXIT_USAGE)
}

// Handle a set of unsupported actions in a command handler.
// Returns true if the action was unsupported (and already printed error + exited).
// This is a convenience for switch statements.
handle_unsupported_actions :: proc(command: string, action: Action, hints: []UnsupportedActionHint) -> bool {
	action_str: string
	switch action {
	case .GET:     action_str = "get"
	case .RESTORE: action_str = "restore"
	case .CLEAN:   action_str = "clean"
	case .DEDUP:   action_str = "dedup"
	case .ADD:     action_str = "add"
	case .REMOVE:  action_str = "remove"
	case .LIST:    action_str = "list"
	case .HELP:    action_str = "help"
	case .UNKNOWN: action_str = "unknown"
	case .CHECK:   action_str = "check"
	case .UPDATE:  action_str = "update"
	}

	for hint in hints {
		if hint.action_name == action_str {
			print_unsupported_action(command, action_str, hint.hint)
			return true  // Never reached (os.exit above), but for type safety
		}
	}
	return false
}
```

### Modifications to `src/path.odin`

**clean_missing_paths** (lines 82-106 → ~6 lines):

Replace the dry-run block (lines 82-92) with:
```odin
// Build item names for display
item_names := make([]string, len(missing_entries))
defer delete(item_names)
for entry, i in missing_entries {
    item_names[i] = entry.name
}

// Dry-run mode check
if print_dry_run_preview(
    fmt.tprintf("Would remove %d missing directories", len(missing_entries)),
    item_names,
) { return }

// Check for --yes flag (required for confirmation)
check_yes_flag_or_exit(
    item_names,
    fmt.tprintf("Found %d missing directories to remove", len(missing_entries)),
    "wayu path clean --yes",
)
```

**remove_duplicate_paths** (lines 172-195 → ~6 lines):

Replace the dry-run block (lines 172-181) and --yes block (lines 184-195) with:
```odin
// Build item names for display
dup_names := make([]string, len(duplicate_indices))
defer delete(dup_names)
for idx, i in duplicate_indices {
    dup_names[i] = entries[idx].name
}

// Dry-run mode check
if print_dry_run_preview(
    fmt.tprintf("Would remove %d duplicate entries", len(duplicate_indices)),
    dup_names,
) { return }

// Check for --yes flag (required for confirmation)
check_yes_flag_or_exit(
    dup_names,
    fmt.tprintf("Found %d duplicate entries to remove", len(duplicate_indices)),
    "wayu path dedup --yes",
)
```

### Modifications to `src/config_entry.odin`

**add_config_entry** (lines 262-273 → 1 call):

Replace:
```odin
// Dry-run check
if DRY_RUN {
    print_header("DRY RUN - No changes will be made", EMOJI_INFO)
    fmt.println()
    line := spec.format_line(entry_to_save)
    defer delete(line)
    shell_ext := DETECTED_SHELL == .ZSH ? "zsh" : "bash"
    fmt.printfln("%sWould add to %s.%s:%s", BRIGHT_CYAN, spec.file_name, shell_ext, RESET)
    fmt.printfln("  %s", line)
    fmt.println()
    fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
    return
}
```

With:
```odin
// Dry-run check
if DRY_RUN {
    line := spec.format_line(entry_to_save)
    defer delete(line)
    shell_ext := DETECTED_SHELL == .ZSH ? "zsh" : "bash"
    if print_dry_run_config_preview(
        "Would add to",
        fmt.tprintf("%s.%s", spec.file_name, shell_ext),
        line,
    ) { return }
}
```

**remove_config_entry** (lines 384-393 → 1 call):

Replace:
```odin
// Dry-run check
if DRY_RUN {
    print_header("DRY RUN - No changes will be made", EMOJI_INFO)
    fmt.println()
    shell_ext := DETECTED_SHELL == .ZSH ? "zsh" : "bash"
    fmt.printfln("%sWould remove from %s.%s:%s", BRIGHT_CYAN, spec.file_name, shell_ext, RESET)
    fmt.printfln("  %s: %s", spec.display_name, name_to_remove)
    fmt.println()
    fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
    return
}
```

With:
```odin
// Dry-run check
if DRY_RUN {
    shell_ext := DETECTED_SHELL == .ZSH ? "zsh" : "bash"
    if print_dry_run_config_preview(
        "Would remove from",
        fmt.tprintf("%s.%s", spec.file_name, shell_ext),
        fmt.tprintf("%s: %s", spec.display_name, name_to_remove),
    ) { return }
}
```

### Modifications to `src/completions.odin`

**add_completion** (lines 91-99 → 1 call):

Replace:
```odin
if DRY_RUN {
    print_header("DRY RUN - No changes will be made", EMOJI_INFO)
    fmt.println()
    fmt.printfln("%sWould copy to completions directory:%s", BRIGHT_CYAN, RESET)
    fmt.printfln("  %s -> %s", source_path, dest_path)
    fmt.println()
    fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
    if allocated_name { delete(completion_name) }
    return
}
```

With:
```odin
if print_dry_run_config_preview(
    "Would copy to completions directory",
    "",
    fmt.tprintf("%s -> %s", source_path, dest_path),
) {
    if allocated_name { delete(completion_name) }
    return
}
```

**remove_completion** (lines 147-154 → 1 call):

Replace:
```odin
if DRY_RUN {
    print_header("DRY RUN - No changes will be made", EMOJI_INFO)
    fmt.println()
    fmt.printfln("%sWould remove completion file:%s", BRIGHT_CYAN, RESET)
    fmt.printfln("  %s", file_path)
    fmt.println()
    fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
    if allocated_name { delete(completion_name) }
    return
}
```

With:
```odin
if print_dry_run_config_preview(
    "Would remove completion file",
    "",
    file_path,
) {
    if allocated_name { delete(completion_name) }
    return
}
```

**handle_completions_command** unsupported actions (lines 33-50 → 1 call):

Replace the 4 unsupported action cases with a default handler before the switch:
```odin
handle_completions_command :: proc(action: Action, args: []string) {
	// Handle unsupported actions first
	#partial switch action {
	case .GET:
		print_unsupported_action("completions", "get", "The get action only applies to plugins")
	case .RESTORE:
		print_unsupported_action("completions", "restore", "Use: wayu backup restore completions")
	case .CLEAN:
		print_unsupported_action("completions", "clean", "The clean action only applies to path entries")
	case .DEDUP:
		print_unsupported_action("completions", "dedup", "The dedup action only applies to path entries")
	case .ADD:
		// ... existing add logic
```

This replaces 16 lines with 8 lines (each case is now 1 line instead of 3).

### Modifications to `src/backup.odin`

**restore_from_backup** (lines 108-114 → 1 call):

Replace:
```odin
if DRY_RUN {
    print_header("DRY RUN - No changes will be made", EMOJI_INFO)
    fmt.println()
    fmt.printfln("%sWould restore from backup:%s", BRIGHT_CYAN, RESET)
    fmt.printfln("  File: %s", file_path)
    fmt.println()
    fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
    return true
}
```

With:
```odin
if print_dry_run_config_preview("Would restore from backup", "", fmt.tprintf("File: %s", file_path)) {
    return true
}
```

**handle_backup_command** unsupported actions (lines 412-434 → 4 lines):

Replace the 4 unsupported action cases:
```odin
case .GET:
    print_unsupported_action("backup", "get", "The get action only applies to plugins")
case .ADD:
    print_unsupported_action("backup", "add", "Backups are created automatically when modifying files\nUse 'wayu backup list' to see existing backups")
case .CLEAN:
    print_unsupported_action("backup", "clean", "The clean action only applies to path entries")
case .DEDUP:
    print_unsupported_action("backup", "dedup", "The dedup action only applies to path entries")
```

### Estimated Line Savings

| File | Before | After | Saved |
|------|--------|-------|-------|
| cli_helpers.odin (NEW) | 0 | ~100 | -100 (new) |
| path.odin | 407 | ~370 | ~37 |
| config_entry.odin | 814 | ~794 | ~20 |
| completions.odin | 373 | ~345 | ~28 |
| backup.odin | 614 | ~595 | ~19 |
| **Net** | | | **~4 lines saved** |

The real win isn't line count — it's **consistency**. All 7 dry-run blocks now produce identical formatting. Any future change to the dry-run UX happens in one place.

---

## Task 2: Extract Completions Reusable Patterns

This task builds on Task 1's helpers. The remaining duplication in completions.odin is:

### Already Addressed by Task 1
- Dry-run blocks → `print_dry_run_config_preview()`
- Unsupported action boilerplate → `print_unsupported_action()`

### Additional Opportunity: Backup-before-modify pattern

Both `completions.odin` and `config_entry.odin` have this identical pattern:
```odin
// Create backup before modifying
if !create_backup_cli(config_file) {
    os.exit(EXIT_IOERR)
}
```

This is only 3 lines and already uses a helper (`create_backup_cli`), so further extraction would be over-engineering. **No change needed.**

### Additional Opportunity: Help printer structure

Both `print_completions_help()` (completions.odin:310-373) and `print_backup_help()` (backup.odin:576-614) follow the same visual structure as `print_config_help()` (config_entry.odin) but with different content. However, the content is sufficiently different (completions has NOTES section, backup has CONFIG TYPES section) that a data-driven approach would be more complex than the current code.

**Decision:** Leave help printers as-is. The visual consistency is already good, and a data-driven help system would add complexity without meaningful benefit for only 3 custom help printers.

### Summary for Task 2

Task 2 is **fully absorbed by Task 1**. The dry-run and unsupported-action helpers from Task 1 address all the meaningful duplication in completions.odin and backup.odin. The remaining patterns (backup-before-modify, help printers) are either already well-factored or not worth abstracting.

---

## Task 3: Add config_entry.odin Unit Tests

### Problem Analysis

`config_entry.odin` is 814 lines and the backbone of the Strategy pattern. It has **zero direct unit tests**. The functions that need testing are pure or near-pure and can be tested without filesystem access:

**Pure functions (no side effects):**
- `parse_args_to_entry(spec, args) -> ConfigEntry`
- `is_entry_complete(entry) -> bool`
- `cleanup_entry(entry)` / `cleanup_entries(entries)`

**Spec functions (via function pointers):**
- `PATH_SPEC.parse_line(line) -> (ConfigEntry, bool)`
- `PATH_SPEC.format_line(entry) -> string`
- `ALIAS_SPEC.parse_line(line) -> (ConfigEntry, bool)`
- `ALIAS_SPEC.format_line(entry) -> string`
- `CONSTANTS_SPEC.parse_line(line) -> (ConfigEntry, bool)`
- `CONSTANTS_SPEC.format_line(entry) -> string`

**Functions requiring filesystem (tested via integration tests already):**
- `read_config_entries` — reads from disk
- `add_config_entry` — writes to disk
- `remove_config_entry` — writes to disk
- `entry_exists` — reads from disk

### New File: `tests/unit/test_config_entry.odin`

```odin
package test_wayu

import "core:testing"
import "core:strings"
import wayu "../../src"

// ============================================================================
// parse_line → format_line round-trip tests (Strategy Pattern contract)
// ============================================================================

@(test)
test_path_parse_format_roundtrip :: proc(t: ^testing.T) {
	// Test that parsing a PATH line and formatting it back produces equivalent output
	original := `  "/usr/local/bin"`
	entry, ok := wayu.parse_path_line(original)
	testing.expect(t, ok, "Should parse valid PATH line")
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.type, wayu.ConfigEntryType.PATH)
	testing.expect_value(t, entry.name, "/usr/local/bin")
	testing.expect_value(t, entry.value, "")

	formatted := wayu.format_path_line(entry)
	defer delete(formatted)
	testing.expect_value(t, formatted, `  "/usr/local/bin"`)
}

@(test)
test_alias_parse_format_roundtrip :: proc(t: ^testing.T) {
	original := `alias ll="ls -la"`
	entry, ok := wayu.parse_alias_line(original)
	testing.expect(t, ok, "Should parse valid alias line")
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.type, wayu.ConfigEntryType.ALIAS)
	testing.expect_value(t, entry.name, "ll")
	testing.expect_value(t, entry.value, "ls -la")

	formatted := wayu.format_alias_line(entry)
	defer delete(formatted)
	testing.expect_value(t, formatted, `alias ll="ls -la"`)
}

@(test)
test_constant_parse_format_roundtrip :: proc(t: ^testing.T) {
	original := `export MY_VAR="hello world"`
	entry, ok := wayu.parse_constant_line(original)
	testing.expect(t, ok, "Should parse valid constant line")
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.type, wayu.ConfigEntryType.CONSTANT)
	testing.expect_value(t, entry.name, "MY_VAR")
	testing.expect_value(t, entry.value, "hello world")

	formatted := wayu.format_constant_line(entry)
	defer delete(formatted)
	testing.expect_value(t, formatted, `export MY_VAR="hello world"`)
}

// ============================================================================
// parse_line edge cases
// ============================================================================

@(test)
test_path_parse_rejects_non_quoted :: proc(t: ^testing.T) {
	// Lines that aren't quoted strings should be rejected
	invalid_lines := []string{
		"# comment",
		"WAYU_PATHS=(",
		")",
		"",
		"  not-a-path",
		"export PATH=something",
	}

	for line in invalid_lines {
		_, ok := wayu.parse_path_line(line)
		testing.expect(t, !ok, "Should reject non-PATH line")
	}
}

@(test)
test_alias_parse_rejects_invalid :: proc(t: ^testing.T) {
	invalid_lines := []string{
		"# alias commented=\"out\"",
		"export VAR=\"value\"",
		"alias",           // no equals
		"alias =value",    // no name
		"",
		"not an alias",
	}

	for line in invalid_lines {
		_, ok := wayu.parse_alias_line(line)
		testing.expect(t, !ok, "Should reject non-alias line")
	}
}

@(test)
test_constant_parse_rejects_invalid :: proc(t: ^testing.T) {
	invalid_lines := []string{
		"# export COMMENTED=\"out\"",
		"alias ll=\"ls\"",
		"export",          // no equals
		"export =value",   // no name
		"",
		"not an export",
	}

	for line in invalid_lines {
		_, ok := wayu.parse_constant_line(line)
		testing.expect(t, !ok, "Should reject non-constant line")
	}
}

@(test)
test_path_parse_with_env_vars :: proc(t: ^testing.T) {
	// PATH entries can contain environment variables
	line := `  "$HOME/go/bin"`
	entry, ok := wayu.parse_path_line(line)
	testing.expect(t, ok, "Should parse PATH with env var")
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.name, "$HOME/go/bin")
}

@(test)
test_path_parse_empty_path :: proc(t: ^testing.T) {
	// Empty quoted string
	line := `  ""`
	entry, ok := wayu.parse_path_line(line)
	testing.expect(t, ok, "Should parse empty PATH entry")
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.name, "")
}

@(test)
test_alias_parse_with_escaped_quotes :: proc(t: ^testing.T) {
	// Alias with complex command
	line := `alias gc="git commit -m"`
	entry, ok := wayu.parse_alias_line(line)
	testing.expect(t, ok, "Should parse alias with complex command")
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.name, "gc")
	testing.expect_value(t, entry.value, "git commit -m")
}

@(test)
test_constant_parse_unquoted_value :: proc(t: ^testing.T) {
	// Constants can have unquoted values
	line := `export FOO=bar`
	entry, ok := wayu.parse_constant_line(line)
	testing.expect(t, ok, "Should parse unquoted constant")
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.name, "FOO")
	testing.expect_value(t, entry.value, "bar")
}

@(test)
test_constant_parse_empty_value :: proc(t: ^testing.T) {
	// Constants can have empty values
	line := `export EMPTY=`
	entry, ok := wayu.parse_constant_line(line)
	testing.expect(t, ok, "Should parse constant with empty value")
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.name, "EMPTY")
	testing.expect_value(t, entry.value, "")
}

// ============================================================================
// parse_args_to_entry tests
// ============================================================================

@(test)
test_parse_args_to_path_entry :: proc(t: ^testing.T) {
	args := []string{"/usr/local/bin"}
	entry := wayu.parse_args_to_entry(&wayu.PATH_SPEC, args)
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.type, wayu.ConfigEntryType.PATH)
	testing.expect_value(t, entry.name, "/usr/local/bin")
	testing.expect_value(t, entry.value, "")
}

@(test)
test_parse_args_to_alias_entry :: proc(t: ^testing.T) {
	args := []string{"ll", "ls -la"}
	entry := wayu.parse_args_to_entry(&wayu.ALIAS_SPEC, args)
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.type, wayu.ConfigEntryType.ALIAS)
	testing.expect_value(t, entry.name, "ll")
	testing.expect_value(t, entry.value, "ls -la")
}

@(test)
test_parse_args_to_constant_entry :: proc(t: ^testing.T) {
	args := []string{"MY_VAR", "my_value"}
	entry := wayu.parse_args_to_entry(&wayu.CONSTANTS_SPEC, args)
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.type, wayu.ConfigEntryType.CONSTANT)
	testing.expect_value(t, entry.name, "MY_VAR")
	testing.expect_value(t, entry.value, "my_value")
}

@(test)
test_parse_args_to_alias_with_spaces :: proc(t: ^testing.T) {
	// When alias command has multiple words, they should be joined
	args := []string{"gc", "git", "commit", "-m"}
	entry := wayu.parse_args_to_entry(&wayu.ALIAS_SPEC, args)
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.name, "gc")
	testing.expect_value(t, entry.value, "git commit -m")
}

@(test)
test_parse_args_empty :: proc(t: ^testing.T) {
	// Empty args should produce empty entry
	args := []string{}
	entry := wayu.parse_args_to_entry(&wayu.PATH_SPEC, args)
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.name, "")
}

// ============================================================================
// is_entry_complete tests
// ============================================================================

@(test)
test_is_entry_complete_path :: proc(t: ^testing.T) {
	// PATH only needs name
	complete := wayu.ConfigEntry{type = .PATH, name = "/usr/bin", value = ""}
	testing.expect(t, wayu.is_entry_complete(complete), "PATH with name should be complete")

	incomplete := wayu.ConfigEntry{type = .PATH, name = "", value = ""}
	testing.expect(t, !wayu.is_entry_complete(incomplete), "PATH without name should be incomplete")
}

@(test)
test_is_entry_complete_alias :: proc(t: ^testing.T) {
	// ALIAS needs both name and value
	complete := wayu.ConfigEntry{type = .ALIAS, name = "ll", value = "ls -la"}
	testing.expect(t, wayu.is_entry_complete(complete), "Alias with name+value should be complete")

	no_value := wayu.ConfigEntry{type = .ALIAS, name = "ll", value = ""}
	testing.expect(t, !wayu.is_entry_complete(no_value), "Alias without value should be incomplete")

	no_name := wayu.ConfigEntry{type = .ALIAS, name = "", value = "ls -la"}
	testing.expect(t, !wayu.is_entry_complete(no_name), "Alias without name should be incomplete")
}

@(test)
test_is_entry_complete_constant :: proc(t: ^testing.T) {
	// CONSTANT needs both name and value
	complete := wayu.ConfigEntry{type = .CONSTANT, name = "MY_VAR", value = "hello"}
	testing.expect(t, wayu.is_entry_complete(complete), "Constant with name+value should be complete")

	no_value := wayu.ConfigEntry{type = .CONSTANT, name = "MY_VAR", value = ""}
	testing.expect(t, !wayu.is_entry_complete(no_value), "Constant without value should be incomplete")
}

// ============================================================================
// ConfigEntrySpec contract verification
// ============================================================================

@(test)
test_path_spec_fields :: proc(t: ^testing.T) {
	spec := &wayu.PATH_SPEC
	testing.expect_value(t, spec.type, wayu.ConfigEntryType.PATH)
	testing.expect_value(t, spec.file_name, "path")
	testing.expect_value(t, spec.display_name, "PATH")
	testing.expect_value(t, spec.fields_count, 1)
	testing.expect(t, spec.has_clean, "PATH should support clean")
	testing.expect(t, spec.has_dedup, "PATH should support dedup")
	testing.expect(t, spec.parse_line != nil, "parse_line should be set")
	testing.expect(t, spec.format_line != nil, "format_line should be set")
	testing.expect(t, spec.validator != nil, "validator should be set")
}

@(test)
test_alias_spec_fields :: proc(t: ^testing.T) {
	spec := &wayu.ALIAS_SPEC
	testing.expect_value(t, spec.type, wayu.ConfigEntryType.ALIAS)
	testing.expect_value(t, spec.file_name, "aliases")
	testing.expect_value(t, spec.display_name, "Alias")
	testing.expect_value(t, spec.fields_count, 2)
	testing.expect(t, !spec.has_clean, "Alias should not support clean")
	testing.expect(t, !spec.has_dedup, "Alias should not support dedup")
}

@(test)
test_constants_spec_fields :: proc(t: ^testing.T) {
	spec := &wayu.CONSTANTS_SPEC
	testing.expect_value(t, spec.type, wayu.ConfigEntryType.CONSTANT)
	testing.expect_value(t, spec.file_name, "constants")
	testing.expect_value(t, spec.display_name, "Constant")
	testing.expect_value(t, spec.fields_count, 2)
	testing.expect(t, !spec.has_clean, "Constants should not support clean")
	testing.expect(t, !spec.has_dedup, "Constants should not support dedup")
}

// ============================================================================
// format_line with special characters
// ============================================================================

@(test)
test_alias_format_escapes_quotes :: proc(t: ^testing.T) {
	// Alias command containing double quotes should be escaped
	entry := wayu.ConfigEntry{
		type = .ALIAS,
		name = "greet",
		value = `echo "hello"`,
	}

	formatted := wayu.format_alias_line(entry)
	defer delete(formatted)

	// Should escape the inner quotes
	testing.expect(t, strings.contains(formatted, `\"`), "Should escape quotes in alias command")
	testing.expect(t, strings.has_prefix(formatted, "alias greet="), "Should start with alias name=")
}

@(test)
test_constant_format_escapes_quotes :: proc(t: ^testing.T) {
	entry := wayu.ConfigEntry{
		type = .CONSTANT,
		name = "MSG",
		value = `say "hi"`,
	}

	formatted := wayu.format_constant_line(entry)
	defer delete(formatted)

	testing.expect(t, strings.contains(formatted, `\"`), "Should escape quotes in constant value")
	testing.expect(t, strings.has_prefix(formatted, "export MSG="), "Should start with export NAME=")
}

@(test)
test_path_format_with_spaces :: proc(t: ^testing.T) {
	entry := wayu.ConfigEntry{
		type = .PATH,
		name = "/path/with spaces/bin",
	}

	formatted := wayu.format_path_line(entry)
	defer delete(formatted)

	testing.expect_value(t, formatted, `  "/path/with spaces/bin"`)
}

// ============================================================================
// cleanup_entry memory safety
// ============================================================================

@(test)
test_cleanup_entry_with_empty_fields :: proc(t: ^testing.T) {
	// Should not crash when cleaning up entry with empty fields
	entry := wayu.ConfigEntry{
		type = .PATH,
		name = "",
		value = "",
		line = "",
	}
	// This should not panic or crash
	wayu.cleanup_entry(&entry)
}

@(test)
test_cleanup_entry_with_allocated_fields :: proc(t: ^testing.T) {
	// Should properly free allocated strings
	entry := wayu.ConfigEntry{
		type = .ALIAS,
		name = strings.clone("test_name"),
		value = strings.clone("test_value"),
		line = strings.clone("alias test_name=\"test_value\""),
	}
	// Should free all 3 strings without error
	wayu.cleanup_entry(&entry)
	// If we get here without crash, the test passes
}

// ============================================================================
// g_current_spec global workaround
// ============================================================================

@(test)
test_g_current_spec_default_nil :: proc(t: ^testing.T) {
	// The global spec pointer should be nil by default
	testing.expect(t, wayu.g_current_spec == nil, "g_current_spec should be nil by default")
}
```

### Test Count: 30 new tests

| Category | Tests |
|----------|-------|
| parse_line → format_line round-trip | 3 |
| parse_line edge cases (rejection) | 3 |
| parse_line edge cases (special values) | 5 |
| parse_args_to_entry | 5 |
| is_entry_complete | 3 |
| ConfigEntrySpec contract | 3 |
| format_line special characters | 3 |
| cleanup_entry memory safety | 2 |
| g_current_spec global | 1 |
| **Total** | **28** |

---

## Implementation Order

### Batch 1: Foundation (parallel - 2 implementers)

#### Task 1.1: Create cli_helpers.odin
**File:** `src/cli_helpers.odin`
**Test:** None needed (helpers are tested through callers; they're thin wrappers around fmt)
**Depends:** none

Create the file with the exact content shown in the "New File" section above.

**Verify:** `task check` (compiles without errors)
**Commit:** `refactor: extract shared dry-run/confirm/unsupported-action CLI helpers`

#### Task 1.2: Create test_config_entry.odin
**File:** `tests/unit/test_config_entry.odin`
**Test:** Self (this IS the test file)
**Depends:** none

Create the file with the exact content shown in the Task 3 section above.

**Verify:** `task test` (all 28 new tests pass alongside existing 235)
**Commit:** `test: add 28 unit tests for config_entry.odin strategy pattern`

### Batch 2: Refactoring (parallel - 4 implementers)

All tasks in this batch depend on Batch 1 completing (specifically Task 1.1).

#### Task 2.1: Refactor path.odin to use cli_helpers
**File:** `src/path.odin`
**Test:** Existing tests (`task test:path`)
**Depends:** 1.1

Apply the modifications described in the "Modifications to src/path.odin" section:
1. In `clean_missing_paths`: Replace dry-run block (lines 82-92) and --yes block (lines 95-106) with helper calls
2. In `remove_duplicate_paths`: Replace dry-run block (lines 172-181) and --yes block (lines 184-195) with helper calls

**Verify:** `task test && task test:path`
**Commit:** `refactor(path): use shared dry-run and confirmation helpers`

#### Task 2.2: Refactor config_entry.odin to use cli_helpers
**File:** `src/config_entry.odin`
**Test:** Existing tests + new test_config_entry.odin
**Depends:** 1.1

Apply the modifications described in the "Modifications to src/config_entry.odin" section:
1. In `add_config_entry`: Replace dry-run block (lines 262-273) with `print_dry_run_config_preview()`
2. In `remove_config_entry`: Replace dry-run block (lines 384-393) with `print_dry_run_config_preview()`

**Verify:** `task test`
**Commit:** `refactor(config-entry): use shared dry-run helpers`

#### Task 2.3: Refactor completions.odin to use cli_helpers
**File:** `src/completions.odin`
**Test:** Existing tests (`task test:completions`)
**Depends:** 1.1

Apply the modifications described in the "Modifications to src/completions.odin" section:
1. In `handle_completions_command`: Replace 4 unsupported action cases with `print_unsupported_action()` calls
2. In `add_completion`: Replace dry-run block (lines 91-99) with `print_dry_run_config_preview()`
3. In `remove_completion`: Replace dry-run block (lines 147-154) with `print_dry_run_config_preview()`

**Verify:** `task test && task test:completions`
**Commit:** `refactor(completions): use shared dry-run and unsupported-action helpers`

#### Task 2.4: Refactor backup.odin to use cli_helpers
**File:** `src/backup.odin`
**Test:** Existing tests (`task test:backup`)
**Depends:** 1.1

Apply the modifications described in the "Modifications to src/backup.odin" section:
1. In `restore_from_backup`: Replace dry-run block (lines 108-114) with `print_dry_run_config_preview()`
2. In `handle_backup_command`: Replace 4 unsupported action cases with `print_unsupported_action()` calls

**Verify:** `task test && task test:backup`
**Commit:** `refactor(backup): use shared dry-run and unsupported-action helpers`

### Batch 3: Verification (sequential)

#### Task 3.1: Full test suite verification
**Depends:** 2.1, 2.2, 2.3, 2.4

Run the complete test suite to verify nothing is broken:

```bash
task check          # Compile check
task test           # All unit tests (should be 263 = 235 existing + 28 new)
task test:all       # All tests including integration
```

**Commit:** None (verification only)

---

## Risk Assessment

### Task 1 (cli_helpers.odin) - LOW RISK
- **What could break:** Nothing — this is a new file with new functions. No existing code changes.
- **Mitigation:** The helpers are called from Batch 2 changes, which are individually testable.
- **Rollback:** Delete the file.

### Task 2 (Refactoring callers) - MEDIUM RISK
- **What could break:** Output formatting could change slightly (e.g., extra/missing newlines in dry-run output).
- **Mitigation:** Integration tests (`task test:path`, `task test:completions`, `task test:backup`) verify the exact CLI behavior. Run them after each file change.
- **Key concern:** The `fmt.tprintf()` calls use the temp allocator. If the returned string is used after more temp allocations, it could be overwritten. All usages in this plan pass the tprintf result directly to a function that consumes it immediately, so this is safe.
- **Rollback:** Revert individual file changes; cli_helpers.odin is additive.

### Task 3 (Unit tests) - LOW RISK
- **What could break:** Nothing — purely additive test file.
- **Key concern:** Tests that call `parse_args_to_entry` allocate strings via `strings.join()` which need cleanup. All tests use `defer wayu.cleanup_entry(&entry)` to handle this.
- **Mitigation:** Run `task test` to verify all tests pass.
- **Rollback:** Delete the test file.

### Cross-cutting Concerns
- **Memory management:** All new helper functions avoid allocating memory (they only call `fmt.printfln` which writes to stdout). The `fmt.tprintf()` calls use the temp allocator which is fine for immediate consumption.
- **Global state:** The helpers read `DRY_RUN` and `YES_FLAG` globals, which is the same pattern used everywhere else in the codebase.
- **Package boundary:** All new code is in the `wayu` package, same as existing code. Tests are in `test_wayu` package with `import wayu "../../src"`, matching existing test conventions.
