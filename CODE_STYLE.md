# Code Style

> Conventions and patterns observed in the wayu codebase. Follow these when contributing.

## Naming Conventions

| Category | Convention | Example |
|----------|-----------|---------|
| Functions | `snake_case` | `create_backup`, `handle_path_command` |
| Structs | `PascalCase` | `ConfigEntry`, `BackupInfo`, `TUIState` |
| Enum types | `PascalCase` (optional suffix) | `ShellType`, `ConfigEntryType`, `Alignment`, `BorderStyle` |
| Enum values (domain) | `SCREAMING_SNAKE` | `PATH`, `ALIAS`, `MAIN_MENU` |
| Enum values (UI) | `PascalCase` | `Left`, `Center`, `Normal`, `Rounded` |
| Constants (`::`) | `SCREAMING_SNAKE_CASE` | `EXIT_SUCCESS`, `VERSION`, `TUI_PRIMARY` |
| Global mutables | `SCREAMING_SNAKE_CASE` | `DRY_RUN`, `HOME`, `WAYU_CONFIG` |
| Private globals | `_` prefix | `_GLOBALS_INITIALIZED` |
| Local variables | `snake_case` | `backup_dir`, `shell_env`, `read_ok` |
| Struct fields | `snake_case` | `original_file`, `error_message` |
| Files | `snake_case.odin` | `config_entry.odin`, `exit_codes.odin` |
| Packages | `lowercase` / `snake_case` | `wayu`, `wayu_tui`, `test_wayu` |
| Test functions | `test_<what>_<scenario>` | `test_create_backup_existing_file` |

### Function naming patterns

- `verb_noun`: `create_backup`, `detect_shell`, `parse_args`
- TUI functions: `tui_` prefix: `tui_state_init`, `tui_render`
- Module-scoped: `module_verb_noun`: `table_add_row`, `style_foreground`
- Handlers: `handle_<command>_command`: `handle_path_command`

## File Organization

- **One module concept per file** — `path.odin` for PATH, `backup.odin` for backups
- **TUI files in subdirectory** drop the `tui_` prefix: `tui/state.odin` not `tui/tui_state.odin`
- **Bridge file** in main package keeps prefix: `tui_bridge_impl.odin`
- **Test files**: `test_<module>.odin` in `tests/unit/`

### Logical groupings in `src/`

```
Core/Entry (4):     main, exit_codes, shell, types
Commands (6):       path, alias, constants, completions, backup, plugin
Config Infra (3):   config_entry, config_specs, preload
Input/Valid (3):    validation, input, special_chars
UI/Style (8):       style, theme, colors, layout, table, progress, spinner, form
Interactive (2):    fuzzy, comp_testing
Cross-cutting (2):  errors, debug
TUI Bridge (1):     tui_bridge_impl
```

## Import Style

```odin
package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:slice"
import "core:log"
import "core:mem"
import tui "tui"
```

- All `core:` imports are **unaliased** — `import "core:fmt"` not `import fmt "core:fmt"`
- Only local packages get aliases: `import tui "tui"`
- Import order: `fmt`, `os`, `strings`, then specialized (`slice`, `log`, `mem`, `time`)
- **No blank-line grouping** — flat block of imports
- Import only what's needed — TUI files use minimal imports

## Memory Management Patterns

### Pattern 1: `defer delete()` for every allocation

```odin
config_file := fmt.aprintf("%s/%s", WAYU_CONFIG, PATH_FILE)
defer delete(config_file)

content, read_ok := safe_read_file(config_file)
if !read_ok { os.exit(EXIT_IOERR) }
defer delete(content)
```

**Rule**: Every `fmt.aprintf()` and `safe_read_file()` result gets `defer delete()`.

### Pattern 2: Conditional defer

```odin
if spec.type == .PATH {
    entry_to_save.name = expand_env_vars(entry.name)
    expanded_name = true
}
defer if expanded_name { delete(entry_to_save.name) }
```

Use when allocation is conditional to avoid double-free.

### Pattern 3: String builder — build + clone + destroy

```odin
builder := strings.builder_make()
defer strings.builder_destroy(&builder)

fmt.sbprintf(&builder, "text: %s", value)
return strings.clone(strings.to_string(builder))  // clone is critical!
```

The `strings.clone()` is mandatory because `builder_destroy` frees the internal buffer.

### Pattern 4: Temp allocator for transient data

```odin
lines := strings.split(content_str, "\n", context.temp_allocator)
// No need to defer delete - temp allocator manages this
```

Pass `context.temp_allocator` when data only lives within the current function.

### Pattern 5: Dynamic arrays of structs need nested cleanup

```odin
entries := make([dynamic]ConfigEntry)
defer {
    for &entry in entries {
        cleanup_entry(&entry)
    }
    delete(entries)
}
```

