// test_script.odin - `wayu script`: language table, shebangs, import
// classification, build + staleness.

package test_wayu

import wayu "../../src"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_script_lang_table :: proc(t: ^testing.T) {
	names := make(map[string]bool, context.temp_allocator)
	exts := make(map[string]bool, context.temp_allocator)
	for l in wayu.SCRIPT_LANGS {
		testing.expectf(t, l.name not_in names, "duplicate language %s", l.name)
		testing.expectf(t, l.ext not_in exts, "duplicate extension %s", l.ext)
		names[l.name] = true
		exts[l.ext] = true
		testing.expectf(t, len(l.interpreters) > 0, "%s has no interpreter", l.name)
		testing.expectf(t, len(l.shebang_names) > 0, "%s has no shebang names", l.name)
		testing.expectf(
			t,
			strings.contains(l.skeleton, "%NAME%"),
			"%s skeleton lacks %%NAME%%",
			l.name,
		)
		testing.expect(t, wayu.script_lang_by_name(l.name) != nil)
		testing.expect(t, wayu.script_lang_by_ext(l.ext) == wayu.script_lang_by_name(l.name))
	}
	for want in ([]string {
			"swift",
			"python",
			"ruby",
			"node",
			"bun",
			"bash",
			"zsh",
			"fish",
			"perl",
			"lua",
			"sh",
		}) {
		testing.expectf(t, want in names, "language %s missing", want)
	}
	testing.expect(t, wayu.script_lang_by_name(wayu.SCRIPT_DEFAULT_LANG) != nil)
	swift := wayu.script_lang_by_name("swift")
	testing.expect_value(t, swift.build, "swiftc -O -o {out} {src}")
	testing.expect(t, wayu.script_lang_by_name("cobol") == nil)
	testing.expect_value(t, wayu.script_lang_by_ext("ts").name, "bun")
}

@(test)
test_script_shebang_detection :: proc(t: ^testing.T) {
	Case :: struct {
		line, interp, lang: string,
	}
	cases := []Case {
		{"#!/usr/bin/swift", "/usr/bin/swift", "swift"},
		{"#!/opt/homebrew/bin/python3 -u", "/opt/homebrew/bin/python3", "python"},
		{"#!/usr/bin/env python3.12", "python3.12", "python"},
		{"#!/usr/bin/env -S bun run", "bun", "bun"},
		{"#!/usr/bin/env FOO=1 node", "node", "node"},
		{"#! /bin/bash", "/bin/bash", "bash"},
		{"#!/usr/bin/env zsh", "zsh", "zsh"},
		{"#!/usr/bin/ruby", "/usr/bin/ruby", "ruby"},
		{"#!/Users/u/.bun/bin/bun", "/Users/u/.bun/bin/bun", "bun"},
		{"#!/usr/bin/perl5.30", "/usr/bin/perl5.30", "perl"},
		{"#!/bin/dash", "/bin/dash", "sh"},
		{"#!/usr/bin/awk -f", "/usr/bin/awk", ""},
		{"echo hi", "", ""},
		// OKAMI-340: env options that take an argument.
		{"#!/usr/bin/env -u PYTHONPATH python3", "python3", "python"},
		{"#!/usr/bin/env -P /opt/bin ruby", "ruby", "ruby"},
		{"#!/usr/bin/env -C /tmp node", "node", "node"},
		{"#!/usr/bin/env --unset=FOO perl", "perl", "perl"},
		{"#!/usr/bin/env --unset FOO --chdir /tmp lua", "lua", "lua"},
		{"#!/usr/bin/env -i -- bash", "bash", "bash"},
		// OKAMI-369: uv runs PEP 723 scripts.
		{"#!/usr/bin/env -S uv run --script", "uv", "python"},
	}
	for c in cases {
		interp := wayu.script_shebang_interpreter(c.line)
		testing.expectf(
			t,
			interp == c.interp,
			"%q: interpreter %q, want %q",
			c.line,
			interp,
			c.interp,
		)
		lang := wayu.script_lang_by_interpreter(wayu.script_basename(interp))
		got := lang.name if lang != nil else ""
		testing.expectf(t, got == c.lang, "%q: language %q, want %q", c.line, got, c.lang)
	}
}

