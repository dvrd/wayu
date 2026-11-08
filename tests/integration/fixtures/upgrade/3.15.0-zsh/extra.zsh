#!/usr/bin/env zsh

# Extra Shell Configuration
# This file is for custom shell snippets that don't fit into other wayu categories.
# Anything written here is sourced at the end of init, before PATH deduplication.
#
# Common uses:
#   - Conditional hooks (chpwd, preexec, precmd)
#   - Third-party tool env loaders (cargo, bun, conda, etc.)
#   - Custom functions that don't belong in ~/.config/wayu/functions
#   - Completion fpath additions
#   - Ad-hoc exports and settings