### Pattern 6: Clone for ownership transfer

```odin
// Clone when storing data that outlives its source
missing_entry := ConfigEntry{
    name = strings.clone(entry.name),
    value = strings.clone(entry.value),
}

// Clone when selection result needs to survive after items array freed
selected_copy := strings.clone(selected)
defer delete(selected_copy)
```

### Pattern 7: `fmt.tprintf()` for throwaway strings

```odin
// Temp-allocated, no cleanup needed
print_info(fmt.tprintf("Selected: %s", name))
```

Use `fmt.tprintf()` instead of `fmt.aprintf()` when the string doesn't need to outlive the current expression.

## Error Handling

### Return pattern: `(value, ok: bool)`

```odin
create_backup :: proc(file_path: string) -> (backup_path: string, ok: bool) {
    // ...
    return "", false  // error
    return path, true // success
}
```

No Result/Error types — just `ok` bools. The only struct-based error is `ValidationResult`.

### Three tiers of error printing

```odin
// Tier 1: Simple colored error (stdout via fmt.printf) — for user-facing command errors
print_error("Missing required arguments for '%s %s'", spec.file_name, action)

// Tier 2: Simple error to stderr — for system/internal errors
print_error_simple("ERROR: %s", shell_msg)

// Tier 3: Rich error with suggestions (stderr) — for file/config errors
print_error_with_context(.FILE_NOT_FOUND, file_path)
// → "File not found: path.zsh"
// → "Suggestion: Run wayu init to create configuration files"
```

### Exit code pattern

```odin
print_error("Bad input: %s", name)
os.exit(EXIT_DATAERR)  // 65
```

Always: `print_error*()` then `os.exit(EXIT_*)` as two separate calls.

| Code | Constant | When |
|------|----------|------|
| 0 | `EXIT_SUCCESS` | Success |
| 1 | `EXIT_GENERAL` | General error |
| 64 | `EXIT_USAGE` | Bad CLI arguments |
| 65 | `EXIT_DATAERR` | Invalid input data |
| 66 | `EXIT_NOINPUT` | File not found |
| 73 | `EXIT_CANTCREAT` | Can't create file |
| 74 | `EXIT_IOERR` | Read/write failure |
| 77 | `EXIT_NOPERM` | Permission denied |
| 78 | `EXIT_CONFIG` | Config not initialized |

Additional codes defined but rarely used: `EXIT_UNAVAILABLE` (69), `EXIT_SOFTWARE` (70), `EXIT_OSERR` (71), `EXIT_OSFILE` (72).

### Safe file I/O wrappers

```odin
// These handle error printing internally — callers just check ok
content, read_ok := safe_read_file(config_file)
if !read_ok { os.exit(EXIT_IOERR) }

write_ok := safe_write_file(config_file, transmute([]byte)new_content)
if !write_ok { os.exit(EXIT_IOERR) }
```

### CLI usage errors include TUI hint

```odin
print_error("Missing required arguments for 'path add'")
fmt.printfln("Usage: wayu path add <path>")
fmt.printfln("Example:")
fmt.printfln("  wayu path add /usr/local/bin")
fmt.printfln("%sHint:%s For interactive mode, use: %swayu --tui%s",
    get_muted(), RESET, get_primary(), RESET)
```

Structure: **ERROR → Usage → Example → Hint to TUI**

### CLI vs TUI error handling split

- **CLI**: Fails immediately. `create_backup_cli()` → error + abort
- **TUI**: Can prompt user. `create_backup_tui()` → warning + "Continue anyway?"
- **Destructive CLI ops**: Require `--yes` flag. Without it, show what would happen + exact flag to add.

## Code Patterns

### Strategy pattern for config types

```odin
ConfigEntrySpec :: struct {
    type:         ConfigEntryType,
    file_name:    string,
    validator:    proc(ConfigEntry) -> ValidationResult,
    format_line:  proc(ConfigEntry) -> string,
    parse_line:   proc(string) -> (ConfigEntry, bool),
    // ...
}

// Usage: all commands go through the generic handler
handle_config_command :: proc(spec: ^ConfigEntrySpec, action: Action, args: []string) { ... }
```

### Config file read-modify-write

```odin
config_file := get_config_file_with_fallback(spec.file_name, DETECTED_SHELL)
defer delete(config_file)

content, read_ok := safe_read_file(config_file)
if !read_ok { os.exit(EXIT_IOERR) }
defer delete(content)

lines := strings.split(string(content), "\n", context.temp_allocator)

// ... modify lines ...

if !create_backup_cli(config_file) { os.exit(EXIT_IOERR) }

final_content := strings.join(lines, "\n")
defer delete(final_content)

write_ok := safe_write_file(config_file, transmute([]byte)final_content)
if !write_ok { os.exit(EXIT_IOERR) }
```

