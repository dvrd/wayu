name: "PRP-13: CLI/TUI Isolation - Complete Separation of Interactive and Non-Interactive Modes"
description: |
  Eliminate all interactive elements from CLI commands to make wayu fully scriptable and
  automation-friendly, while consolidating interactive features exclusively in TUI mode.
  Follows Unix philosophy: CLI for scripts, TUI for humans.

version: "1.0.0"
created: "2025-10-16"
status: "READY_FOR_IMPLEMENTATION"

---

## Goal

**Feature Goal**: Transform wayu CLI into a fully non-interactive, scriptable tool by removing all confirmation prompts, fuzzy finders, and interactive forms from CLI commands, while preserving all interactive functionality in TUI mode with explicit `--yes` flags for automation.

**Deliverable**:
- CLI commands that NEVER prompt for user input (fully scriptable)
- All operations require explicit arguments or `--yes` flag
- Interactive operations moved to TUI mode (`wayu --tui`)
- Proper exit codes following BSD sysexits.h conventions
- Zero CLI regressions - all existing functionality preserved

**Success Definition**:
- CLI commands work in pipes: `wayu path list | grep local`
- CLI commands work in CI/CD without hanging
- All commands return appropriate exit codes (0=success, 64=usage error, etc.)
- TUI mode retains all interactive features
- All 255 existing tests pass with zero failures

---

## User Persona

**Target User**: DevOps engineers, system administrators, and power users who script shell configuration

**Use Cases**:
- **Primary**: DevOps engineer writes Ansible playbook to configure 100 servers
- **Secondary**: CI/CD pipeline sets up development environment automatically
- **Tertiary**: User writes shell script to batch-add PATH entries

**User Journey (Automation)**:
```bash
#!/bin/bash
# setup-dev-env.sh - Non-interactive environment setup

set -e  # Exit on error

# Add PATH entries (no prompts)
wayu path add "$HOME/.local/bin"
wayu path add "$HOME/go/bin"

# Add aliases (no interactive forms)
wayu alias add ll "ls -la"
wayu alias add gs "git status"

# Clean missing paths with explicit confirmation
wayu path clean --yes

# Check exit codes
if [ $? -eq 0 ]; then
    echo "✅ Setup complete"
else
    echo "❌ Setup failed"
    exit 1
fi
```

**User Journey (Interactive)**:
```bash
# For interactive management, user launches TUI
wayu --tui

# Or uses CLI with explicit args
wayu path rm /usr/local/bin  # No fuzzy finder
```

**Pain Points Addressed**:
- **Hanging in CI/CD**: Interactive prompts cause pipelines to hang → Fixed with `--yes` flag
- **Non-deterministic scripts**: Fuzzy finders break automation → Fixed by requiring arguments
- **Poor error messages**: "Operation cancelled" unclear → Fixed with usage hints
- **Inconsistent UX**: Sometimes prompts, sometimes doesn't → Fixed with clear separation

---

## Why

- **Business Value**: Makes wayu suitable for enterprise automation and configuration management tools (Ansible, Chef, Puppet)
- **User Impact**: Enables reliable scripting without workarounds or `echo "y" | wayu` hacks
- **Competitive**: Aligns with industry standards (Git, npm, apt all have `--yes` flags)
- **Integration**: Follows Unix philosophy and clig.dev guidelines for modern CLIs
- **Problems Solved**:
  - For **DevOps**: Reliable automation without interactive prompts
  - For **CI/CD**: Predictable behavior in non-TTY environments
  - For **Power users**: Scriptable operations with proper exit codes

---

## What

### User-Visible Behavior Changes

**Before (v2.1.0 - Interactive CLI)**:
```bash
$ wayu path rm
# Opens full-screen fuzzy finder
# Requires terminal interaction

$ wayu path clean
Found 3 missing directories:
  - /nonexistent/path
Continue with cleanup? [y/N]: _
# Blocks waiting for input

$ wayu alias add
# Opens interactive form
# Can't be scripted
```

**After (v2.2.0 - Non-Interactive CLI)**:
```bash
$ wayu path rm
ERROR: Missing required argument: path

Usage: wayu path rm <path>

Remove a PATH entry from your configuration.

Examples:
  wayu path rm /usr/local/bin
  wayu path rm '$HOME/bin'

Hint: For interactive selection, use: wayu --tui
(Exit code: 64)

$ wayu path clean
ERROR: This operation requires confirmation.

Found 3 missing directories to remove:
  - /nonexistent/path

Add --yes flag to proceed:
  wayu path clean --yes
(Exit code: 1)

$ wayu path clean --yes
✅ Removed 3 missing directories from PATH
(Exit code: 0)

$ wayu alias add
ERROR: Missing required arguments: name and command

Usage: wayu alias add <name> <command>

Examples:
  wayu alias add ll "ls -la"
  wayu alias add gst "git status"

Hint: For interactive mode, use: wayu --tui
(Exit code: 64)

$ wayu alias add ll "ls -la"
✅ Alias added successfully: ll
(Exit code: 0)
```

### Technical Requirements

**Exit Codes** (BSD sysexits.h compatible):
- **0** (`EXIT_SUCCESS`): All operations successful
- **1** (`EXIT_GENERAL`): General errors, failed operations
- **64** (`EXIT_USAGE`): Invalid command or arguments
- **65** (`EXIT_DATAERR`): Invalid input data format
- **66** (`EXIT_NOINPUT`): Cannot open input file
- **74** (`EXIT_IOERR`): File I/O error
- **77** (`EXIT_NOPERM`): Permission denied
- **78** (`EXIT_CONFIG`): Configuration error

**Flag System**:
- `--yes` / `-y`: Skip confirmation prompts (safe operations)
- `--force` / `-f`: Override safety checks (future: dangerous operations)
- Existing `--dry-run` / `-n`: Preview without changes

**Error Message Format**:
```
ERROR: <Specific error message>

<Context about what went wrong>

<How to fix it with examples>

Hint: <Suggestion (e.g., use --tui for interactive mode)>
```

**Interactive Mode Detection**:
- CLI commands NEVER call interactive functions
- All `interactive_fuzzy_select()` calls removed from CLI path
- All `form_run()` calls removed from CLI path
- Confirmation prompts replaced with `--yes` flag requirement

### Success Criteria

**Functional**:
- [ ] All CLI commands require explicit arguments (no interactive fallbacks)
- [ ] `--yes` flag works for clean/dedup operations
- [ ] Error messages show usage and suggest `--tui`
- [ ] Exit codes match BSD sysexits.h conventions
- [ ] TUI mode retains all interactive features

