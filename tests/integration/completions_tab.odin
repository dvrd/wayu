package integration
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

Tab_Case :: struct {
	line:         string,
	want, reject: []string,
}
tab_cases := [?]Tab_Case {
	{"wayu ", {"path", "alias", "secrets", "backup"}, {"add", "gst"}},
	{"wayu --dry-run al", {"alias"}, {"add"}},
	{"wayu --shell bash alias rm ", {"gst"}, {"add"}},
	{"wayu alias rm ", {"gst"}, {"add", "rm"}},
	{"wayu alias --dry-run rm ", {"gst"}, {"add"}},
	{"wayu alias rm gst ", {}, {"gst", "add"}},
	{"wayu alias ", {"add", "rm", "list"}, {"gst"}},
	{"wayu -y const get DY", {"DYN_CONST"}, {"SEC1"}},
	{"wayu const get --yes DY", {"DYN_CONST"}, {}},
	{"wayu alias rm --", {"--dry-run", "--yes", "--help"}, {"--version", "--tui", "--lang"}},
	{"wayu alias list --", {"--json"}, {}},
	{"wayu --", {"--version", "--tui", "--dry-run"}, {"--json"}},
	{"wayu script new foo --l", {"--lang"}, {}},
	{"wayu script new foo --lang ", {"swift", "python", "fish"}, {"foo"}},
	{"wayu script --lang ruby new foo --c", {"--copy"}, {}},
	{"wayu script new foo --lang=py", {"python"}, {"ruby"}},
	{"wayu --shell ", {"zsh", "bash", "fish"}, {"path"}},
	{"wayu path list --source ", {"wayu", "external", "inactive", "all"}, {}},
	{"wayu plugin search --category g", {"git"}, {"syntax"}},
	{"wayu plugin search -c ", {"git", "syntax", "prompt"}, {}},
	{"wayu plugin add zsh-ab", {"zsh-abbr"}, {}},
	{"wayu init --template m", {"minimal"}, {"full"}},
	{"wayu template apply d", {"developer", "data-science"}, {"minimal"}},
	{"wayu backup restore ", {"toml", "entries"}, {"1"}},
	{"wayu backup restore entries ", {"1", "2"}, {"toml"}},
	{"wayu backup --yes restore entries ", {"1"}, {}},
	{"wayu secrets run ", {"SEC1"}, {"DYN_CONST"}},
	{"wayu secrets run SEC1 ", {"SEC1"}, {"DYN_CONST"}},
	{"wayu secrets run SEC1 -- ech", {"echo"}, {"SEC1"}},
	{"wayu completions fpath ", {"list", "add", "rm"}, {}},
	{"wayu doctor --", {"--fix", "--json"}, {}},
	{"wayu bogus ", {}, {"path", "add", "gst"}},
}

