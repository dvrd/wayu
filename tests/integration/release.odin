package integration

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
release_formula :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	binary := cli.binary
	cli.binary = ".github/scripts/homebrew-formula.sh"
	shas: [4]string
	for letter, i in ([]string {
			"a",
			"b",
			"c",
			"d",
		}) {shas[i] = strings.repeat(letter, 64, context.temp_allocator)}
	formula := checked_cli(t, cli, "v1.2.3", shas[0], shas[1], shas[2], shas[3])
	readme := read_fixture(t, "README.md")
	for shell in ([]string{"bash", "zsh"}) {
		found := false
		for span in strings.split(readme, "`", context.temp_allocator) {
			if strings.has_prefix(span, "source \"${WAYU_DATA_DIR:-") &&
			   strings.has_suffix(span, fmt.tprintf("/init.%s\"", shell)) {
				found = strings.contains(formula, span)
				break
			}
		}
		testing.expectf(t, found, "formula caveats missing %s source line", shell)
	}
	testing.expect(t, !has_any(formula, ".config/wayu/init", "depends_on arch:"))
	path := fmt.tprintf("%s/wayu.rb", cli.home)
	write_fixture(t, path, formula)
	cli.binary = "ruby"
	checked_cli(t, cli, "-c", path)
	major, _, _ := strings.partition(
		strings.trim_space(read_fixture(t, ".github/macos-minimum-version")),
		".",
	)
	floor := ""
	switch major {
	case "11":
		floor = "big_sur"
	case "12":
		floor = "monterey"
	case "13":
		floor = "ventura"
	case "14":
		floor = "sonoma"
	case "15":
		floor = "sequoia"
	case "26":
		floor = "tahoe"
	}
	testing.expect(
		t,
		floor != "" && strings.contains(formula, fmt.tprintf("depends_on macos: :%s", floor)),
	)
	for row, i in ([][3]string {
			{"macos", "arm", "arm64"},
			{"macos", "intel", "amd64"},
			{"linux", "intel", "amd64"},
			{"linux", "arm", "arm64"},
		}) {
		_, _, tail := strings.partition(formula, fmt.tprintf("  on_%s do\n", row[0]))
		platform, _, _ := strings.partition(tail, "\n  end\n")
		_, _, body := strings.partition(platform, fmt.tprintf("    on_%s do\n", row[1]))
		cpu, _, _ := strings.partition(body, "\n    end")
		testing.expectf(
			t,
			strings.contains(cpu, fmt.tprintf("/v1.2.3/wayu-%s-%s.tar.gz\"", row[0], row[2])) &&
			strings.contains(cpu, fmt.tprintf("sha256 \"%s\"", shas[i])),
			"%v: %s",
			row,
			cpu,
		)
	}
	when ODIN_OS == .Darwin {
		if _, external := os.lookup_env("WAYU_BIN", context.temp_allocator); !external {
			cli.binary = ".github/scripts/check-macos-minos.sh"
			checked_cli(t, cli, binary)
		}
	}
}

@(test)
release_notes :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	cliff := fmt.tprintf("%s/cliff.md", cli.home)
	upgrading := fmt.tprintf("%s/UPGRADING.md", cli.home)
	original := `## [9.0.0] - 2026-01-01

### ⚠ Upgrade notes

- **shell**: Cut off footer from the
commit

### Added

- **x**: A feature

### Fixed

- **y**: A fix
`
	write_fixture(t, cliff, original)
	write_fixture(
		t,
		upgrading,
		`# Upgrading wayu

## Unreleased

- Next thing.

## 9.0.0

**Data dir moves**

- The full, curated note.

## 8.0.0

- Older note.
`,
	)
	cli.binary = ".github/scripts/release-notes.sh"
	out := checked_cli(t, cli, "v9.0.0", cliff, upgrading)
	for want in ([]string {
			"### ⚠ Upgrade notes\n\n**Data dir moves**\n\n- The full, curated note.",
			"UPGRADING.md#900",
			"### Added\n\n- **x**: A feature",
			"### Fixed\n\n- **y**: A fix",
		}) {testing.expectf(t, strings.contains(out, want), "missing %s", want)}
	testing.expect(t, !has_any(out, "Cut off footer", "Older note", "Next thing"))
	testing.expect(
		t,
		strings.index(out, "### ⚠ Upgrade notes") < strings.index(out, "### Added"),
	)
	testing.expect_value(t, checked_cli(t, cli, "v9.1.0", cliff, upgrading), original)
	before, _, _ := strings.partition(original, "### ⚠")
	_, added, after := strings.partition(original, "### Added")
	write_fixture(t, cliff, fmt.tprintf("%s%s%s", before, added, after))
	out = checked_cli(t, cli, "v9.0.0", cliff, upgrading)
	idx := strings.index(out, "### ⚠ Upgrade notes")
	testing.expect(
		t,
		strings.contains(out, "The full, curated note.") &&
		idx >= 0 &&
		idx < strings.index(out, "### Added"),
	)
	cli.binary = ".github/scripts/upgrading-version.sh"
	checked_cli(t, cli, "v9.1.0", upgrading)
	first := read_fixture(t, upgrading)
	testing.expect(
		t,
		strings.contains(first, "## 9.1.0\n\n- Next thing.") &&
		!strings.contains(first, "## Unreleased"),
	)
	checked_cli(t, cli, "v9.1.0", upgrading)
	testing.expect_value(t, read_fixture(t, upgrading), first)
}

@(test)
cliff_footer :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	cli.binary = "git"
	_, code := run_cli(t, cli, "cliff", "--version")
	if code != 0 {
		fmt.println("Skipping footer rendering because git-cliff is unavailable"); return
	}
	set_cli_env(&cli, "GIT_CONFIG_NOSYSTEM", "1")
	set_cli_env(&cli, "GIT_CONFIG_GLOBAL", "/dev/null")
	for pair in ([][2]string {
			{"GIT_AUTHOR_NAME", "fixture"},
			{"GIT_COMMITTER_NAME", "fixture"},
			{"GIT_AUTHOR_EMAIL", "fixture@example.invalid"},
			{"GIT_COMMITTER_EMAIL", "fixture@example.invalid"},
		}) {set_cli_env(&cli, pair[0], pair[1])}
	file := fmt.tprintf("%s/a", cli.home)
	checked_cli(t, cli, "-C", cli.home, "init", "-q")
	write_fixture(t, file, "1")
	checked_cli(t, cli, "-C", cli.home, "add", "a")
	checked_cli(t, cli, "-C", cli.home, "commit", "-qm", "feat: first")
	checked_cli(t, cli, "-C", cli.home, "tag", "v1.0.0")
	write_fixture(t, file, "2")
	checked_cli(t, cli, "-C", cli.home, "add", "a")
	checked_cli(
		t,
		cli,
		"-C",
		cli.home,
		"commit",
		"-qm",
		"fix(shell)!: literal dollars\n\nBody text.\n\nBREAKING CHANGE: values are literal; in zsh\n`$NAME:x` no longer applies modifiers;\nfish keeps `${NAME:-x}` literal. END-OF-FOOTER.",
	)
	config, err := os.get_absolute_path("cliff.toml", context.temp_allocator)
	testing.expect_value(t, err, nil)
	out := checked_cli(
		t,
		cli,
		"-C",
		cli.home,
		"cliff",
		"--config",
		config,
		"--unreleased",
		"--strip",
		"all",
	)
	testing.expect(
		t,
		strings.contains(
			out,
			"- **shell**: Values are literal; in zsh\n`$NAME:x` no longer applies modifiers;",
		) &&
		strings.contains(out, "END-OF-FOOTER."),
	)
}
