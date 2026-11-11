// script_langs.odin - The language table behind `wayu script`
//
// One row per language a managed script may be written in. Everything
// language-specific lives here: the source extension, the interpreters
// looked up on PATH for the shebang of a new script, the shebang names that
// identify the language on import, the skeleton `script new` writes, and the
// optional build preset (swift). script.odin never switches on a language.
//
// Build commands (OKAMI-369): any source may declare its own in a header
// comment, scriptisto-style, in its first SCRIPT_BUILD_HEADER_LINES lines:
//   // wayu: build = cc -O2 -o {out} {src}
//   #  wayu: build = go build -o {out} {src}
// `{src}` is the source, `{out}` the file the command must write (it then
// becomes bin/NAME). The words are split like a shell would (quotes, no
// expansions) and run without a shell. A language's `build` (swift) is the
// same mechanism, used when the source declares none.

package wayu

import "core:strings"

// First lines of a source searched for a `wayu: build = ...` header.
SCRIPT_BUILD_HEADER_LINES :: 20

ScriptLang :: struct {
	name:          string, // `--lang` value and `[scripts] default_lang`
	ext:           string, // source extension, no dot
	interpreters:  []string, // shebang of `script new`: first found on PATH
	// Interpreter basenames (trailing version digits/dots stripped, see
	// script_interpreter_key) that identify this language in a shebang.
	shebang_names: []string,
	comment:       string, // line comment prefix for the skeleton header
	skeleton:      string, // body after the header; "%NAME%" is replaced
	// Build preset: a build command template (see the top of the file); ""
	// for an interpreted language (bin/NAME links to the source).
	build:         string,
	// Other extensions recognised on import (kept as the source extension).
	extra_exts:    []string,
}

SCRIPT_DEFAULT_LANG :: "swift"

SCRIPT_LANGS := [?]ScriptLang {
	{
		name = "swift",
		ext = "swift",
		interpreters = {"swift"},
		shebang_names = {"swift"},
		comment = "//",
		skeleton = "print(\"%NAME%\")\n",
		build = "swiftc -O -o {out} {src}",
	},
	{
		name          = "python",
		ext           = "py",
		interpreters  = {"python3", "python"},
		// uv: `#!/usr/bin/env -S uv run --script` (PEP 723 inline deps).
		shebang_names = {"python", "pypy", "uv"},
		comment       = "#",
		skeleton      = "import sys\n\n\ndef run() -> int:\n    print(\"%NAME%\")\n    return 0\n\n\nif __name__ == \"__main__\":\n    sys.exit(run())\n",
	},
	{
		name = "ruby",
		ext = "rb",
		interpreters = {"ruby"},
		shebang_names = {"ruby"},
		comment = "#",
		skeleton = "puts \"%NAME%\"\n",
	},
	{
		name = "node",
		ext = "js",
		interpreters = {"node", "nodejs"},
		shebang_names = {"node", "nodejs"},
		comment = "//",
		skeleton = "console.log(\"%NAME%\");\n",
		extra_exts = {"mjs", "cjs"},
	},
	{
		name = "bun",
		ext = "ts",
		interpreters = {"bun"},
		shebang_names = {"bun"},
		comment = "//",
		skeleton = "console.log(\"%NAME%\");\n",
		extra_exts = {"tsx"},
	},
	{
		name = "bash",
		ext = "bash",
		interpreters = {"bash"},
		shebang_names = {"bash"},
		comment = "#",
		skeleton = "set -euo pipefail\n\necho \"%NAME%\"\n",
	},
	{
		name = "zsh",
		ext = "zsh",
		interpreters = {"zsh"},
		shebang_names = {"zsh"},
		comment = "#",
		skeleton = "emulate -L zsh\nsetopt err_exit no_unset pipe_fail\n\necho \"%NAME%\"\n",
	},
	{
		name = "fish",
		ext = "fish",
		interpreters = {"fish"},
		shebang_names = {"fish"},
		comment = "#",
		skeleton = "echo \"%NAME%\"\n",
	},
	{
		name = "perl",
		ext = "pl",
		interpreters = {"perl"},
		shebang_names = {"perl"},
		comment = "#",
		skeleton = "use strict;\nuse warnings;\n\nprint \"%NAME%\\n\";\n",
	},
	{
		name = "lua",
		ext = "lua",
		interpreters = {"lua", "luajit"},
		shebang_names = {"lua", "luajit"},
		comment = "--",
		skeleton = "print(\"%NAME%\")\n",
	},
	{
		name = "sh",
		ext = "sh",
		interpreters = {"sh"},
		shebang_names = {"sh", "dash"},
		comment = "#",
		skeleton = "set -eu\n\necho \"%NAME%\"\n",
	},
}