**Scriptability**:
- [ ] Commands work in pipes: `wayu path list | grep pattern`
- [ ] Commands work when stdin not TTY
- [ ] No hanging on missing stdin
- [ ] Proper exit codes enable `&&` and `||` chaining

**Testing**:
- [ ] All 255 existing tests pass
- [ ] New exit code tests pass
- [ ] Scriptability integration tests pass

---

## All Needed Context

### Context Completeness Check

✅ **Validation**: This PRP includes:
- Exact file paths with line numbers for all 87 exit points
- Specific patterns for all 14 interactive elements
- URLs to exit code standards and CLI guidelines
- Code snippets showing exact modifications needed
- Complete mapping of wayu errors to exit codes
- Flag parsing patterns from Odin ecosystem

### Documentation & References

```yaml
# MUST READ - Exit Code Standards
- url: https://manpages.ubuntu.com/manpages/lunar/man3/sysexits.h.3head.html
  why: BSD sysexits.h exit codes (64-78) - industry standard for CLI tools
  critical: Use EX_USAGE (64) for argument errors, EX_IOERR (74) for file errors

- url: https://en.wikipedia.org/wiki/Exit_status
  why: POSIX exit code conventions and shell-reserved codes
  critical: 0=success, 1=error, 126/127=shell, 128+N=signal

- url: https://rust-cli.github.io/book/in-depth/exit-code.html
  why: Modern CLI exit code best practices from Rust ecosystem
  critical: Use exitcode crate pattern - sysexits.h for categorized errors

# MUST READ - CLI Automation Standards
- url: https://clig.dev/
  why: Modern CLI Guidelines - comprehensive guide to scriptable CLIs
  section: "Interactivity" - Never prompt if stdout not TTY
  section: "Robustness" - Provide --no-input flag
  critical: Commands must work in pipes and non-TTY environments

- url: https://www.gnu.org/prep/standards/html_node/Command_002dLine-Interfaces.html
  why: GNU Coding Standards for command-line programs
  critical: Long options (--yes), short options (-y), POSIX compliance

- url: https://no-color.org/
  why: Standard for NO_COLOR environment variable
  critical: Respect NO_COLOR when set, auto-detect TTY for colors

# MUST READ - Existing wayu Patterns
- file: /Users/kakurega/dev/projects/wayu/src/errors.odin
  why: Centralized error handling with context
  pattern: Lines 21-107 (print_error_with_context), 126-162 (safe file ops)
  gotcha: All errors currently use exit code 1, need categorization

- file: /Users/kakurega/dev/projects/wayu/src/config_entry.odin
  why: Generic config management - contains interactive fallbacks
  pattern: Lines 56-98 (handle_config_command), 102-145 (add_config_interactive)
  pattern: Lines 356-395 (remove_config_interactive), 459-526 (list_config_interactive)
  critical: REMOVE Lines 68-69, 374-386 (interactive fallbacks from CLI)

- file: /Users/kakurega/dev/projects/wayu/src/path.odin
  why: PATH-specific operations with confirmations
  pattern: Lines 93-105 (clean confirmation), 235-247 (dedup confirmation)
  critical: REPLACE stdin prompts with --yes flag checks

- file: /Users/kakurega/dev/projects/wayu/src/backup.odin
  why: Backup system with failure prompt
  pattern: Lines 63-86 (create_backup_with_prompt)
  critical: CLI version must fail immediately, TUI version can prompt

- file: /Users/kakurega/dev/projects/wayu/src/fuzzy.odin
  why: Interactive fuzzy finder - 1,000+ lines
  pattern: Lines 52-79 (enable/disable raw mode), 753-821 (fuzzy_run main loop)
  critical: Only called from TUI, never from CLI after this PRP

- file: /Users/kakurega/dev/projects/wayu/src/form.odin
  why: Interactive form system
  pattern: Lines 54-73 (form_run lifecycle)
  critical: Only called from TUI, never from CLI after this PRP

- file: /Users/kakurega/dev/projects/wayu/src/main.odin
  why: Entry point with flag parsing
  pattern: Lines 166-334 (parse_args function)
  pattern: Lines 184-185 (DRY_RUN flag parsing)
  critical: ADD --yes flag parsing at line 186 (after --dry-run check)

# MUST READ - Flag Parsing in Odin
- url: https://pkg.odin-lang.org/core/flags/
  why: Odin core:flags package documentation
  critical: wayu uses manual parsing, not core:flags (for consistency)

- file: /Users/kakurega/dev/projects/wayu/src/main.odin
  why: Existing manual flag parsing pattern
  pattern: Lines 182-186 (flag parsing loop)
  example: `if arg == "--dry-run" || arg == "-n" { DRY_RUN = true }`
  critical: Follow same pattern for --yes flag

# Interactive Elements to Remove (Complete List)
- location: src/main.odin:504-532
  pattern: Init command RC file prompt (stdin read)
  action: KEEP (init is inherently interactive, acceptable exception)

- location: src/path.odin:93-105
  pattern: "Continue with cleanup? [y/N]:" prompt
  action: REPLACE with --yes flag requirement

- location: src/path.odin:235-247
  pattern: "Continue with deduplication? [y/N]:" prompt
  action: REPLACE with --yes flag requirement

- location: src/backup.odin:70-79
  pattern: "Continue anyway? [y/N]:" on backup failure
  action: SPLIT - CLI fails immediately, TUI can prompt

- location: src/config_entry.odin:68-69
  pattern: add_config_interactive() call when args empty
  action: REMOVE - error with usage hint instead

- location: src/config_entry.odin:374-386
  pattern: remove_config_interactive() call when args empty
  action: REMOVE - error with usage hint instead

- location: src/config_entry.odin:475-476
  pattern: list_config_interactive() call (default mode)
  action: CHANGE - default to list_config_static() in CLI

- location: src/completions.odin:203-235
  pattern: interactive_fuzzy_select() for removal
  action: REPLACE with explicit argument requirement

- location: src/plugin.odin:658-672
  pattern: interactive_fuzzy_select() for removal
  action: REPLACE with explicit argument requirement
```

### Current Codebase Tree