### Style system — value-copy builders

```odin
s := new_style()
s = style_foreground(s, "green")
s = style_bold(s, true)
s = style_border(s, .Rounded)
s = style_padding(s, 1)
result := render(s, "Hello World")
defer delete(result)
```

Each builder copies the struct, mutates one field, returns the copy. **Not** fluent chaining.

### Adaptive colors

```odin
// Always use adaptive getters, never raw ANSI constants
color := get_primary()   // Returns TrueColor, ANSI256, or ANSI based on terminal
print_success("Done!")   // Uses get_success() internally
```

**Note:** The TUI package (`src/tui/colors.odin`) maintains its own parallel color system with constants like `TUI_PRIMARY`, `TUI_SECONDARY`, etc. — separate from the main package's adaptive color getters. This is by design since the TUI always runs in a capable terminal.

### Table rendering

```odin
table := new_table([]string{"Name", "Value"})
defer table_destroy(&table)

table_style(&table, style_foreground(new_style(), "white"))
table_header_style(&table, style_bold(style_foreground(new_style(), "cyan"), true))
table_border(&table, .Normal)

table_add_row(&table, []string{"key", "value"})

output := table_render(table)
defer delete(output)
fmt.print(output)
```

### Dry-run guard

```odin
if DRY_RUN {
    print_header("DRY RUN - No changes will be made", EMOJI_INFO)
    fmt.printfln("Would add to path.zsh:")
    fmt.printfln("  %s", line)
    fmt.printfln("To apply changes, remove --dry-run flag")
    return
}
```

## Testing Patterns

### Unit test structure

```odin
@(test)
test_create_backup_existing_file :: proc(t: ^testing.T) {
    // Setup
    fake_file := "/tmp/wayu-test-file"
    defer os.remove(fake_file)
    os.write_entire_file(fake_file, transmute([]byte)"test content")

    // Act
    backup_path, ok := wayu.create_backup(fake_file)
    defer if len(backup_path) > 0 do delete(backup_path)

    // Assert
    testing.expect(t, ok, "Should succeed for existing file")
    testing.expect(t, len(backup_path) > 0, "Should return backup path")
}
```

- `@(test)` annotation on every test proc
- `testing.expect(t, condition, message)` for assertions
- `testing.expect_value(t, got, expected)` for value comparisons
- Test data in `/tmp/wayu-test-*` paths
- Cleanup with `defer os.remove()` or `defer delete()`

### Integration tests (Odin standalone)

Separate `main :: proc()` programs that exercise full command workflows:

```odin
// tests/integration/test_path_standalone.odin
main :: proc() {
    wayu.init_shell_globals()
    // ... setup temp config dir ...
    test_add_path()
    test_list_paths()
    test_remove_path()
    // ... cleanup ...
}
```

### Integration tests (Ruby)

Invoke compiled binary and check stdout/stderr/exit codes:

```ruby
# tests/integration/test_path.rb
def test_add_path
  output = `#{WAYU_BIN} path add /tmp/test-path 2>&1`
  assert_match(/added successfully/, output)
  assert_equal(0, $?.exitstatus)
end
```

### Golden file testing

```bash
task test:components:snapshot   # Generate golden files
task test:components            # Compare against golden files
```

Component rendering tested via `wayu -c=<component>` CLI flag.

## Do's and Don'ts

### Do

- Use `defer delete()` for every `fmt.aprintf()` result
- Use `safe_read_file()` / `safe_write_file()` instead of raw `os.read_entire_file`
- Create backups before any file modification
- Use `context.temp_allocator` for transient `strings.split()` calls
- Use adaptive color getters (`get_primary()`, `get_success()`) not raw ANSI codes
- Use `strings.clone()` when storing data that outlives its source
- Follow the `print_error() + os.exit(EXIT_*)` pattern
- Test in both Zsh and Bash when modifying shell-specific code
- Add `@(test)` annotation to all test procs

### Don't

- Don't use `fmt.aprintf()` without a corresponding `delete()` or `defer delete()`
- Don't call `os.exit()` from TUI code — set `state.running = false` instead (exception: pre-loop init failures in `tui/main.odin` where the TUI can't start)
- Don't import the main package from TUI — use the bridge pattern
- Don't add interactive prompts to CLI code — CLI is fully non-interactive (exception: `wayu init` has one stdin prompt, bypassable with `--yes`)
- Don't use raw ANSI escape codes — use the style/color system (known debt: `table.odin` has inline ANSI codes)
- Don't forget `strings.clone()` on builder output: `strings.clone(strings.to_string(builder))`
- Don't skip the `--yes` flag check for destructive CLI operations
- Don't use `fmt.tprintf()` for strings that need to outlive the current scope
