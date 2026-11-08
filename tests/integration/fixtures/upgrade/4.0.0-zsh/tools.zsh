#!/usr/bin/env zsh
#
# tools.zsh — user escape hatch for tool init not modeled by [tools] in wayu.toml.
#
# Most lazy loaders are now declarative in wayu.toml:
#
#   [tools]
#   nvm    = { kind = "nvm" }
#   conda  = { kind = "conda" }
#   zoxide = { kind = "evalcache", args = "init zsh" }
#   atuin  = { kind = "evalcache", args = "init zsh --disable-up-arrow", eager = true }
#   sdk    = { kind = "lazy", init_script = "$HOME/.sdkman/bin/sdkman-init.sh", hook_commands = ["sdk"] }
#
# Run 'wayu build eval' after editing wayu.toml. The corresponding lazy loaders
# are emitted into init-lazy.zsh so they work in every interactive shell
# (login, non-login, Ghostty/Zellij/tmux panes).
#
# Use this file ONLY for one-off, machine-specific tool setup that doesn't fit
# any built-in recipe. Do not eagerly source large init scripts here — they
# block prompt rendering. Wrap them in a lazy loader instead.