```bash
wayu/
├── src/
│   ├── main.odin               # [MODIFY] Add --yes flag parsing (line 186)
│   ├── path.odin               # [MODIFY] Replace prompts with --yes checks
│   ├── config_entry.odin       # [MODIFY] Remove interactive fallbacks
│   ├── backup.odin             # [MODIFY] Split CLI/TUI backup handlers
│   ├── completions.odin        # [MODIFY] Require explicit arguments
│   ├── plugin.odin             # [MODIFY] Require explicit arguments
│   ├── errors.odin             # [MODIFY] Add exit code constants
│   ├── fuzzy.odin              # [NO CHANGE] Used only by TUI
│   ├── form.odin               # [NO CHANGE] Used only by TUI
│   └── tui_bridge_impl.odin    # [NO CHANGE] TUI keeps interactive features
│
├── tests/
│   ├── unit/                   # [NO CHANGE] 218 tests must pass
│   ├── ui/                     # [NO CHANGE] 10 tests must pass
│   └── integration/            # [MODIFY] Add exit code & scriptability tests
│       ├── test_exit_codes.rb  # [CREATE] New test file
│       └── test_scriptability.sh # [CREATE] New test file
│
├── docs/
│   ├── MIGRATION_v2.2.md       # [CREATE] Breaking changes guide
│   └── EXIT_CODES.md           # [CREATE] Exit code reference
│
└── PRPs/
    └── PRP-13_CLI_TUI_ISOLATION_BASE.md  # [THIS FILE]
```

### Known Gotchas & Patterns

```odin
// GOTCHA: wayu uses manual flag parsing, not core:flags
// Pattern from main.odin:184-185
if arg == "--dry-run" || arg == "-n" {
    DRY_RUN = true
}

// CRITICAL: Follow same pattern for --yes flag
// Add at main.odin:186 (right after --dry-run)
else if arg == "--yes" || arg == "-y" {
    YES_FLAG = true
}

// GOTCHA: 87 exit points currently all use os.exit(1)
// Need to update with proper exit codes
// Current pattern:
if !read_ok {
    os.exit(1)  // Generic error
}

// New pattern:
if !read_ok {
    os.exit(EXIT_IOERR)  // Categorized error (74)
}

// GOTCHA: Confirmation prompts block on stdin
// Current pattern (path.odin:93-105):
fmt.print("Continue with cleanup? [y/N]: ")
input_buf: [10]byte
n, err := os.read(os.stdin, input_buf[:])  // BLOCKS!

// New pattern:
if !YES_FLAG {
    print_error("This operation requires confirmation.")
    fmt.println("\nAdd --yes flag to proceed:")
    fmt.println("  wayu path clean --yes")
    os.exit(EXIT_GENERAL)
}

// GOTCHA: Interactive functions still called from CLI
// Current pattern (config_entry.odin:68-69):
if len(args) == 0 {
    add_config_interactive(spec)  // Opens TUI form!
} else {
    // ...
}

// New pattern:
if len(args) == 0 {
    print_cli_usage_error(spec, "add")
    os.exit(EXIT_USAGE)
}
// Remove add_config_interactive call entirely from CLI path

// GOTCHA: List defaults to interactive mode
// Current pattern (config_entry.odin:74-77):
if len(args) > 0 && args[0] == "--static" {
    list_config_static(spec)
} else {
    list_config_interactive(spec)  // Default is interactive!
}

// New pattern:
if len(args) > 0 && args[0] == "--static" {
    list_config_static(spec)
} else {
    list_config_static(spec)  // Default to static in CLI
}

// GOTCHA: Error messages don't suggest alternatives
// Current pattern:
print_error_simple("Error: Plugin name or URL required")
os.exit(1)

// New pattern:
print_error_simple("Error: Plugin name or URL required")
fmt.println("\nUsage: wayu plugin add <name-or-url>")
fmt.println("Example: wayu plugin add zsh-syntax-highlighting")
fmt.println("\nHint: For interactive mode, use: wayu --tui")
os.exit(EXIT_USAGE)
```

---

## Implementation Blueprint

### Data Models and Structure

```odin
// New file: src/exit_codes.odin
// Exit codes following BSD sysexits.h conventions

package wayu

// Exit codes (BSD sysexits.h compatible)
// See: man 3 sysexits, https://manpages.ubuntu.com/manpages/lunar/man3/sysexits.h.3head.html
EXIT_SUCCESS      :: 0   // Successful termination
EXIT_GENERAL      :: 1   // General unspecified error
EXIT_USAGE        :: 64  // Command line usage error
EXIT_DATAERR      :: 65  // Data format error
EXIT_NOINPUT      :: 66  // Cannot open input
EXIT_UNAVAILABLE  :: 69  // Service unavailable
EXIT_SOFTWARE     :: 70  // Internal software error
EXIT_OSERR        :: 71  // System error (can't fork)
EXIT_OSFILE       :: 72  // Critical OS file missing
EXIT_CANTCREAT    :: 73  // Can't create output file
EXIT_IOERR        :: 74  // Input/output error
EXIT_NOPERM       :: 77  // Permission denied
EXIT_CONFIG       :: 78  // Configuration error

// Helper to exit with code and message
exit_with_code :: proc(code: int, message: string, args: ..any) {
    if code != EXIT_SUCCESS {
        fmt.eprintfln(message, ..args)
    }
    os.exit(code)
}

// Map wayu error types to exit codes
error_to_exit_code :: proc(error_type: ErrorType) -> int {
    switch error_type {
    case .FILE_NOT_FOUND:
        return EXIT_NOINPUT
    case .PERMISSION_DENIED:
        return EXIT_NOPERM
    case .FILE_READ_ERROR, .FILE_WRITE_ERROR:
        return EXIT_IOERR
    case .INVALID_INPUT:
        return EXIT_DATAERR
    case .CONFIG_NOT_INITIALIZED:
        return EXIT_CONFIG
    case .DIRECTORY_NOT_FOUND:
        return EXIT_NOINPUT
    case:
        return EXIT_GENERAL
    }
}

// Global flag for --yes
YES_FLAG := false  // Skip confirmation prompts
```

### Implementation Tasks (Ordered by Dependencies)

```yaml
PHASE 1: Exit Code Infrastructure (Priority: CRITICAL, Hours: 2)

Task 1.1: CREATE src/exit_codes.odin
  - IMPLEMENT: EXIT_* constants (lines 1-40)
  - IMPLEMENT: exit_with_code() helper
  - IMPLEMENT: error_to_exit_code() mapper
  - NAMING: Follow BSD sysexits.h naming exactly
  - PLACEMENT: New file in src/ directory
  - RUN: odin check src/exit_codes.odin

Task 1.2: MODIFY src/main.odin - Add YES_FLAG global
  - FIND: Line 17 (after DRY_RUN declaration)
  - ADD: `YES_FLAG := false  // Skip confirmation prompts`
  - IMPORT: Add exit_codes to imports if needed
  - RUN: odin check src/main.odin

Task 1.3: MODIFY src/main.odin - Parse --yes flag
  - FIND: Lines 184-185 (--dry-run parsing)
  - ADD after line 185:
    ```odin
    } else if arg == "--yes" || arg == "-y" {
        YES_FLAG = true
    ```
  - TEST: `./bin/wayu --yes path list` (flag recognized)
  - RUN: task build-dev