// Row for a language name, nil when unknown.
script_lang_by_name :: proc(name: string) -> ^ScriptLang {
	for &l in SCRIPT_LANGS {
		if l.name == name {
			return &l
		}
	}
	return nil
}

// Row whose source extension (or extra extension) is `ext` (no dot).
script_lang_by_ext :: proc(ext: string) -> ^ScriptLang {
	for &l in SCRIPT_LANGS {
		if l.ext == ext {
			return &l
		}
		for e in l.extra_exts {
			if e == ext {
				return &l
			}
		}
	}
	return nil
}

// "swift, python, ..." for messages. Temp-allocated.
script_lang_names :: proc() -> string {
	names := make([dynamic]string, context.temp_allocator)
	for l in SCRIPT_LANGS {append(&names, l.name)}
	return strings.join(names[:], ", ", context.temp_allocator)
}

// Interpreter basename without a trailing version: python3.12 → python,
// lua5.4 → lua, perl5.30 → perl.
script_interpreter_key :: proc(base: string) -> string {
	end := len(base)
	for end > 0 &&
	    ((base[end - 1] >= '0' && base[end - 1] <= '9') || base[end - 1] == '.') {end -= 1}
	if end == 0 {
		return base
	}
	return base[:end]
}

// Row for an interpreter basename from a shebang, nil when unknown.
script_lang_by_interpreter :: proc(base: string) -> ^ScriptLang {
	key := script_interpreter_key(base)
	for &l in SCRIPT_LANGS {
		for n in l.shebang_names {
			if n == key || n == base {
				return &l
			}
		}
	}
	return nil
}

// env options whose value is the next word (GNU and BSD env): `-u VAR`,
// `-P dir`, `-C dir`, `--unset VAR`, `--chdir dir`. `-S` / `--split-string`
// are not here: their value is the command line itself.
@(private = "file")
ENV_OPTS_WITH_ARG :: []string{"-u", "-P", "-C", "--unset", "--chdir"}

// The interpreter a shebang line runs: `#!/usr/bin/python3 -u` →
// "/usr/bin/python3"; `#!/usr/bin/env -S deno run` → "deno" (env's own
// options, their arguments — `-u VAR`, `-P dir`, `-C dir`, `--unset=VAR` —
// and NAME=value assignments skipped, OKAMI-340). "" when `line` is not a
// shebang or names nothing.
script_shebang_interpreter :: proc(line: string) -> string {
	if !strings.has_prefix(line, "#!") {
		return ""
	}
	rest := strings.trim_space(strings.trim_right(line[2:], "\r"))
	words := strings.fields(rest, context.temp_allocator)
	if len(words) == 0 {
		return ""
	}
	first := words[0]
	base := first[strings.last_index_byte(first, '/') + 1:]
	if base != "env" {
		return first
	}
	options := true
	for i := 1; i < len(words); i += 1 {
		w := words[i]
		if options && w == "--" {
			options = false
			continue
		}
		if options && strings.has_prefix(w, "-") {
			for o in ENV_OPTS_WITH_ARG {
				if w == o {
					i += 1 // skip the option's argument
					break
				}
			}
			continue
		}
		if strings.contains_rune(w, '=') {
			continue
		}
		return w
	}
	return ""
}

// True when the shebang line of `content` ends in a carriage return
// (CRLF line endings): the kernel would run "<interpreter>\r" (`bad
// interpreter`), OKAMI-338.
script_shebang_has_cr :: proc(content: string) -> bool {
	if !strings.has_prefix(content, "#!") {
		return false
	}
	nl := strings.index_byte(content, '\n')
	line := content if nl < 0 else content[:nl]
	return strings.has_suffix(line, "\r")
}

