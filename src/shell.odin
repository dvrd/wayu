package wayu
import "core:os"
import "core:strings"
import "core:fmt"
import "core:strconv"
import "core:c"
import "core:sys/posix"
// Shell types supported by wayu
ShellType :: enum {
    BASH,
    ZSH,
    FISH,
    UNKNOWN,
}

// Detect the user's current shell from environment variables.
// Zero-allocation: uses case-insensitive contains instead of to_lower.
detect_shell :: proc() -> ShellType {
    shell_env := os.get_env("SHELL", context.temp_allocator)
    if len(shell_env) == 0 {
        shell_env = os.get_env("0", context.temp_allocator)
        if len(shell_env) == 0 {
            return .UNKNOWN
        }
    }

    // Check suffix after last '/' for common paths like /bin/zsh, /usr/bin/bash
    name := shell_env
    if last_slash := strings.last_index_byte(shell_env, '/'); last_slash >= 0 {
        name = shell_env[last_slash + 1:]
    }
    if strings.equal_fold(name, "zsh")  { return .ZSH  }
    if strings.equal_fold(name, "bash") { return .BASH }
    if strings.equal_fold(name, "fish") { return .FISH }

    // Fallback: scan full path for substring
    if strings.contains(shell_env, "zsh")  { return .ZSH  }
    if strings.contains(shell_env, "bash") { return .BASH }
    if strings.contains(shell_env, "fish") { return .FISH }

    return .UNKNOWN
}

// Get shell-specific file extension for config files
get_shell_extension :: proc(shell: ShellType) -> string {
    switch shell {
    case .BASH:
        return "bash"
    case .ZSH:
        return "zsh"
    case .FISH:
        return "fish"
    case .UNKNOWN:
        return "sh" // Fallback to POSIX shell
    }
    return "sh"
}

// Get shell-specific RC file path for initialization
get_rc_file_path :: proc(shell: ShellType) -> string {
    home := os.get_env("HOME", context.temp_allocator)

    switch shell {
    case .BASH:
        // Check for .bash_profile first (macOS), then .bashrc (Linux)
        bash_profile := fmt.aprintf("%s/.bash_profile", home)
        if os.exists(bash_profile) {
            return bash_profile
        }
        return fmt.aprintf("%s/.bashrc", home)
    case .ZSH:
        // zsh reads its rc files from $ZDOTDIR when set.
        return fmt.aprintf("%s/.zshrc", zsh_dotdir(home))
    case .FISH:
        return fmt.aprintf("%s/.config/fish/config.fish", home)
    case .UNKNOWN:
        return fmt.aprintf("%s/.profile", home)
    }
    return ""
}

// $ZDOTDIR when set and non-empty, else `home`. Temp-allocated.
zsh_dotdir :: proc(home: string) -> string {
    zdot := os.get_env("ZDOTDIR", context.temp_allocator)
    return len(zdot) > 0 ? zdot : home
}

// Every startup file `shell` may read (login and interactive), in load
// order, whether or not it exists. `wayu init` writes to get_rc_file_path;
// doctor accepts a wayu source line in any of these. Fish also reads every
// conf.d/*.fish snippet, which is listed when the directory exists.
shell_startup_files :: proc(shell: ShellType, allocator := context.allocator) -> []string {
    context.allocator = allocator
    home := os.get_env("HOME", context.temp_allocator)
    files := make([dynamic]string)

    switch shell {
    case .ZSH:
        zdot := zsh_dotdir(home)
        // ~/.zshenv is read before ZDOTDIR is known (it often sets it).
        if zdot != home {
            append(&files, fmt.aprintf("%s/.zshenv", home))
        }
        for name in ([]string{".zshenv", ".zprofile", ".zshrc", ".zlogin"}) {
            append(&files, fmt.aprintf("%s/%s", zdot, name))
        }
    case .BASH:
        for name in ([]string{".bash_profile", ".bash_login", ".profile", ".bashrc"}) {
            append(&files, fmt.aprintf("%s/%s", home, name))
        }
    case .FISH:
        fish_dir := fmt.aprintf("%s/.config/fish", home)
        append(&files, fmt.aprintf("%s/config.fish", fish_dir))
        conf_d := fmt.aprintf("%s/conf.d", fish_dir)
        if handle, err := os.open(conf_d); err == nil {
            defer os.close(handle)
            if infos, read_err := os.read_dir(handle, -1, context.temp_allocator); read_err == nil {
                for info in infos {
                    if info.type != .Directory && strings.has_suffix(info.name, ".fish") {
                        append(&files, fmt.aprintf("%s/%s", conf_d, info.name))
                    }
                }
            }
        }
    case .UNKNOWN:
        append(&files, fmt.aprintf("%s/.profile", home))
    }
    return files[:]
}