// OKAMI-369: `wayu: build =` header comments and the build argv.
@(test)
test_script_build_header :: proc(t: ^testing.T) {
	Case :: struct {
		content, want: string,
	}
	cases := []Case {
		{"// wayu: build = cc -O2 -o {out} {src}\nint main(){}\n", "cc -O2 -o {out} {src}"},
		{"#!/bin/sh\n# wayu: build = go build -o {out} {src}\n", "go build -o {out} {src}"},
		{"-- wayu:build=luac -o {out} {src}\n", "luac -o {out} {src}"},
		{"/* wayu: build = rustc -o {out} {src} */\nfn main(){}\n", "rustc -o {out} {src}"},
		{"int x; // not a header line\nwayu: build = cc\n", ""},
		{"print(1)\n", ""},
	}
	for c in cases {
		got := wayu.script_build_header(c.content)
		testing.expectf(t, got == c.want, "%q: %q, want %q", c.content, got, c.want)
	}
	// Past the first SCRIPT_BUILD_HEADER_LINES lines: ignored.
	far := strings.concatenate(
		{
			strings.repeat("x\n", wayu.SCRIPT_BUILD_HEADER_LINES, context.temp_allocator),
			"// wayu: build = cc -o {out} {src}\n",
		},
		context.temp_allocator,
	)
	testing.expect_value(t, wayu.script_build_header(far), "")

	argv, problem := wayu.script_build_argv(
		`cc -DMSG="a b" -o '{out}' {src}`,
		"/s/x.c",
		"/b/.x.build",
	)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(argv), 5)
	if len(argv) == 5 {
		testing.expect_value(t, argv[1], "-DMSG=a b")
		testing.expect_value(t, argv[3], "/b/.x.build")
		testing.expect_value(t, argv[4], "/s/x.c")
	}
	_, problem = wayu.script_build_argv("cc {src}", "a", "b")
	testing.expect(t, strings.contains(problem, "{out}"))
	_, problem = wayu.script_build_argv("cc 'oops", "a", "b")
	testing.expect_value(t, problem, "unterminated quote")
}

// OKAMI-338: a CRLF shebang is detected.
@(test)
test_script_shebang_crlf :: proc(t: ^testing.T) {
	testing.expect(t, wayu.script_shebang_has_cr("#!/bin/sh\r\necho hi\r\n"))
	testing.expect(t, !wayu.script_shebang_has_cr("#!/bin/sh\necho hi\r\n"))
	testing.expect(t, !wayu.script_shebang_has_cr("echo\r\n"))
}