// The build command a source declares in a header comment (see the top of
// the file): the text after `wayu: build =` on a comment line (`//`, `#`,
// `--`, `;`, `/*`, `*`) among the first SCRIPT_BUILD_HEADER_LINES lines,
// trimmed (a trailing `*/` dropped). "" when there is none.
script_build_header :: proc(content: string) -> string {
	rest := content
	for _ in 0 ..< SCRIPT_BUILD_HEADER_LINES {
		if len(rest) == 0 {
			break
		}
		nl := strings.index_byte(rest, '\n')
		line := rest if nl < 0 else rest[:nl]
		rest = "" if nl < 0 else rest[nl + 1:]
		l := strings.trim_space(line)
		if strings.has_prefix(l, "#!") {
			continue
		}
		body := strings.trim_left(l, "/#-;* \t")
		if len(body) == len(l) {
			continue // not a comment line
		}
		if !strings.has_prefix(body, "wayu:") {
			continue
		}
		body = strings.trim_left(body[len("wayu:"):], " \t")
		if !strings.has_prefix(body, "build") {
			continue
		}
		body = strings.trim_left(body[len("build"):], " \t")
		if !strings.has_prefix(body, "=") {
			continue
		}
		cmd := strings.trim_space(body[1:])
		cmd = strings.trim_space(strings.trim_suffix(cmd, "*/"))
		return cmd
	}
	return ""
}

// Words of a build command: split on blanks, with '...' and "..." quoting
// (backslash escapes `"`/`\` inside double quotes and any byte outside
// quotes); no expansions. ok=false on an unterminated quote. Temp-allocated.
script_split_command :: proc(cmd: string) -> (words: [dynamic]string, ok: bool) {
	words = make([dynamic]string, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	in_word := false
	i := 0
	for i < len(cmd) {
		c := cmd[i]
		switch {
		case c == ' ' || c == '\t':
			if in_word {
				append(&words, strings.clone(strings.to_string(b), context.temp_allocator))
				strings.builder_reset(&b)
				in_word = false
			}
			i += 1
		case c == '\'':
			end := strings.index_byte(cmd[i + 1:], '\'')
			if end < 0 {
				return words, false
			}
			strings.write_string(&b, cmd[i + 1:i + 1 + end])
			in_word = true
			i += end + 2
		case c == '"':
			i += 1
			closed := false
			for i < len(cmd) {
				d := cmd[i]
				if d == '"' {
					closed = true
					i += 1
					break
				}
				if d == '\\' && i + 1 < len(cmd) && (cmd[i + 1] == '"' || cmd[i + 1] == '\\') {
					d = cmd[i + 1]
					i += 1
				}
				strings.write_byte(&b, d)
				i += 1
			}
			if !closed {
				return words, false
			}
			in_word = true
		case c == '\\' && i + 1 < len(cmd):
			strings.write_byte(&b, cmd[i + 1])
			in_word = true
			i += 2
		case:
			strings.write_byte(&b, c)
			in_word = true
			i += 1
		}
	}
	if in_word {
		append(&words, strings.clone(strings.to_string(b), context.temp_allocator))
	}
	return words, true
}

// argv of build command `cmd` for source `src` writing `out` ({src} and
// {out} replaced in every word). Returns the reason (temp) when the command
// is unusable: empty, an unterminated quote, or no {out}.
script_build_argv :: proc(cmd, src, out: string) -> (argv: []string, problem: string) {
	words, ok := script_split_command(cmd)
	if !ok {
		return nil, "unterminated quote"
	}
	if len(words) == 0 {
		return nil, "empty command"
	}
	has_out := false
	for &w in words {
		if strings.contains(w, "{out}") {
			has_out = true
		}
		w, _ = strings.replace_all(w, "{src}", src, context.temp_allocator)
		w, _ = strings.replace_all(w, "{out}", out, context.temp_allocator)
	}
	if !has_out {
		return nil, "no {out} (the file the command must write)"
	}
	return words[:], ""
}

// Basename of a path.
script_basename :: proc(path: string) -> string {
	return path[strings.last_index_byte(path, '/') + 1:]
}

// Header comment + skeleton body for `script new NAME` (no shebang).
// Caller deletes.
script_skeleton :: proc(
	lang: ^ScriptLang,
	name: string,
	allocator := context.allocator,
) -> string {
	body, _ := strings.replace_all(lang.skeleton, "%NAME%", name, context.temp_allocator)
	return strings.concatenate(
		{
			lang.comment,
			" ",
			name,
			" - script managed by wayu (edit: wayu script edit ",
			name,
			")\n\n",
			body,
		},
		allocator,
	)
}
