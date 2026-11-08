#!/usr/bin/env zsh
# lazy.zsh - deferred tools + user escape hatches

# === User tools.zsh (escape hatch for unrecognised tools) ===
if [ -f "@HOME@/.config/wayu/tools.zsh" ]; then source "@HOME@/.config/wayu/tools.zsh"; fi

# === Extra config ===
if [ -f "@HOME@/.config/wayu/extra.zsh" ]; then source "@HOME@/.config/wayu/extra.zsh"; fi