@(test)
test_script_import_classification :: proc(t: ^testing.T) {
	Case :: struct {
		file, content, name, ext, lang, reason_has: string,
	}
	cases := []Case {
		{"greet.swift", "#!/usr/bin/swift\nprint(1)\n", "greet", "swift", "swift", ""},
		{"a", "#!/bin/bash\necho a\n", "a", "bash", "bash", ""},
		{"zz", "#!/usr/bin/env zsh\necho z\n", "zz", "zsh", "zsh", ""},
		{"tool", "#!/Users/u/.bun/bin/bun\nconsole.log(1)\n", "tool", "ts", "bun", ""},
		{"x.js", "#!/Users/u/.bun/bin/bun\nconsole.log(1)\n", "x", "js", "bun", ""},
		{"plain.py", "print(1)\n", "plain", "py", "python", ""},
		{"README", "hello\n", "", "", "", "no shebang"},
		{"awky", "#!/usr/bin/awk -f\n{print}\n", "", "", "", "unknown interpreter"},
		{"bin1", "#!/bin/sh\x00\x01", "", "", "", "binary"},
		{"elf", "\x7fELF\x02\x01", "", "", "", "binary"},
		{"macho", "\xcf\xfa\xed\xfe\x07", "", "", "", "binary"},
		{
			"launch",
			"#!/bin/sh\n# wrapper\nexec \"/abs/path/app/bin/tool\" \"$@\"\n",
			"",
			"",
			"",
			"launcher for /abs/path/app/bin/tool",
		},
		{
			"launch2",
			"#!/bin/sh\nexec /opt/x/bin/y \"$@\"\n",
			"",
			"",
			"",
			"launcher for /opt/x/bin/y",
		},
		{
			"black",
			"#!/Users/u/.local/pipx/venvs/black/bin/python\nimport sys\n",
			"",
			"",
			"",
			"package manager",
		},
		{
			"ruff",
			"#!/Users/u/.local/share/uv/tools/ruff/bin/python3\nimport sys\n",
			"",
			"",
			"",
			"package manager",
		},
		{"vt", "#!/w/.venv/bin/python\nprint(1)\n", "", "", "", "package manager"},
		{
			"foo",
			"#!/opt/py/bin/python3\n# -*- coding: utf-8 -*-\nimport re\nimport sys\nfrom foo.cli import main\nif __name__ == \"__main__\":\n    sys.argv[0] = re.sub(r\"(-script\\.pyw|\\.exe)?$\", \"\", sys.argv[0])\n    sys.exit(main())\n",
			"",
			"",
			"",
			"console_scripts",
		},
		// A real python script that happens to import things is kept.
		{
			"real",
			"#!/usr/bin/python3\nimport sys\nfrom os import path\n\ndef run():\n    print(path.sep)\n\nrun()\nsys.exit(0)\n",
			"real",
			"py",
			"python",
			"",
		},
		// Two commands: not a bare launcher.
		{"wrap", "#!/bin/sh\nexport X=1\nexec \"/abs/tool\" \"$@\"\n", "wrap", "sh", "sh", ""},
	}
	for c in cases {
		name, ext, lang, reason := wayu.script_classify_content(c.file, c.content)
		if len(c.reason_has) > 0 {
			testing.expectf(
				t,
				strings.contains(reason, c.reason_has),
				"%s: reason %q, want it to contain %q",
				c.file,
				reason,
				c.reason_has,
			)
			testing.expectf(t, lang == nil, "%s: skipped file has a language", c.file)
			continue
		}
		testing.expectf(t, reason == "", "%s: unexpected skip %q", c.file, reason)
		testing.expectf(t, name == c.name, "%s: name %q, want %q", c.file, name, c.name)
		testing.expectf(t, ext == c.ext, "%s: ext %q, want %q", c.file, ext, c.ext)
		got := lang.name if lang != nil else ""
		testing.expectf(t, got == c.lang, "%s: language %q, want %q", c.file, got, c.lang)
	}
}

@(test)
test_script_plan_import_filesystem :: proc(t: ^testing.T) {
	dir := test_tmp("wayu-test-script-plan")
	os.remove_all(dir)
	os.make_directory_all(dir)
	defer os.remove_all(dir)

	reg := fmt.tprintf("%s/hello", dir)
	_ = os.write_entire_file(reg, transmute([]byte)string("#!/bin/sh\necho hi\n"))
	link := fmt.tprintf("%s/hello-link", dir)
	_ = os.symlink(reg, link)
	sub := fmt.tprintf("%s/subdir", dir)
	os.make_directory(sub)

	p := wayu.script_plan_import(reg, nil)
	testing.expectf(t, p.reason == "" && p.name == "hello" && p.ext == "sh", "regular file: %v", p)
	p = wayu.script_plan_import(reg, {"hello"})
	testing.expectf(t, strings.contains(p.reason, "already exists"), "taken name: %q", p.reason)
	p = wayu.script_plan_import(link, nil)
	testing.expect_value(t, p.reason, "symlink")
	p = wayu.script_plan_import(sub, nil)
	testing.expect_value(t, p.reason, "not a regular file")
	p = wayu.script_plan_import(fmt.tprintf("%s/missing", dir), nil)
	testing.expect_value(t, p.reason, "not found")
}

