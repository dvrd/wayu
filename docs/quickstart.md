# Quickstart

Install wayu, add its one line to your shell, and move your first PATH
entries, aliases and secrets into it. Every command, flag and exit code is in
the [CLI reference](cli.md); every config key in the
[configuration reference](config-reference.md).

## Install

Homebrew (macOS 15 or later on Apple silicon or Intel, Linux on x86_64 or
arm64):

```bash
brew tap dvrd/wayu
brew install wayu
wayu init
```

Or the install script, on the same platforms without Homebrew:

```bash
curl -fsSL https://wayu.dvrd.io/install.sh | sh
wayu init
```

It downloads the release archive for your OS and CPU, checks its SHA-256
(and its [build provenance attestation](https://github.com/dvrd/wayu/blob/main/SECURITY.md#verifying-release-binaries)
when the GitHub CLI `gh` is installed and logged in), and installs `wayu` to
`~/.local/bin`, replacing an older one atomically. `WAYU_VERSION=v7.0.0`
installs that release, `WAYU_INSTALL_DIR` another directory. It refuses to
install next to a Homebrew-managed wayu (`WAYU_FORCE=1` overrides), and says
when the directory is not on your `PATH`. To upgrade, run it again. Read it
first if you like: [install.sh](https://wayu.dvrd.io/install.sh).

Other platforms (older macOS, musl Linux, the BSDs) build from source. It
needs the
[Odin compiler](https://odin-lang.org/docs/install/) at the release named in
[`.github/odin-release`](https://github.com/dvrd/wayu/blob/main/.github/odin-release):

```bash
git clone https://github.com/dvrd/wayu && cd wayu
odin build build -out:build_it && ./build_it install   # installs to ~/.local/bin, runs wayu init
```

Use one install method: while Homebrew manages wayu, `./build_it install`
and the install script refuse to run.

## Set up your shell

`wayu init` creates `~/.config/wayu/` (`wayu.toml` and the other files you
edit) and `~/.local/share/wayu/` (your entries and the generated files), and
offers to add one line to your rc file, or prints it when stdin is not a
terminal:

| Shell | rc file | Line |
|---|---|---|
| zsh | `${ZDOTDIR:-~}/.zshrc` | `source "${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.zsh"` |
| bash | `~/.bash_profile` if it exists, else `~/.bashrc` | `source "${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.bash"` |
| fish | `~/.config/fish/config.fish` | `if test -n "$WAYU_DATA_DIR"; source $WAYU_DATA_DIR/init.fish; else if test -n "$XDG_DATA_HOME"; source $XDG_DATA_HOME/wayu/init.fish; else; source ~/.local/share/wayu/init.fish; end` |

The shell is detected from `$SHELL`; `wayu init --shell bash` (or `zsh`,
`fish`) picks another one. Run it once per shell you use: they share one
`wayu.toml` and one set of entries. Open a new shell afterwards.

## First commands

```bash
# PATH entries: open shells pick them up at their next prompt
wayu path add ~/.cargo/bin
wayu path list

# Aliases and constants (exported variables)
wayu alias add gs 'git status -sb'
wayu const add EDITOR nvim

# An encrypted secret: the value is read with hidden input
wayu const add OPENAI_API_KEY --secret

# A secret only one command gets, never exported to the shell
wayu const add GH_TOKEN --run-only
wayu secrets run GH_TOKEN -- gh auth status

# Plugins, from the registry or a git URL
wayu plugin add autosuggestions

# Check the whole setup
wayu doctor
```

Running `wayu` with no arguments opens the full-screen TUI. Every write is
backed up first: `wayu backup list` shows the backups, and
`wayu backup restore entries --yes` undoes the last change to your entries.

## Bring over an existing rc file

Lines that installers appended to your `.zshrc` (`eval "$(tool init zsh)"`,
`source <(tool completion zsh)`, `fpath` edits, PATH exports, aliases) can
move into wayu, where they are cached:

```bash
wayu optimize --dry-run   # the diff and the list of what would move
wayu optimize --yes       # back the file up, rewrite it, update wayu
```

Only top-level lines after wayu's own line are touched;
`wayu backup restore .zshrc --yes` undoes it.

## Next

- [CLI reference](cli.md): every command, the `--json` shapes, exit codes.
- [Configuration](config-reference.md): `wayu.toml` (`[settings]`, `[tools]`,
  `[prompt]`, `[secrets]`), `entries.json` and the generated files.
- [Stability](STABILITY.md): what each release promises.
- [Upgrading](UPGRADING.md): what changed in each release.
