#!/usr/bin/env zsh

# Plugin keybindings and configuration
# Auto-generated from wayu.toml

# === zsh-autosuggestions ===
if (( ${+widgets[autosuggest-accept]} )); then
  bindkey '^Y' autosuggest-accept
  bindkey -M emacs '^Y' autosuggest-accept
  bindkey -M main '^Y' autosuggest-accept
  bindkey -M viins '^Y' autosuggest-accept
  bindkey '^[[121;5u' autosuggest-accept
  bindkey -M emacs '^[[121;5u' autosuggest-accept
  bindkey -M main '^[[121;5u' autosuggest-accept
  bindkey -M viins '^[[121;5u' autosuggest-accept
fi