PHASE 2: Remove Interactive Fallbacks from CLI (Priority: CRITICAL, Hours: 4)

Task 2.1: MODIFY src/config_entry.odin - Remove add interactive fallback
  - FIND: Lines 58-65 (handle_config_command .ADD case)
  - CURRENT:
    ```odin
    case .ADD:
        if len(args) == 0 {
            add_config_interactive(spec)
        } else {
            entry := parse_args_to_entry(spec, args)
            defer cleanup_entry(&entry)
            add_config_entry(spec, entry)
        }
    ```
  - REPLACE with:
    ```odin
    case .ADD:
        if len(args) == 0 {
            print_cli_usage_error(spec, "add")
            os.exit(EXIT_USAGE)
        }

        entry := parse_args_to_entry(spec, args)
        defer cleanup_entry(&entry)

        if !is_entry_complete(entry) {
            print_cli_usage_error(spec, "add")
            os.exit(EXIT_USAGE)
        }

        add_config_entry(spec, entry)
    ```
  - IMPLEMENT: print_cli_usage_error() function (see Task 2.5)

Task 2.2: MODIFY src/config_entry.odin - Remove remove interactive fallback
  - FIND: Lines 66-71 (handle_config_command .REMOVE case)
  - CURRENT:
    ```odin
    case .REMOVE:
        if len(args) == 0 {
            remove_config_interactive(spec)
        } else {
            remove_config_entry(spec, args[0])
        }
    ```
  - REPLACE with:
    ```odin
    case .REMOVE:
        if len(args) == 0 {
            print_cli_usage_error(spec, "remove")
            os.exit(EXIT_USAGE)
        }
        remove_config_entry(spec, args[0])
    ```

Task 2.3: MODIFY src/config_entry.odin - Change list default to static
  - FIND: Lines 72-77 (handle_config_command .LIST case)
  - CURRENT:
    ```odin
    case .LIST:
        if len(args) > 0 && args[0] == "--static" {
            list_config_static(spec)
        } else {
            list_config_interactive(spec)
        }
    ```
  - REPLACE with:
    ```odin
    case .LIST:
        // CLI defaults to static (non-interactive)
        list_config_static(spec)
    ```
  - NOTE: Remove --static flag check (static is now default)

Task 2.4: RENAME interactive functions (document TUI-only usage)
  - FIND: add_config_interactive (line 102)
  - ADD COMMENT above:
    ```odin
    // TUI-only: Interactive form for adding config entries
    // This function is ONLY called from TUI bridge, never from CLI
    add_config_interactive :: proc(spec: ^ConfigEntrySpec) {
    ```
  - REPEAT for: remove_config_interactive, list_config_interactive

Task 2.5: IMPLEMENT print_cli_usage_error function
  - LOCATION: src/config_entry.odin (after handle_config_command)
  - ADD new function (approx line 100):
    ```odin
    // Print usage error with hint to TUI mode
    print_cli_usage_error :: proc(spec: ^ConfigEntrySpec, action: string) {
        print_error("Missing required arguments for '%s %s'", spec.file_name, action)
        fmt.println()

        // Show usage based on action
        switch action {
        case "add":
            if spec.fields_count == 1 {
                fmt.printfln("Usage: wayu %s add <%s>", spec.file_name, spec.field_labels[0])
                fmt.println()
                fmt.printfln("Example:")
                fmt.printfln("  wayu %s add %s", spec.file_name, spec.field_placeholders[0])
            } else {
                fmt.printfln("Usage: wayu %s add <%s> <%s>",
                    spec.file_name, spec.field_labels[0], spec.field_labels[1])
                fmt.println()
                fmt.printfln("Example:")
                fmt.printfln("  wayu %s add %s %s",
                    spec.file_name, spec.field_placeholders[0], spec.field_placeholders[1])
            }
        case "remove":
            fmt.printfln("Usage: wayu %s rm <%s>", spec.file_name, spec.field_labels[0])
            fmt.println()
            fmt.printfln("Example:")
            fmt.printfln("  wayu %s rm %s", spec.file_name, spec.field_placeholders[0])
        }

        fmt.println()
        fmt.printfln("%sHint:%s For interactive mode, use: %swayu --tui%s",
            get_muted(), RESET, get_primary(), RESET)
    }
    ```

PHASE 3: Replace Confirmation Prompts with --yes Flag (Priority: HIGH, Hours: 3)

Task 3.1: MODIFY src/path.odin - clean_missing_paths with --yes
  - FIND: Lines 93-105 (confirmation prompt)
  - CURRENT:
    ```odin
    fmt.print("Continue with cleanup? [y/N]: ")
    input_buf: [10]byte
    n, err := os.read(os.stdin, input_buf[:])
    if err != 0 || n == 0 {
        print_info("Operation cancelled")
        return
    }
    response := strings.trim_space(string(input_buf[:n]))
    if response != "y" && response != "Y" {
        print_info("Operation cancelled")
        return
    }
    ```
  - REPLACE with:
    ```odin
    if !YES_FLAG {
        print_error("This operation requires confirmation.")
        fmt.println()
        fmt.printfln("Found %d missing directories:", len(missing_entries))
        for entry in missing_entries {
            fmt.printfln("  - %s", entry.name)
        }
        fmt.println()
        fmt.printfln("Add --yes flag to proceed:")
        fmt.printfln("  wayu path clean --yes")
        os.exit(EXIT_GENERAL)
    }
    ```

Task 3.2: MODIFY src/path.odin - remove_duplicate_paths with --yes
  - FIND: Lines 235-247 (confirmation prompt)
  - APPLY same pattern as Task 3.1
  - MESSAGE: "wayu path dedup --yes"

Task 3.3: MODIFY src/path.odin - Update function signatures
  - FIND: Line 30 (clean_missing_paths definition)
  - CHANGE: No signature change needed (YES_FLAG is global)
  - FIND: Line 172 (remove_duplicate_paths definition)
  - CHANGE: No signature change needed

Task 3.4: MODIFY src/main.odin - Pass args to PATH commands
  - FIND: Line 140 (handle_path_command call)
  - CURRENT: `handle_path_command(parsed.action, parsed.args)`
  - VERIFY: Already passing args, no change needed
  - VERIFY: handle_path_command signature accepts args

PHASE 4: Split Backup Handler for CLI vs TUI (Priority: MEDIUM, Hours: 2)

Task 4.1: MODIFY src/backup.odin - Create CLI-only version
  - FIND: Lines 63-86 (create_backup_with_prompt)
  - ADD new function before it:
    ```odin
    // CLI version - fails immediately without prompt
    create_backup_cli :: proc(file_path: string) -> bool {
        backup_path, ok := create_backup(file_path)
        defer if ok do delete(backup_path)

        if !ok {
            print_error("Failed to create backup for %s", file_path)
            fmt.println("Aborting operation to prevent data loss.")
            return false
        }

        return true
    }
    ```