// Get shell-specific shebang for config files
get_shebang :: proc(shell: ShellType) -> string {
    switch shell {
    case .BASH:
        return "#!/usr/bin/env bash"
    case .ZSH:
        return "#!/usr/bin/env zsh"
    case .FISH:
        return "#!/usr/bin/env fish"
    case .UNKNOWN:
        return "#!/bin/sh"
    }
    return "#!/bin/sh"
}

// Get shell name as string for display purposes
get_shell_name :: proc(shell: ShellType) -> string {
    switch shell {
    case .BASH:
        return "Bash"
    case .ZSH:
        return "ZSH"
    case .FISH:
        return "Fish"
    case .UNKNOWN:
        return "Unknown"
    }
    return "Unknown"
}

// Value stored in wayu.toml `[shell] type` (lowercase, as parse_shell_type
// and toml_validate expect). UNKNOWN maps to zsh, the default wayu falls
// back to everywhere else.
shell_config_name :: proc(shell: ShellType) -> string {
    switch shell {
    case .BASH:            return "bash"
    case .FISH:            return "fish"
    case .ZSH, .UNKNOWN:   return "zsh"
    }
    return "zsh"
}

// Parse shell type from string (for CLI flags)
parse_shell_type :: proc(shell_str: string) -> ShellType {
    shell_lower := strings.to_lower(shell_str)
    defer delete(shell_lower)

    if shell_lower == "bash" {
        return .BASH
    } else if shell_lower == "zsh" {
        return .ZSH
    } else if shell_lower == "fish" {
        return .FISH
    }
    return .UNKNOWN
}

// Validate shell compatibility
validate_shell_compatibility :: proc(shell: ShellType) -> (valid: bool, message: string) {
    switch shell {
    case .BASH, .ZSH, .FISH:
        return true, ""
    case .UNKNOWN:
        return false, "Unable to detect shell type. Please specify --shell bash, --shell zsh, or --shell fish"
    }
    return false, "Unsupported shell type"
}

