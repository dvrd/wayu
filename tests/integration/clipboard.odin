package integration

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
clipboard :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	expect_exit(t, cli, 0, "init", "--shell", "zsh")
	fake_bin := fmt.tprintf("%s/clipboard-bin", cli.home)
	data := fmt.tprintf("%s/.local/share/wayu", cli.home)
	plugin := fmt.tprintf("%s/plugins/demo", data)
	copied := fmt.tprintf("%s/copied", cli.home)
	for dir in ([]string{fake_bin, plugin}) {
		if err := os.make_directory_all(dir); err != nil {
			testing.fail_now(t, fmt.tprintf("mkdir %s: %v", dir, err))
		}
	}
	url := fmt.tprintf(
		"https://example.invalid/%s",
		strings.repeat("x", 131_072, context.temp_allocator),
	)
	write_fixture(
		t,
		fmt.tprintf("%s/plugins.json", data),
		strings.concatenate(
			{
				`{"version":"1.0","plugins":[{"name":"demo","url":"`,
				url,
				`","enabled":true,"shell":"zsh","installedPath":"`,
				plugin,
				`","template":"source","priority":100,"git":{},"use":[]}]}`,
			},
			context.temp_allocator,
		),
	)
	set_cli_env(&cli, "PATH", fmt.tprintf("%s:/usr/bin:/bin", fake_bin))
	set_cli_env(&cli, "WAYU_CLIP_FIXTURE", copied)
	install_helpers :: proc(t: ^testing.T, dir, body: string) {
		for name in ([]string{"pbcopy", "xclip", "xsel"}) {
			path := fmt.tprintf("%s/%s", dir, name)
			write_fixture(t, path, fmt.tprintf("#!/bin/sh\n%s\n", body))
			if err := os.chmod(path, os.Permissions{.Read_User, .Write_User, .Execute_User});
			   err != nil {
				testing.fail_now(t, fmt.tprintf("chmod %s: %v", path, err))
			}
		}
	}
	install_helpers(t, fake_bin, "exec 0<&-\nsleep 0.05")
	out, code := run_cli(t, cli, "plugin", "get", "demo")
	testing.expectf(
		t,
		code == 0 && strings.contains(out, "Failed to copy URL"),
		"early close: %d %s",
		code,
		out,
	)
	for mode in ([]string{"foreground", "background owner", "background reader"}) {
		body := `cat > "$WAYU_CLIP_FIXTURE"`
		switch mode {
		case "background owner":
			body = `cat > "$WAYU_CLIP_FIXTURE"
sleep 4 &`
		case "background reader":
			body = `exec 3<&0
(sleep 0.05; cat > "$WAYU_CLIP_FIXTURE") <&3 3<&- >/dev/null 2>&1 &
exit 0`
		}
		if os.exists(copied) {
			_ = os.remove(copied)
		}
		install_helpers(t, fake_bin, body)
		start := time.tick_now()
		out, code = run_cli(t, cli, "plugin", "get", "demo")
		testing.expectf(
			t,
			code == 0 && strings.contains(out, "URL copied to clipboard"),
			"%s: exit %d",
			mode,
			code,
		)
		if mode == "background owner" {
			testing.expect(t, time.tick_since(start) < 3 * time.Second)
		}
		start = time.tick_now()
		for {
			bytes, err := os.read_entire_file_from_path(copied, context.temp_allocator)
			if err == nil && string(bytes) == url {
				break
			}
			if mode != "background reader" || time.tick_since(start) >= 2 * time.Second {
				testing.fail_now(t, fmt.tprintf("%s: incomplete clipboard transfer", mode))
			}
			time.sleep(10 * time.Millisecond)
		}
	}
}