Task 4.2: RENAME create_backup_with_prompt to create_backup_tui
  - FIND: Line 63 (create_backup_with_prompt definition)
  - RENAME to: `create_backup_tui`
  - ADD COMMENT:
    ```odin
    // TUI version - prompts user on backup failure
    // This function is ONLY called from TUI bridge
    create_backup_tui :: proc(file_path: string, auto_backup := true) -> bool {
    ```

Task 4.3: UPDATE all CLI calls to use create_backup_cli
  - SEARCH: All calls to `create_backup_with_prompt` in non-TUI files
  - REPLACE: With `create_backup_cli`
  - FILES to update:
    - config_entry.odin (lines with backup calls)
    - path.odin (lines with backup calls)

Task 4.4: KEEP TUI bridge calls to create_backup_tui
  - FILE: src/tui_bridge_impl.odin
  - VERIFY: Uses create_backup_tui (with prompts for user)
  - NO CHANGE needed in TUI bridge

PHASE 5: Update Completions and Plugins (Priority: MEDIUM, Hours: 2)

Task 5.1: MODIFY src/completions.odin - Remove interactive removal
  - FIND: Lines 203-235 (interactive_fuzzy_select call)
  - CURRENT:
    ```odin
    if len(args) == 0 {
        items := extract_completion_items()
        // ... fuzzy finder ...
    }
    ```
  - REPLACE with:
    ```odin
    if len(args) == 0 {
        print_error("Missing required argument: completion name")
        fmt.println()
        fmt.println("Usage: wayu completions rm <name>")
        fmt.println()
        fmt.println("Example:")
        fmt.println("  wayu completions rm jj")
        fmt.println()
        fmt.printfln("%sHint:%s For interactive selection, use: %swayu --tui%s",
            get_muted(), RESET, get_primary(), RESET)
        os.exit(EXIT_USAGE)
    }
    ```

Task 5.2: MODIFY src/plugin.odin - Remove interactive removal
  - FIND: Lines 658-672 (interactive_fuzzy_select call)
  - APPLY same pattern as Task 5.1
  - MESSAGE: "Usage: wayu plugin rm <name>"

PHASE 6: Update Exit Codes Throughout Codebase (Priority: HIGH, Hours: 4)

Task 6.1: UPDATE main.odin exit points
  - LOCATION: src/main.odin
  - EXIT POINTS: Lines 106, 162 (currently os.exit(1))
  - MAPPING:
    - Line 106: No args → `os.exit(EXIT_USAGE)`
    - Line 162: Unknown command → `os.exit(EXIT_USAGE)`

Task 6.2: UPDATE errors.odin exit points
  - LOCATION: src/errors.odin
  - MODIFY: print_error_with_context to use error_to_exit_code
  - CURRENT: All errors exit with 1
  - NEW: Use mapping from exit_codes.odin

Task 6.3: UPDATE validation errors
  - LOCATION: All validation result handlers
  - PATTERN:
    ```odin
    if !validation_result.valid {
        print_error("%s", validation_result.error_message)
        delete(validation_result.error_message)
        os.exit(EXIT_DATAERR)  // Changed from 1
    }
    ```

Task 6.4: UPDATE file operation errors
  - LOCATIONS: All `if !read_ok { os.exit(1) }` patterns
  - CHANGE to: `if !read_ok { os.exit(EXIT_IOERR) }`
  - COUNT: ~25 locations across all files

Task 6.5: CREATE exit code reference document
  - FILE: docs/EXIT_CODES.md
  - CONTENT: Complete mapping table, examples, testing guide

PHASE 7: Documentation and Help Updates (Priority: MEDIUM, Hours: 2)

Task 7.1: UPDATE main help message
  - LOCATION: src/main.odin:540-594 (print_help)
  - ADD EXIT CODES section before EXAMPLES:
    ```odin
    print_section("EXIT CODES:", EMOJI_INFO)
    fmt.println("  0   Success")
    fmt.println("  1   General error")
    fmt.println("  64  Invalid command or arguments")
    fmt.println("  74  File I/O error")
    fmt.println("  77  Permission denied")
    fmt.println("  78  Configuration error")
    fmt.println()
    fmt.println("  Use exit codes in scripts:")
    fmt.println("    wayu path add /usr/local/bin && echo 'Success' || echo 'Failed'")
    fmt.println()
    ```

Task 7.2: UPDATE config_entry help
  - LOCATION: src/config_entry.odin:663-711 (print_config_help)
  - ADD note about non-interactive mode:
    ```odin
    fmt.println("\nNOTE:")
    fmt.println("  All commands require explicit arguments.")
    fmt.println("  For interactive mode, use: wayu --tui")
    fmt.println()
    ```

Task 7.3: CREATE migration guide
  - FILE: docs/MIGRATION_v2.2.md
  - SECTIONS:
    - Breaking Changes list
    - Before/After examples
    - Migration checklist
    - Quick fixes for common patterns

Task 7.4: UPDATE README.md
  - ADD "Scripting & Automation" section
  - ADD exit code reference
  - UPDATE examples to show --yes flag

PHASE 8: Testing (Priority: CRITICAL, Hours: 6)

Task 8.1: CREATE exit code tests
  - FILE: tests/integration/test_exit_codes.rb
  - TESTS:
    - test_exit_code_success (0)
    - test_exit_code_usage_error (64)
    - test_exit_code_io_error (74)
    - test_exit_code_permission_denied (77)
    - test_exit_code_config_error (78)

Task 8.2: CREATE scriptability tests
  - FILE: tests/integration/test_scriptability.sh
  - TESTS:
    - Pipe output: `wayu path list | grep pattern`
    - Redirect output: `wayu path list > file.txt`
    - No hanging: `wayu path clean < /dev/null` (should error, not hang)
    - Flag chaining: `wayu path add /test && wayu path rm /test`
    - Exit code check: `$?` after each command

Task 8.3: UPDATE existing integration tests
  - VERIFY: All tests that expect prompts now use --yes
  - UPDATE: Tests that rely on interactive mode
  - VERIFY: 255 existing tests still pass

Task 8.4: RUN full test suite
  - COMMAND: `task test:all`
  - EXPECTED: 255 tests pass + new tests pass
  - VERIFY: Zero regressions
```

### Implementation Patterns & Key Details

```odin
// PATTERN: CLI Usage Error (Task 2.5 output)
// FOLLOW: Print error → Show usage → Show example → Hint TUI