@(test)
completions_tab :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	checked_cli(t, cli, "init", "--shell", "zsh")
	config := fmt.tprintf("%s/.config/wayu/wayu.toml", cli.home)
	write_fixture(
		t,
		config,
		fmt.tprintf("%s\n[secrets]\nbackend = \"file\"\n", read_fixture(t, config)),
	)
	checked_cli(t, cli, "alias", "add", "gst", "git status")
	checked_cli(t, cli, "const", "add", "DYN_CONST", "1")
	sh := cli
	sh.binary = "/bin/sh"
	checked_cli(t, sh, "-c", `printf 'v\n' | "$1" const add SEC1 --secret`, "seed", cli.binary)
	backups, err := os.glob(
		fmt.tprintf("%s/.local/share/wayu/backup/entries.json.backup.*", cli.home),
		context.temp_allocator,
	)
	testing.expect(t, err == nil && len(backups) >= 2)
	lines := make([dynamic]string, context.temp_allocator)
	for c in tab_cases {append(&lines, c.line)}
	casefile := fmt.tprintf("%s/cases.txt", cli.home)
	write_fixture(
		t,
		casefile,
		fmt.tprintf("%s\n", strings.join(lines[:], "\n", context.temp_allocator)),
	)
	set_cli_env(&cli, "_WAYU_BIN", cli.binary)
	set_cli_env(&cli, "TAB_DIR", cli.home)
	set_cli_env(&cli, "TAB_OUT", fmt.tprintf("%s/zsh.out", cli.home))
	for shell in ([]string{"zsh", "bash", "fish"}) {
		_, code := run_cli(t, sh, "-c", `command -v "$1"`, "which", shell)
		if code != 0 {
			continue
		}
		module := checked_cli(t, cli, "completions", shell)
		module_path := fmt.tprintf("%s/wayu.%s", cli.home, shell)
		write_fixture(t, module_path, module)
		cmd: []string
		switch shell {
		case "zsh":
			testing.expect_value(t, os.make_directory(fmt.tprintf("%s/fpath", cli.home)), nil)
			write_fixture(t, fmt.tprintf("%s/fpath/_wayu", cli.home), module)
			write_fixture(
				t,
				fmt.tprintf("%s/init.zsh", cli.home),
				#load("fixtures/tab_init.zsh", string),
			)
			cmd = {shell, "-f", "tests/integration/fixtures/tab_driver.zsh", casefile}
		case "fish":
			cmd = {
				shell,
				"--no-config",
				"-c",
				`source $argv[1]
while read -l line
    echo "@@ $line"
    complete -C "$line"
end < $argv[2]`,
				module_path,
				casefile,
			}
		case "bash":
			cmd = {
				"/bin/bash",
				"--norc",
				"--noprofile",
				"-c",
				`source "$1"
while IFS= read -r line; do
    COMP_LINE=$line
    COMP_POINT=${#line}
    read -ra COMP_WORDS <<< "${line//=/ = }"
    [[ $line == *' ' ]] && COMP_WORDS+=('')
    COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
    COMPREPLY=()
    _wayu_completion
    printf '@@ %s\n' "$line"
    printf '%s\n' "${COMPREPLY[@]}"
done < "$2"`,
				"probe",
				module_path,
				casefile,
			}
		}
		path := fmt.tprintf("%s/%s.out.txt", cli.home, shell)
		file, ferr := os.create(path)
		if ferr != nil {
			testing.fail_now(t, fmt.tprintf("create %s: %v", path, ferr))
		}
		defer os.close(file)
		child, serr := os.process_start(
			{command = cmd, env = cli.env, stdout = file, stderr = os.stderr},
		)
		if serr != nil {
			testing.fail_now(t, fmt.tprintf("start %s: %v", shell, serr))
		}
		state, werr := os.process_wait(child, 120 * time.Second)
		if werr != nil {
			_ = os.process_kill(child); _, _ = os.process_wait(child)
			testing.fail_now(t, fmt.tprintf("%s: %v", shell, werr))
		}
		testing.expect_value(t, state.exit_code, 0)
		candidates := make(map[string]map[string]bool, context.temp_allocator)
		current: string
		output := read_fixture(t, path)
		for line in strings.split_lines_iterator(&output) {
			if strings.has_prefix(line, "@@ ") {
				current = line[3:]
				candidates[current] = make(map[string]bool, context.temp_allocator)
			} else if current != "" && line != "" {
				name, _, _ := strings.partition(line, "\t")
				if strings.has_prefix(name, "--") {
					_, found, v := strings.partition(name, "=")
					if found != "" {
						name = v
					}
				}
				matches := candidates[current]
				matches[name] = true
				candidates[current] = matches
			}
		}
		for c in tab_cases {
			matches, found := candidates[c.line]
			testing.expectf(t, found, "%s omitted %q", shell, c.line)
			for word in c.want {testing.expectf(t, matches[word], "%s %q missing %q", shell, c.line, word)}
			for word in c.reject {testing.expectf(t, !matches[word], "%s %q unexpected %q", shell, c.line, word)}
		}
	}
}
