#!/usr/bin/env zsh

# Wayu Shell Initialization - Main Orchestrator
# Sources core.<ext>, which wayu compiles from wayu.toml

# Directories. wayu writes this file into its data dir, so that dir is this
# file's own location (WAYU_DATA_DIR / WAYU_CONFIG_DIR given to wayu need not
# be exported to the shell). The config dir holds wayu.toml.
_wayu_d=${${(%):-%x}:a:h}
if [ -f "$_wayu_d/init.zsh" ]; then WAYU_DATA_DIR=$_wayu_d; fi
unset _wayu_d
: ${WAYU_DATA_DIR:=$HOME/.config/wayu}
if [ -z "${WAYU_CONFIG_DIR-}" ]; then
    if [ -f "$WAYU_DATA_DIR/wayu.toml" ]; then WAYU_CONFIG_DIR=$WAYU_DATA_DIR; else WAYU_CONFIG_DIR=$HOME/.config/wayu; fi
fi

# === Compiled core ===
# core.zsh is generated from wayu.toml (any wayu write, or 'wayu build') and
# sources plugins.zsh, tools.zsh and extra.zsh itself (once each).
if [ -f "$WAYU_DATA_DIR/core.zsh" ]; then
    source "$WAYU_DATA_DIR/core.zsh"
else
    echo "wayu: $WAYU_DATA_DIR/core.zsh is missing; run 'wayu build'" >&2
fi
