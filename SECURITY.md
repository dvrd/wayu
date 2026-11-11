# Security Policy

## Supported versions

Only the latest release of wayu receives security fixes. Upgrade
(`brew upgrade wayu`, or rebuild from `main`) before reporting.

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Report it privately through GitHub's private vulnerability reporting:
[**Report a vulnerability**](https://github.com/dvrd/wayu/security/advisories/new)
(repository **Security** tab → **Report a vulnerability**).

Include:

- the wayu version (`wayu --version`) and shell (zsh, bash or fish)
- what an attacker controls (a `wayu.toml` value, a plugin repository, a
  `hooks.conf` entry, a file in `~/.config/wayu/` or `~/.local/share/wayu/`, …) and what they gain
- steps or a minimal config that reproduces it

You will get an acknowledgement on the advisory, and the fix is released as a
normal version with the advisory published once users can upgrade.

## Scope

wayu writes shell code that every new shell sources, so these are in scope:

- values from `wayu.toml` or CLI arguments that escape their quoting in the
  generated `init`/`core` files and run as code
- path traversal or writes outside wayu's two directories, the config dir
  (`~/.config/wayu/`, `WAYU_CONFIG_DIR`) and the data dir
  (`${XDG_DATA_HOME:-~/.local/share}/wayu/`, `WAYU_DATA_DIR`) (backups,
  restore, plugins, completions, export, scripts)
- secret-looking constant values leaking into output, previews or files
  readable by other users
- release artifacts or the Homebrew formula not matching the source

Plugins and hooks run code by design: a plugin you install, or a command you
put in `hooks.conf`, executing is not a vulnerability by itself.

## Verifying release binaries

Release archives carry a SHA-256 checksum file; releases after v5.0.0 also
carry a GitHub build provenance attestation. Verify an archive with the
[GitHub CLI](https://cli.github.com/):

```bash
gh attestation verify wayu-macos-arm64.tar.gz --repo dvrd/wayu
```
