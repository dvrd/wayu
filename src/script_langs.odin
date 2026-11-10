// script_langs.odin - The language table behind `wayu script`
//
// One row per language a managed script may be written in. Everything
// language-specific lives here: the source extension, the interpreters
// looked up on PATH for the shebang of a new script, the shebang names that
// identify the language on import, the skeleton `script new` writes, and the
// optional compile step (swift). script.odin never switches on a language.

package wayu

import "core:strings"

// A compile step: `<compiler> <args...> -o <out> <src>` (no shell).
ScriptCompile :: struct {
	compiler: string, // looked up on PATH at build time
	args:     []string, // before `-o <out> <src>`
}

ScriptLang :: struct {
	name:          string, // `--lang` value and `[scripts] default_lang`
	ext:           string, // source extension, no dot
	interpreters:  []string, // shebang of `script new`: first found on PATH
	// Interpreter basenames (trailing version digits/dots stripped, see
	// script_interpreter_key) that identify this language in a shebang.
	shebang_names: []string,
	comment:       string, // line comment prefix for the skeleton header
	skeleton:      string, // body after the header; "%NAME%" is replaced
	compile:       Maybe(ScriptCompile),
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
		compile = ScriptCompile{compiler = "swiftc", args = {"-O"}},
	},
	{
		name = "python",
		ext = "py",
		interpreters = {"python3", "python"},
		shebang_names = {"python", "pypy"},
		comment = "#",
		skeleton = "import sys\n\n\ndef run() -> int:\n    print(\"%NAME%\")\n    return 0\n\n\nif __name__ == \"__main__\":\n    sys.exit(run())\n",
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

// The interpreter a shebang line runs: `#!/usr/bin/python3 -u` →
// "/usr/bin/python3"; `#!/usr/bin/env -S deno run` → "deno" (env's own
// options and NAME=value assignments skipped). "" when `line` is not a
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
	for w in words[1:] {
		if strings.has_prefix(w, "-") {
			continue
		}
		if strings.contains_rune(w, '=') {
			continue
		}
		return w
	}
	return ""
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
