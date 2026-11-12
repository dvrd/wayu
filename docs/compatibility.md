# Using wayu with other shell tools

Give each plugin and prompt one owner. Wayu can manage global entries while
another tool manages project environments, themes or plugins. Keep a tool out
of `[tools]` if its initializer already appears in your rc file.

## mise, Starship and direnv

Keep `[prompt] enabled = false` in wayu.toml when using Starship. After sourcing
wayu, activate mise, initialize Starship, and install direnv's hook last:

```zsh
# ~/.zshrc, after the wayu source line
eval "$(mise activate zsh)"
eval "$(starship init zsh)"
eval "$(direnv hook zsh)"
```

```bash
# ~/.bashrc, after the wayu source line
eval "$(mise activate bash)"
eval "$(starship init bash)"
eval "$(direnv hook bash)"
```

```fish
# ~/.config/fish/config.fish, after the wayu source line
mise activate fish | source
starship init fish | source
direnv hook fish | source
```

Use only the tools you need. On Bash login shells, source `.bashrc` from
`.bash_profile` when your setup lives there. Some Fish packages already
activate mise through vendor configuration; avoid a second activation.
The order above makes wayu's PATH available first and places direnv after
prompt-manipulating extensions, as its documentation requests.

The pinned real-upstream suite tests these initializers together, explicit
mise/direnv environment diffs when entering and leaving a fixture project,
direnv authorization, and preservation of Starship's prompt definition after
re-sourcing wayu. It does not certify every prompt transition, module or
third-party hook. References: [mise shell setup](https://mise.jdx.dev/shell-setup.html),
[Starship setup](https://starship.rs/guide/), [direnv hooks](https://direnv.net/docs/hook.html).

## chezmoi

Track selected source files, not the whole generated data directory. Follow
the [machine-transfer guide](../README.md#recreating-your-setup-on-another-machine),
apply your files, then run plugin restore and rebuild runtime/scripts locally.
Keep machine keys and plaintext session caches out of the source state.

Wayu mutates entries.json and plugins.json. Capture those edits back into
chezmoi before a later apply, for example with `chezmoi re-add` for the selected
tracked files. Otherwise an apply can replace your CLI edits with an older
source version. Alternatively use chezmoi's documented symlink-to-source
workflow for externally modified files; wayu's atomic writer preserves such
symlinks and replaces their targets. Do not sync a writer concurrently with
wayu: a dotfiles manager does not participate in wayu's config lock.

The real-upstream smoke test covers add → wayu mutation → re-add → apply.
Reference: [externally modified files](https://www.chezmoi.io/user-guide/manage-different-types-of-file/#handle-configuration-files-which-are-externally-modified).

## Oh My Zsh and Antidote

Source wayu first, then your existing manager. Keep wayu's native prompt off
while retaining an external theme. Each plugin should occur in only one
manager; disable wayu's built-in highlighting or suggestions when an external
plugin owns that feature.

Migrate one plugin at a time: remove it from the old manager's list, add it to
wayu, and verify its completion and key bindings in a new shell before moving
the next one. Keep the old configuration in version control for rollback.
Neither manager's plugin-list format is a plugins.json import format.

The pinned smoke tests load each actual manager with a local plugin and
completion, then re-source wayu and verify one plugin load and retained global
entries. Oh My Zsh updates are disabled in the test. This does not establish
parity for every theme, plugin ordering rule or widget wrapper.
References: [Oh My Zsh settings](https://github.com/ohmyzsh/ohmyzsh/wiki/Settings),
[Antidote](https://antidote.sh/).

## Fisher

Let Fisher own Fisher plugins and let wayu own global entries. Keep Fisher's
`fish_plugins` manifest alongside the selected wayu source files, and replay
it with Fisher on a new machine. Do not install the same plugin twice.

Fisher's function, completion and install-event behavior is tested with its
actual pinned implementation and a local fixture plugin before sourcing wayu.
Wayu's source-only Fish loader does not implement all Fisher lifecycle/theme
semantics; retaining Fisher is the supported recipe for plugins that need
them. Reference: [Fisher](https://github.com/jorgebucaran/fisher#creating-a-plugin).

## Sheldon

Keep each plugin in either Sheldon or wayu. Source wayu first, then use
Sheldon's generated source or your static loader. Regenerate a static loader
when changing its configuration. The pinned smoke suite checks actual source
generation and loading of a local plugin alongside wayu; the benchmark records
both normal and static-loader startup separately.
Reference: [Sheldon](https://sheldon.cli.rs/).

## Reproducing the evidence

`tests/ecosystem/tools.json` pins the upstream release archives by SHA-256 and
source trees by full commit. To run in temporary homes:

```sh
python3 tests/ecosystem/fetch.py /tmp/wayu-upstreams
WAYU_ECOSYSTEM_DIR=/tmp/wayu-upstreams WAYU_BIN="$PWD/bin/wayu" ruby tests/ecosystem/smoke.rb
```

This network suite is separate from offline integration tests. CI runs it on
macOS and Linux as a release dependency and retains the output and manifest.
Missing dependencies or a failed assertion fail the job. See
[benchmark methodology](benchmarks.md) for performance evidence and
[the security review brief](security-review.md) for the separate assessment
required before promoting multi-machine secrets.