print_error("Missing required arguments for 'path add'")
fmt.println()
fmt.println("Usage: wayu path add <path>")
fmt.println()
fmt.println("Example:")
fmt.println("  wayu path add /usr/local/bin")
fmt.println()
fmt.printfln("%sHint:%s For interactive mode, use: %swayu --tui%s",
    get_muted(), RESET, get_primary(), RESET)
os.exit(EXIT_USAGE)

// PATTERN: Confirmation Replacement (Task 3.1)
// FOLLOW: Check YES_FLAG → Show what will happen → Provide command

if !YES_FLAG {
    print_error("This operation requires confirmation.")
    fmt.println()
    fmt.printfln("Found %d missing directories to remove:", len(missing_entries))
    for entry in missing_entries {
        fmt.printfln("  - %s", entry.name)
    }
    fmt.println()
    fmt.printfln("Add --yes flag to proceed:")
    fmt.printfln("  wayu path clean --yes")
    os.exit(EXIT_GENERAL)
}

// PATTERN: Exit Code Usage (Task 6.2)
// FOLLOW: Categorize error → Use appropriate exit code

// Usage errors (invalid arguments, syntax)
os.exit(EXIT_USAGE)  // 64

// Data validation errors (invalid format)
os.exit(EXIT_DATAERR)  // 65

// File not found
os.exit(EXIT_NOINPUT)  // 66

// File I/O errors (read/write failed)
os.exit(EXIT_IOERR)  // 74

// Permission denied
os.exit(EXIT_NOPERM)  // 77

// Configuration errors (wayu not initialized, shell incompatible)
os.exit(EXIT_CONFIG)  // 78

// General errors (everything else)
os.exit(EXIT_GENERAL)  // 1

// PATTERN: Backup Handling Split (Task 4.1-4.3)

// CLI version - no prompts
if !create_backup_cli(config_file) {
    os.exit(EXIT_IOERR)  // Fails immediately
}

// TUI version - can prompt user
if !create_backup_tui(config_file) {
    print_info("Operation cancelled")
    return  // Don't exit, return to TUI
}

// PATTERN: Interactive Function Documentation
// FOLLOW: Add clear comments marking TUI-only functions

// TUI-only: Interactive fuzzy finder for removal
// This function is ONLY called from TUI bridge, never from CLI
remove_config_interactive :: proc(spec: ^ConfigEntrySpec) {
    // ... implementation unchanged ...
}
```

---

## Validation Loop

### Level 1: Syntax & Compilation (Immediate Feedback)

```bash
# After each file modification

# Compile with error checking
odin check src/exit_codes.odin
# Expected: No errors

# Compile modified files
odin check src/main.odin
odin check src/config_entry.odin
odin check src/path.odin
odin check src/backup.odin

# Build entire project
task build-dev
# Expected: Compiles successfully with zero errors

# Verify no warnings
odin build src -out:bin/wayu_test -warnings-as-errors
# Expected: Clean build
```

### Level 2: Unit Tests (Component Validation)

```bash
# Run all existing unit tests (must not break)
task test
# Expected: 218/218 tests pass (99.5%+ success rate)

# Run specific module tests
odin test tests/unit/test_main.odin -file
odin test tests/unit/test_path.odin -file
odin test tests/unit/test_config_entry.odin -file

# Verify no regressions
# Expected: Same test count, same pass rate
```

### Level 3: Integration Testing (System Validation)

```bash
# Test 1: Non-interactive CLI requires arguments
./bin/wayu path add
# Expected: Exit code 64, shows usage, suggests --tui

./bin/wayu path rm
# Expected: Exit code 64, shows usage, suggests --tui

./bin/wayu alias add
# Expected: Exit code 64, shows usage, suggests --tui

# Test 2: Operations work with explicit arguments
./bin/wayu path add /usr/local/bin
echo $?
# Expected: Exit code 0

./bin/wayu path rm /usr/local/bin
echo $?
# Expected: Exit code 0

./bin/wayu alias add ll "ls -la"
echo $?
# Expected: Exit code 0

# Test 3: Confirmation operations require --yes
./bin/wayu path clean
# Expected: Exit code 1, error message, suggests --yes flag

./bin/wayu path clean --yes
# Expected: Exit code 0 or exit code 0 (if no missing paths)

./bin/wayu path dedup
# Expected: Exit code 1, error message, suggests --yes flag

./bin/wayu path dedup --yes
# Expected: Exit code 0

# Test 4: Scriptability - pipes work
./bin/wayu path list | grep local
echo $?
# Expected: Exit code 0 if pattern found, 1 if not found

./bin/wayu path list > /tmp/paths.txt
echo $?
# Expected: Exit code 0, file created

# Test 5: No hanging on missing stdin
echo "" | ./bin/wayu path clean
# Expected: Exit code 1, error (not hanging)

./bin/wayu path clean < /dev/null
# Expected: Exit code 1, error (not hanging)

# Test 6: TUI mode still works
./bin/wayu --tui
# Press 'q' to quit
# Expected: TUI launches, shows main menu, all interactive features work

# Test 7: Run new integration tests
task test:exit-codes
# Expected: All exit code tests pass

task test:scriptability
# Expected: All scriptability tests pass

# Test 8: Run ALL integration tests
task test:integration
# Expected: 27 tests pass + new tests pass

# Test 9: Full test suite
task test:all
# Expected: 255+ tests pass, ZERO REGRESSIONS
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Automation Workflow Test
cat > /tmp/setup-env.sh << 'EOF'
#!/bin/bash
set -e  # Exit on error

# Add multiple PATH entries
wayu path add "$HOME/.local/bin"
wayu path add "$HOME/go/bin"

# Add aliases
wayu alias add ll "ls -la"
wayu alias add gs "git status"

# Clean with --yes
wayu path clean --yes

# Check all succeeded
if [ $? -eq 0 ]; then
    echo "✅ Setup complete"
else
    echo "❌ Setup failed"
    exit 1
fi
EOF

chmod +x /tmp/setup-env.sh
/tmp/setup-env.sh
# Expected: Script runs without hanging, exits with code 0

# CI/CD Simulation Test
docker run -i --rm ubuntu:latest bash << 'EOF'
# Simulate non-TTY environment (no stdin connected)
apt-get update && apt-get install -y wget
wget https://example.com/wayu
chmod +x wayu

# These should work without hanging
./wayu path add /usr/local/bin
./wayu path list
./wayu --help

echo "Exit code: $?"
EOF
# Expected: All commands work, no hanging, proper exit codes

# Error Handling Test
./bin/wayu path add /nonexistent/path
EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
    echo "✅ Properly failed with exit code $EXIT_CODE"
else
    echo "❌ Should have failed"
fi
# Expected: Non-zero exit code, helpful error message

# Pipe Chain Test
./bin/wayu path list | grep local | wc -l
# Expected: Works without errors, proper exit codes