// Width CLI tables are fitted to (table_render's max_width).
// Tries: exported COLUMNS → 0 (no limit) when stdout is not a terminal, so
// `wayu path list | cat` keeps whole values → ioctl size → 80.
get_cli_terminal_width :: proc() -> int {
    // Method 1: COLUMNS env var (an explicit export wins)
    cols_env := os.get_env("COLUMNS", context.temp_allocator)
    if len(cols_env) > 0 {
        cols, ok := strconv.parse_int(cols_env)
        if ok && cols > 0 {
            return cols
        }
    }

    // Piped / redirected: never truncate values with '…'.
    if !is_stdout_tty() { return 0 }

    // Method 2: ioctl TIOCGWINSZ (direct syscall, no subprocess)
    ws: winsize
    // Try stdout (fd 1), then stderr (fd 2), then stdin (fd 0)
    for fd in ([3]c.int{1, 2, 0}) {
        if ioctl(fd, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 {
            return int(ws.ws_col)
        }
    }

    return 80
}

// ============================================================================
// Utility Functions
// ============================================================================

// Escape a string as a fully literal Fish word.
//
// Inside fish single quotes only `\\` and `\'` are escape sequences, so both
// backslash and single quote must be escaped; everything else (including `$`
// and `*`) is literal. Works byte-wise, so UTF-8 passes through untouched.
escape_fish_string :: proc(s: string, allocator := context.allocator) -> string {
    sb := strings.builder_make(allocator)
    strings.write_byte(&sb, '\'')
    for i in 0..<len(s) {
        c := s[i]
        if c == '\\' || c == '\'' {
            strings.write_byte(&sb, '\\')
        }
        strings.write_byte(&sb, c)
    }
    strings.write_byte(&sb, '\'')
    return strings.to_string(sb)
}

// ============================================================================
// Shell quoting helpers (shared by every generator that emits shell code)
// ============================================================================
//
// Policy for values written into generated scripts:
//
//   aliases       → single-quoted (shell_single_quote). The alias body is
//                   stored verbatim and `$VAR` expands when the alias *runs*,
//                   which is what users expect from `alias x='cd $HOME/y'`.
//   env values    → double-quoted (shell_double_quote_env). `$VAR` and
//                   `${VAR}` keep expanding at source time (GOPATH="$HOME/go"),
//                   but `"`, `\` and backtick are escaped, and command
//                   substitution `$(...)` / `$((...))` is neutralised to a
//                   literal `$(`. Rationale: values come from data files and
//                   are re-evaluated on every shell start; parameter expansion
//                   is the documented feature, executing arbitrary commands
//                   is not. Backticks and `$(` are treated the same way so the
//                   rule is simple: variables expand, commands never run.
//   literal paths → double-quoted with `$` escaped too
//                   (shell_double_quote_literal) — used for already-expanded
//                   absolute paths.
//
// All helpers operate byte-wise so non-ASCII (UTF-8) content is preserved.

// Wrap `s` in single quotes for zsh/bash, encoding embedded `'` as `'\''`.
shell_single_quote :: proc(s: string, allocator := context.allocator) -> string {
    sb := strings.builder_make(allocator)
    strings.write_byte(&sb, '\'')
    for i in 0..<len(s) {
        c := s[i]
        if c == '\'' {
            strings.write_string(&sb, `'\''`)
        } else {
            strings.write_byte(&sb, c)
        }
    }
    strings.write_byte(&sb, '\'')
    return strings.to_string(sb)
}

// Double-quote an env value for zsh/bash keeping `$VAR` / `${VAR}` expansion.
// See the policy comment above for what gets escaped and why.
//
// Only references to named variables expand: `$NAME` (emitted as `${NAME}`
// so zsh never reads a following `:x` / `[i]` as a modifier / subscript) and
// `${NAME...}` / `${#NAME}` with a matching `}` (its body is escaped the same
// way, so `${X:-$(cmd)}` stays inert). Every other `$` is literal: `$(`,
// `$1`, `$$`, a trailing `$`, an unclosed `${` (a syntax error that used to
// break the whole generated file) and zsh flags such as `${(e)...}` (which
// would evaluate its text, running commands).
shell_double_quote_env :: proc(s: string, allocator := context.allocator) -> string {
    sb := strings.builder_make(allocator)
    strings.write_byte(&sb, '"')
    write_env_dq_body(&sb, s)
    strings.write_byte(&sb, '"')
    return strings.to_string(sb)
}

@(private = "file")
write_env_dq_body :: proc(sb: ^strings.Builder, s: string) {
    i := 0
    for i < len(s) {
        c := s[i]
        switch c {
        case '"', '\\', '`':
            strings.write_byte(sb, '\\')
            strings.write_byte(sb, c)
            i += 1
            continue
        case '$':
            if n := var_name_prefix_len(s[i+1:]); n > 0 {
                strings.write_string(sb, "${")
                strings.write_string(sb, s[i+1:i+1+n])
                strings.write_byte(sb, '}')
                i += 1 + n
                continue
            }
            if i + 1 < len(s) && s[i+1] == '{' {
                inner := s[i+2:]
                lead := 1 if len(inner) > 0 && inner[0] == '#' else 0
                n := var_name_prefix_len(inner[lead:])
                close := matching_brace(inner)
                if n > 0 && close >= lead + n && env_brace_op_is_safe(inner[lead+n:close], lead == 1) {
                    strings.write_string(sb, "${")
                    strings.write_string(sb, inner[:lead+n])
                    write_env_dq_body(sb, inner[lead+n:close])
                    strings.write_byte(sb, '}')
                    i += 2 + close + 1
                    continue
                }
            }
            strings.write_string(sb, `\$`)
            i += 1
            continue
        }
        strings.write_byte(sb, c)
        i += 1
    }
}

// The text after NAME inside `${NAME...}` may expand only when it starts
// with an operator that is valid in both zsh and bash and never evaluates
// text: default/assign/alternate/error (`-` `=` `+` `?`, with or without a
// leading `:`), prefix/suffix removal (`#` `%`) and substitution (`/`).
// Everything else stays literal: bash `${X@P}` (4.4+) prompt-expands X's
// value and runs a `$(...)` stored in it; `${X[Y]}` and `${X:Y}` evaluate Y
// arithmetically, which runs `$(...)` hidden in Y's value (bash), and
// `${X:Y}` / `${X^}` abort sourcing in zsh (unknown modifier / bad
// substitution). `${#NAME}` takes no operator.
env_brace_op_is_safe :: proc(body: string, is_length: bool) -> bool {
    if len(body) == 0 { return true }
    if is_length { return false }
    op := body[0]
    if op == ':' {
        if len(body) < 2 { return false }
        op = body[1]
        return op == '-' || op == '=' || op == '+' || op == '?'
    }
    switch op {
    case '-', '=', '+', '?', '#', '%', '/':
        return true
    }
    return false
}

// Length of the variable name ([A-Za-z_][A-Za-z0-9_]*) at the start of s, or 0.
var_name_prefix_len :: proc(s: string) -> int {
    n := 0
    for n < len(s) {
        c := s[n]
        alpha := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
        digit := c >= '0' && c <= '9'
        if !alpha && !(digit && n > 0) { break }
        n += 1
    }
    return n
}

// Index in s (the text after a `${`) of the `}` closing it, counting nested
// `${`; a backslash skips the next byte. -1 when unbalanced.
@(private = "file")
matching_brace :: proc(s: string) -> int {
    depth := 0
    for j := 0; j < len(s); j += 1 {
        switch s[j] {
        case '\\':
            j += 1
        case '$':
            if j + 1 < len(s) && s[j+1] == '{' {
                depth += 1
                j += 1
            }
        case '}':
            if depth == 0 { return j }
            depth -= 1
        }
    }
    return -1
}

// Double-quote a fully literal value for zsh/bash (no expansion of any kind).
shell_double_quote_literal :: proc(s: string, allocator := context.allocator) -> string {
    sb := strings.builder_make(allocator)
    strings.write_byte(&sb, '"')
    for i in 0..<len(s) {
        c := s[i]
        switch c {
        case '"', '\\', '`', '$':
            strings.write_byte(&sb, '\\')
        }
        strings.write_byte(&sb, c)
    }
    strings.write_byte(&sb, '"')
    return strings.to_string(sb)
}

// Double-quote an env value for fish keeping `$VAR` expansion. Inside fish
// double quotes only `\"`, `\$`, `\\` are escapes. `$NAME` and `${NAME}`
// expand (as `$NAME`, followed by `""` when a name character, a non-ASCII
// byte or `[` comes next, so fish doesn't read a longer name or an index).
// Every other `$` is literal: fish rejects `${`, `$$`, `$1`, a trailing `$`
// … at parse time, which used to make the whole core.fish fail to load, and
// `$(` is command substitution since fish 3.4. `${NAME:-x}` has no fish
// equivalent: literal.
fish_double_quote_env :: proc(s: string, allocator := context.allocator) -> string {
    sb := strings.builder_make(allocator)
    strings.write_byte(&sb, '"')
    i := 0
    for i < len(s) {
        c := s[i]
        switch c {
        case '"', '\\':
            strings.write_byte(&sb, '\\')
        case '$':
            // `$NAME` or `${NAME}`: name = s[start:start+n], next byte at `end`.
            start := i + 1
            braced := start < len(s) && s[start] == '{'
            if braced { start += 1 }
            n := var_name_prefix_len(s[start:])
            end := start + n
            if braced {
                if end < len(s) && s[end] == '}' { end += 1 } else { n = 0 }
            }
            if n == 0 {
                strings.write_string(&sb, `\$`)
                i += 1
                continue
            }
            strings.write_byte(&sb, '$')
            strings.write_string(&sb, s[start:start+n])
            // fish names also take non-ASCII letters (`$Xé` reads `Xé`).
            if end < len(s) && (var_name_prefix_len(s[end:end+1]) > 0 || (s[end] >= '0' && s[end] <= '9') || s[end] == '[' || s[end] >= 0x80) {
                strings.write_string(&sb, `""`)
            }
            i = end
            continue
        }
        strings.write_byte(&sb, c)
        i += 1
    }
    strings.write_byte(&sb, '"')
    return strings.to_string(sb)
}

// Rewrite a leading `~` / `~/` into `$HOME` so env values like
// LEDGER_FILE = "~/x" expand (tilde is not expanded inside quotes).
// Returns a new string the caller owns.
expand_leading_tilde_to_home_var :: proc(s: string, allocator := context.allocator) -> string {
    if s == "~" {
        return strings.clone("$HOME", allocator)
    }
    if strings.has_prefix(s, "~/") {
        return strings.concatenate({"$HOME", s[1:]}, allocator)
    }
    return strings.clone(s, allocator)
}

// True when `s` is a portable shell variable name ([A-Za-z_][A-Za-z0-9_]*).
is_shell_var_name :: proc(s: string) -> bool {
    if len(s) == 0 { return false }
    for i in 0..<len(s) {
        c := s[i]
        alpha := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
        digit := c >= '0' && c <= '9'
        if !alpha && !(digit && i > 0) { return false }
    }
    return true
}

// True when `s` can be used verbatim as an alias name in zsh/bash/fish
// without quoting (rejects whitespace, quotes, `=`, and shell metachars).
is_safe_alias_name :: proc(s: string) -> bool {
    if len(s) == 0 { return false }
    for i in 0..<len(s) {
        c := s[i]
        switch c {
        case ' ', '\t', '\n', '\r', '\'', '"', '`', '$', '=', ';', '&', '|',
             '<', '>', '(', ')', '{', '}', '\\', '*', '?', '[', ']', '#', '~', '!':
            return false
        }
        if c < 0x20 { return false }
    }
    return true
}

// Check if a command exists in PATH
command_exists :: proc(cmd: string) -> bool {
    output := capture_command([]string{"which", cmd})
    defer if len(output) > 0 do delete(output)
    return len(output) > 0 && !strings.contains(output, "not found")
}

// ============================================================================
// Fish Config File Operations
// ============================================================================

// Shell of the parent process. `build eval` output is eval'd by its parent
// (the command-substitution subshell), so this is the shell that will run the
// generated code — unlike $SHELL, which sudo resets to root's /bin/sh and a
// bash started from zsh leaves as zsh. UNKNOWN when it can't be determined
// or the parent isn't zsh/bash/fish (e.g. bash invoked as `sh`).
detect_parent_shell :: proc() -> ShellType {
    name := parent_process_name()
    name = strings.trim_prefix(name, "-") // login shells report "-zsh"
    if slash := strings.last_index_byte(name, '/'); slash >= 0 { name = name[slash + 1:] }
    switch name {
    case "zsh":  return .ZSH
    case "bash": return .BASH
    case "fish": return .FISH
    }
    return .UNKNOWN
}

when ODIN_OS == .Darwin {
    foreign import libsys "system:c"
    foreign libsys {
        proc_name :: proc(pid: c.int, buffer: rawptr, buffersize: u32) -> c.int ---
    }
}

// Executable name of the parent process (temp-allocated), or "".
parent_process_name :: proc() -> string {
    ppid := posix.getppid()
    when ODIN_OS == .Darwin {
        buf := make([]u8, 256, context.temp_allocator)
        n := proc_name(c.int(ppid), raw_data(buf), u32(len(buf)))
        if n <= 0 { return "" }
        return string(buf[:n])
    } else when ODIN_OS == .Linux {
        data, err := os.read_entire_file(fmt.tprintf("/proc/%d/comm", ppid), context.temp_allocator)
        if err != nil { return "" }
        return strings.trim_space(string(data))
    } else {
        return ""
    }
}

// True when running as root on a config dir owned by another user (e.g. a
// `sudo zsh` that still sources the user's .zshenv). Writing there would leave
// root-owned generated files in the user's config.
running_as_root_on_user_config :: proc(dir: string) -> bool {
    if posix.geteuid() != 0 { return false }
    st: posix.stat_t
    cdir := strings.clone_to_cstring(dir, context.temp_allocator)
    if posix.stat(cdir, &st) != .OK { return false }
    return st.st_uid != 0
}

// Set by `--shell`: an explicit choice that auto-detection must not override.
shell_flag_given := false

// Switch the active shell.
set_active_shell :: proc(s: ShellType) {
    wayu.shell = s
    wayu.shell_ext = get_shell_extension(s)
}
