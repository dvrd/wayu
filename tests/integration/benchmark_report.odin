package integration

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

@(test)
benchmark_report :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	python := cli
	python.binary = "python3"
	metrics := []string {
		"first_prompt_lag_ms",
		"first_command_lag_ms",
		"command_lag_ms",
		"input_lag_ms",
		"exit_time_ms",
	}
	flags := []string{"has_compsys", "has_autosuggestions", "has_syntax_highlighting"}
	b := strings.builder_make(context.temp_allocator)
	for metric in metrics {fmt.sbprintf(&b, "%s=( 1 3 )\n", metric)}
	for flag in flags {fmt.sbprintf(&b, "%s=( 1 1 )\n", flag)}
	raw := fmt.tprintf("%s/fixture.raw", cli.home)
	output := fmt.tprintf("%s/report.json", cli.home)
	good := strings.to_string(b)
	write_fixture(t, raw, good)
	write_fixture(t, fmt.tprintf("%s/fixture.cold", cli.home), "10.5")
	args := []string {
		"tests/benchmark/report.py",
		"--results",
		cli.home,
		"--output",
		output,
		"--binary",
		cli.binary,
		"--zsh",
		"zsh",
		"--iters",
		"2",
		"--pin",
		"fixture=synthetic",
	}
	checked_cli(t, python, ..args)
	Row :: struct {
		median_ms:                  map[string]f64,
		samples_ms:                 map[string][]f64,
		cold_first_process_exit_ms: f64,
	}
	doc: struct {
		results:       map[string]Row,
		binary_sha256: string,
		pins:          map[string]string,
	}
	err := json.unmarshal(
		transmute([]byte)read_fixture(t, output),
		&doc,
		allocator = context.temp_allocator,
	)
	testing.expect_value(t, err, nil)
	row := doc.results["fixture"]
	for metric in metrics {
		testing.expect_value(t, row.median_ms[metric], 2)
		samples := row.samples_ms[metric]
		testing.expect(t, len(samples) == 2 && samples[0] == 1 && samples[1] == 3)
	}
	testing.expect_value(t, len(doc.binary_sha256), 64)
	testing.expect_value(t, doc.pins["fixture"], "synthetic")
	testing.expect_value(t, row.cold_first_process_exit_ms, 10.5)
	for pair in ([][2]string {
			{"1 3", "NaN 3"},
			{"1 3", "1"},
			{"has_compsys=( 1 1 )", "has_compsys=( 1 )"},
		}) {
		bad, _ := strings.replace(good, pair[0], pair[1], 1, context.temp_allocator)
		write_fixture(t, raw, bad)
		_, code := run_cli(t, python, ..args)
		testing.expectf(t, code != 0, "accepted %s", pair[1])
	}
	timer := "tests/benchmark/run_with_timeout.py"
	out := checked_cli(t, python, timer, "--seconds", "5", "--elapsed", "python3", "-c", "pass")
	seconds, ok := strconv.parse_f64(strings.trim_space(out))
	testing.expectf(t, ok && seconds >= 0, "elapsed: %s", out)
	expect_exit(
		t,
		python,
		124,
		timer,
		"--seconds",
		"0.1",
		"python3",
		"-c",
		"import time; time.sleep(10)",
	)
	expect_exit(t, python, 7, timer, "--seconds", "5", "python3", "-c", "raise SystemExit(7)")
}