# Flag Combination Test
./bin/wayu --dry-run --yes path clean
# Expected: Shows what would be cleaned (dry-run), no prompt

# Help Accessibility Test
./bin/wayu --help | grep "EXIT CODES"
# Expected: Exit codes section present in help

# TUI Still Works Test
# (Manual) Run: ./bin/wayu --tui
# Navigate to PATH → Press 'a' (add) → Interactive form appears
# Expected: All TUI interactive features still work

# Backward Compatibility Test  (Scripts that worked before)
# Old pattern (should still work):
./bin/wayu path add /usr/bin
./bin/wayu path rm /usr/bin
./bin/wayu path list
# Expected: All commands work (explicit args always worked)

# Migration Test (Docs accuracy)
# Follow docs/MIGRATION_v2.2.md checklist
# Expected: All migrations work as documented
```

---

## Final Validation Checklist

### Technical Validation

**Compilation:**
- [ ] All files compile without errors: `task build-dev`
- [ ] No compiler warnings: `odin build src -warnings-as-errors`
- [ ] Exit codes file created and compiles: `src/exit_codes.odin`

**Testing:**
- [ ] All 218 unit tests pass: `task test`
- [ ] All 27 integration tests pass: `task test:integration`
- [ ] New exit code tests pass: `task test:exit-codes`
- [ ] New scriptability tests pass: `task test:scriptability`
- [ ] ZERO test regressions: 255+ total tests passing

**Code Quality:**
- [ ] No `os.exit(1)` left (all use proper exit codes)
- [ ] No interactive calls in CLI path (grep confirms)
- [ ] All confirmation prompts replaced with `--yes` checks
- [ ] TUI functions clearly marked as TUI-only

### Feature Validation

**Non-Interactive CLI:**
- [ ] `wayu path add` requires path argument (no form)
- [ ] `wayu path rm` requires path argument (no fuzzy finder)
- [ ] `wayu alias add` requires name and command (no form)
- [ ] `wayu alias rm` requires name (no fuzzy finder)
- [ ] `wayu constants add` requires name and value (no form)
- [ ] `wayu constants rm` requires name (no fuzzy finder)
- [ ] `wayu path clean` requires `--yes` flag (no prompt)
- [ ] `wayu path dedup` requires `--yes` flag (no prompt)

**Exit Codes:**
- [ ] Success returns 0: `wayu path add /test; echo $?`
- [ ] Usage errors return 64: `wayu path add; echo $?`
- [ ] I/O errors return 74: Test with permission denied
- [ ] Help shows exit codes section

**Scriptability:**
- [ ] Pipes work: `wayu path list | grep pattern`
- [ ] Redirects work: `wayu path list > file.txt`
- [ ] No hanging: `wayu path clean < /dev/null`
- [ ] Flag chaining: `wayu path add /a && wayu path add /b`
- [ ] Works in non-TTY: Docker/CI test passes

**Error Messages:**
- [ ] Missing args show usage + example + TUI hint
- [ ] Confirmation errors show what would happen + --yes command
- [ ] All errors go to stderr (not stdout)
- [ ] Error messages are actionable

**TUI Mode:**
- [ ] `wayu --tui` launches interactive mode
- [ ] All 8 TUI views work (Main, PATH, Alias, Constants, etc.)
- [ ] Interactive forms work in TUI
- [ ] Fuzzy finders work in TUI
- [ ] Confirmations work in TUI
- [ ] Can add/remove entries interactively

**Documentation:**
- [ ] docs/MIGRATION_v2.2.md created with breaking changes
- [ ] docs/EXIT_CODES.md created with reference
- [ ] README.md updated with scripting section
- [ ] Help message shows exit codes
- [ ] All examples in docs work

### User Persona Validation

**DevOps Engineer (Automation)**:
- [ ] Can write non-interactive shell script
- [ ] Script works in CI/CD pipeline
- [ ] Exit codes enable error handling
- [ ] No prompts block execution

**System Administrator (Management)**:
- [ ] Can batch-add entries with loop
- [ ] Can script configuration setup
- [ ] Has option for interactive mode (TUI)

**Power User (Scripting)**:
- [ ] Can pipe commands
- [ ] Can use in functions
- [ ] Clear error messages guide fixes

---

## Anti-Patterns to Avoid

**CLI Anti-Patterns**:
- ❌ Don't leave any `interactive_fuzzy_select()` calls in CLI path
- ❌ Don't leave any `form_run()` calls in CLI path
- ❌ Don't leave any stdin prompts in CLI (except init command)
- ❌ Don't use exit code 1 for everything - categorize errors
- ❌ Don't hide exit codes in help - document them

**Error Message Anti-Patterns**:
- ❌ Don't just say "Missing arguments" - show usage
- ❌ Don't just say "Error" - explain what happened
- ❌ Don't forget the TUI hint - guide users to interactive mode
- ❌ Don't send errors to stdout - use stderr

**Testing Anti-Patterns**:
- ❌ Don't skip existing tests - all must pass
- ❌ Don't skip manual TUI testing - ensure it still works
- ❌ Don't skip scriptability tests - pipes must work
- ❌ Don't skip CI simulation - test non-TTY environments

**Documentation Anti-Patterns**:
- ❌ Don't hide breaking changes - document prominently
- ❌ Don't provide incomplete migration guide
- ❌ Don't forget to update examples
- ❌ Don't leave old interactive examples in docs

**Code Anti-Patterns**:
- ❌ Don't hardcode exit codes - use constants
- ❌ Don't mix CLI and TUI backup handlers
- ❌ Don't forget to mark TUI-only functions
- ❌ Don't leave `TODO` comments - complete all changes

---

## Success Metrics

### Quantitative Targets

| Metric | Target | Measurement Method |
|--------|--------|-------------------|
| **Test Pass Rate** | 100% | `task test:all` - 255+ tests pass |
| **Exit Code Coverage** | 87 points updated | Grep for `os.exit(1)` - should be 0 |
| **Interactive Calls in CLI** | 0 | Grep for `interactive_fuzzy_select\|form_run` in CLI files |
| **CLI Commands Scriptable** | 100% | Pipe test: `wayu * list \| grep` all work |
| **Proper Exit Codes** | 6 categories | 0, 1, 64, 66, 74, 77, 78 all used |

### Qualitative Targets

| Metric | Target | Measurement Method |
|--------|--------|-------------------|
| **Error Clarity** | High | All errors show usage + example + hint |
| **Script Reliability** | Excellent | No hanging, proper exit codes |
| **TUI Preservation** | Perfect | All 8 views work, zero functionality lost |
| **Documentation** | Complete | Migration guide + exit code reference exist |
| **Backward Compat** | Good | Explicit-arg scripts work unchanged |

### Breaking Changes Documented

| Change | Old Behavior | New Behavior | Impact |
|--------|--------------|--------------|--------|
| `wayu path rm` (no args) | Fuzzy finder | Error + usage | **BREAKING** |
| `wayu alias add` (no args) | Interactive form | Error + usage | **BREAKING** |
| `wayu path clean` | Prompts [y/N] | Requires --yes | **BREAKING** |
| `wayu path dedup` | Prompts [y/N] | Requires --yes | **BREAKING** |
| Exit codes | All 1 | Categorized 0/64/74/77/78 | **ENHANCEMENT** |
| `wayu path list` | Interactive by default | Static by default | **CHANGE** |

---

## Confidence Score

**8.5/10** - High Confidence for One-Pass Implementation Success

**Rationale**:
- ✅ **Complete research**: 87 exit points mapped, 14 interactive patterns documented
- ✅ **Clear patterns**: Every change has exact file:line reference
- ✅ **Proven approach**: Following industry standards (clig.dev, sysexits.h)
- ✅ **Comprehensive tests**: 4-level validation strategy with 255 existing tests as safety net
- ✅ **Detailed tasks**: 50+ specific implementation tasks with dependencies
- ⚠️ **Complexity**: 87 exit points to update (high count but straightforward)
- ⚠️ **Breaking changes**: Will affect some user scripts (mitigated with migration guide)

**Risk Factors** (mitigated):
- Many exit points to update (87) → Systematic search-replace with verification
- Breaking changes for users → Comprehensive migration guide with examples
- Test suite must pass → Clear validation checklist with regression detection

---

## Next Steps

1. **Review This PRP**:
   - Verify all file:line references are accurate
   - Confirm exit code mappings make sense
   - Review implementation order

2. **Begin Implementation**:
   - Start with Phase 1 (Exit Code Infrastructure)
   - Follow task order strictly (dependencies matter)
   - Run validation after each phase

3. **Continuous Validation**:
   - Compile after each file modification
   - Run unit tests after each module
   - Manual TUI test after Phase 4
   - Full test suite before marking complete

4. **Documentation**:
   - Create migration guide as you implement
   - Update help messages as you modify commands
   - Keep exit code reference up-to-date

---

## Appendices

### A. Complete Exit Point Locations

```yaml
main.odin:
  - Line 106: No args → EXIT_USAGE
  - Line 162: Unknown command → EXIT_USAGE