@(test)
test_script_build_and_staleness :: proc(t: ^testing.T) {
	dir := test_tmp("wayu-test-script-build")
	os.remove_all(dir)
	os.make_directory_all(fmt.tprintf("%s/scripts", dir))
	defer os.remove_all(dir)
	original_data := wayu.wayu.data
	wayu.wayu.data = dir
	defer wayu.wayu.data = original_data

	// No script yet: <data>/bin stays off PATH.
	testing.expect_value(t, wayu.script_path_value(), "")

	// Interpreted: a relative symlink; stale again when the source loses +x.
	src := fmt.tprintf("%s/scripts/hello.sh", dir)
	_ = os.write_entire_file(src, transmute([]byte)string("#!/bin/sh\necho hi\n"))
	s, ok := wayu.script_find("hello")
	testing.expect(t, ok)
	testing.expect_value(t, s.lang.name, "sh")
	testing.expect(t, wayu.script_is_stale(s))
	testing.expect(t, wayu.script_build(s, quiet = true))
	testing.expect(t, !wayu.script_is_stale(s))
	target, _ := os.read_link(s.bin, context.temp_allocator)
	testing.expect_value(t, target, "../scripts/hello.sh")
	testing.expect_value(t, wayu.script_path_value(), fmt.tprintf("%s/bin", dir))
	_ = os.chmod(src, os.perm_number(0o644))
	testing.expect(t, wayu.script_is_stale(s))

	// Compiled, with a fake compiler on PATH: stale until built, again
	// after the source changes; a failed build keeps the old binary.
	fake := fmt.tprintf("%s/fakebin", dir)
	os.make_directory(fake)
	swiftc := fmt.tprintf("%s/swiftc", fake)
	_ = os.write_entire_file(
		swiftc,
		transmute([]byte)string(
			"#!/bin/sh\nout=; src=\nwhile [ $# -gt 0 ]; do case \"$1\" in -o) out=$2; shift 2;; -*) shift;; *) src=$1; shift;; esac; done\n" +
			"grep -q FAIL \"$src\" && { echo 'error: nope' >&2; exit 1; }\nprintf '#!/bin/sh\\necho built\\n' > \"$out\"\n",
		),
	)
	_ = os.chmod(swiftc, os.perm_number(0o755))
	old_path := os.get_env("PATH", context.temp_allocator)
	_ = os.set_env("PATH", fmt.tprintf("%s:%s", fake, old_path))
	defer os.set_env("PATH", old_path)

	sw := fmt.tprintf("%s/scripts/sw.swift", dir)
	_ = os.write_entire_file(sw, transmute([]byte)string("print(1)\n"))
	c, cok := wayu.script_find("sw")
	testing.expect(t, cok)
	testing.expect(t, wayu.script_is_compiled(c))
	testing.expect(t, wayu.script_is_stale(c))
	testing.expect(t, wayu.script_build(c, quiet = true))
	testing.expect(t, !wayu.script_is_stale(c))
	_ = os.write_entire_file(sw, transmute([]byte)string("print(2)\n"))
	testing.expect(t, wayu.script_is_stale(c))
	_ = os.write_entire_file(sw, transmute([]byte)string("FAIL\n"))
	testing.expect(t, !wayu.script_build(c, quiet = true))
	testing.expect(t, os.is_file(c.bin))
	testing.expect(t, wayu.script_is_stale(c))
}

@(test)
test_script_default_lang_validation :: proc(t: ^testing.T) {
	ok_issues := wayu.toml_content_schema_issues("[scripts]\ndefault_lang = \"python\"\n")
	testing.expect_value(t, len(ok_issues), 0)
	bad := wayu.toml_content_schema_issues("[scripts]\ndefault_lang = \"cobol\"\n")
	testing.expect_value(t, len(bad), 1)
	if len(bad) == 1 {
		testing.expect(t, bad[0].is_error)
		testing.expect(t, strings.contains(bad[0].msg, "cobol"))
	}
	unknown := wayu.toml_content_schema_issues("[scripts]\nfoo = 1\n")
	testing.expect_value(t, len(unknown), 1)
	if len(unknown) == 1 {
		testing.expect(t, !unknown[0].is_error)
	}
}

@(test)
test_script_build_is_preset :: proc(t: ^testing.T) {
	testing.expect(t, wayu.script_build_is_preset("swiftc -O -o {out} {src}"), "swift preset")
	testing.expect(t, !wayu.script_build_is_preset("cc -o {out} {src}"), "custom command")
	testing.expect(t, !wayu.script_build_is_preset(""), "empty")
}
