package integration

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

startup_median :: proc(t: ^testing.T, env: []string, command: []string) -> f64 {
	samples: [9]f64
	for i in 0 ..< len(samples) + 2 {
		start := time.tick_now()
		state, _, stderr, err := os.process_exec(
			{command = command, env = env},
			context.temp_allocator,
		)
		ms := time.duration_seconds(time.tick_since(start)) * 1000
		if err != nil || state.exit_code != 0 || len(stderr) != 0 {
			testing.fail_now(
				t,
				fmt.tprintf(
					"%s: %v, exit %d: %s",
					command[0],
					err,
					state.exit_code,
					string(stderr),
				),
			)
		}
		if i >= 2 {
			samples[i - 2] = ms
		}
	}
	slice.sort(samples[:])
	return samples[len(samples) / 2]
}

@(test)
startup_budget :: proc(t: ^testing.T) {
	for shell in ([]string{"zsh", "bash", "fish"}) {
		cli := new_cli(t)
		defer os.remove_all(cli.home)
		probe := cli
		probe.binary = "/bin/sh"
		out, code := run_cli(t, probe, "-c", "command -v \"$1\"", "probe", shell)
		if shell == "fish" && code != 0 {
			continue
		}
		if code != 0 {
			testing.fail_now(t, fmt.tprintf("missing %s", shell))
		}
		exe := strings.trim_space(out)
		set_cli_env(&cli, "SHELL", fmt.tprintf("/bin/%s", shell))
		set_cli_env(&cli, "PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
		expect_exit(t, cli, 0, "init", "--shell", shell)
		paths := make([dynamic]Fixture_Path, context.temp_allocator)
		env := make([dynamic]Named_Value, context.temp_allocator)
		aliases := make([dynamic]Named_Value, context.temp_allocator)
		append(&env, Named_Value{"GOPATH", "$HOME/go"})
		for i in 0 ..< 40 {
			dir := fmt.tprintf("%s/bins/b%d", cli.home, i)
			if i % 2 == 0 {
				testing.expect(t, os.make_directory_all(dir) == nil)
			}
			append(&paths, Fixture_Path{fmt.tprintf("p%d", i), dir})
			append(
				&env,
				Named_Value {
					fmt.tprintf("BUDGET_E%d", i),
					fmt.tprintf("value-%d:%s", i, "${HOME}/x"),
				},
			)
		}
		append(&paths, Fixture_Path{"gobin", "$GOPATH/bin"})
		for i in 0 ..< 60 {append(&aliases, Named_Value{fmt.tprintf("ba%d", i), fmt.tprintf("echo alias %d && ls -la", i)})}
		set_store(t, cli, paths = paths[:], aliases = aliases[:], env = env[:])
		write_fixture(
			t,
			fmt.tprintf("%s/.config/wayu/wayu.toml", cli.home),
			`[tools]
sdk = { kind = "lazy", init_script = "~/.sdk/init.sh", hook_commands = ["sdk"] }
`,
		)
		expect_exit(t, cli, 0, "completions", "generate")
		expect_exit(t, cli, 0, "build")
		flag := "-f"
		if shell == "bash" {
			flag = "--norc"
		} else if shell == "fish" {
			flag = "--no-config"
		}
		empty := startup_median(t, cli.env, {exe, flag, "-c", ":"})
		script := fmt.tprintf("source \"$HOME/.local/share/wayu/init.%s\"", shell)
		loaded := startup_median(t, cli.env, {exe, flag, "-c", script})
		budget: f64 = 250 if shell == "fish" else 150
		if override, ok := os.lookup_env("WAYU_STARTUP_BUDGET_MS", context.temp_allocator); ok {
			parsed, valid := strconv.parse_f64(override)
			if !valid {
				testing.fail_now(t, "invalid WAYU_STARTUP_BUDGET_MS")
			}
			budget = parsed
		}
		testing.expectf(
			t,
			loaded - empty <= budget,
			"%s added %.1f ms (budget %.1f ms)",
			shell,
			loaded - empty,
			budget,
		)
	}
}