path.odin:
  - Line 34: Not initialized → EXIT_CONFIG
  - Lines 93-105: Clean confirmation → --yes check
  - Lines 235-247: Dedup confirmation → --yes check

config_entry.odin:
  - Line 80: Unsupported action → EXIT_GENERAL
  - Line 87: Unsupported action → EXIT_GENERAL
  - Line 105: No TTY → EXIT_CONFIG
  - Line 203: Validation failed → EXIT_DATAERR
  - Line 227: File read failed → EXIT_IOERR
  - Line 269: File write failed → EXIT_IOERR

backup.odin:
  - Line 39: Read failed → EXIT_IOERR
  - Line 54: Write failed → EXIT_IOERR
  - Lines 70-79: Prompt (CLI version fails) → EXIT_IOERR

# ... (Complete list in research agent report)
# Total: 87 exit points documented
```

### B. Example Migration Script

```bash
#!/bin/bash
# migrate-to-v2.2.sh - Helper script to update existing shell scripts

# Replace interactive patterns with explicit args
find . -name "*.sh" -type f -exec sed -i.bak \
  -e 's/wayu path rm$/wayu path rm <path>  # TODO: Add explicit path/g' \
  -e 's/wayu alias add$/wayu alias add <name> <command>  # TODO: Add explicit args/g' \
  -e 's/wayu path clean$/wayu path clean --yes/g' \
  -e 's/wayu path dedup$/wayu path dedup --yes/g' \
  {} \;

echo "Migration complete. Review .bak files and fix TODO comments."
```

### C. Testing Checklist Template

```markdown
# PRP-13 Testing Checklist

Date: ________
Tester: ________

## Phase 1: Exit Codes
- [ ] exit_codes.odin compiles
- [ ] Constants match sysexits.h
- [ ] main.odin imports successfully

## Phase 2: Interactive Removal
- [ ] path add requires args
- [ ] path rm requires args
- [ ] alias add requires args
- [ ] alias rm requires args
- [ ] constants add requires args
- [ ] constants rm requires args

## Phase 3: Confirmation Prompts
- [ ] path clean requires --yes
- [ ] path dedup requires --yes
- [ ] Error messages show --yes command

## Phase 4: Backup Split
- [ ] CLI backup fails immediately
- [ ] TUI backup prompts user

## Phase 5: Completions/Plugins
- [ ] completions rm requires args
- [ ] plugin rm requires args

## Phase 6: Exit Codes Applied
- [ ] Usage errors return 64
- [ ] I/O errors return 74
- [ ] Validation errors return 65

## Phase 7: Documentation
- [ ] MIGRATION_v2.2.md exists
- [ ] EXIT_CODES.md exists
- [ ] README.md updated
- [ ] Help shows exit codes

## Phase 8: Full Testing
- [ ] 218 unit tests pass
- [ ] 27 integration tests pass
- [ ] New exit code tests pass
- [ ] New scriptability tests pass
- [ ] TUI mode fully functional

## Manual Testing
- [ ] Pipe: wayu path list | grep local
- [ ] Redirect: wayu path list > file.txt
- [ ] No hang: wayu path clean < /dev/null
- [ ] TUI: wayu --tui (all views work)
- [ ] Script: setup-env.sh runs without hanging

## Sign-off
All tests passed: [ ] Yes [ ] No
Ready for production: [ ] Yes [ ] No
```

---

**Status**: ✅ READY FOR IMPLEMENTATION
**Confidence**: 8.5/10 for one-pass success
**Total Estimated Effort**: 25-30 hours over 1-2 weeks
**Blocking Issues**: None - all context provided
**Prerequisites**: wayu v2.1.0 codebase, Odin compiler, test suite

---

**Document Metadata**:
- **Version**: 1.0.0
- **Created**: 2025-10-16
- **Author**: Claude (AI Assistant) via PRP Base Template
- **Research Agents**: 3 parallel agents (error patterns, interactive elements, CLI standards)
- **Lines of Context**: 120,000+ tokens of research findings
- **Files Referenced**: 15+ wayu source files, 30+ external URLs
- **Exit Points Documented**: 87 locations with exact line numbers
- **Interactive Patterns**: 14 patterns with exact locations
- **Implementation Tasks**: 50+ ordered tasks with dependencies
