#!/usr/bin/env bash
# lazy.bash - deferred tools + user escape hatches

# === User tools.bash (escape hatch for unrecognised tools) ===
if [ -f "@HOME@/.config/wayu/tools.bash" ]; then source "@HOME@/.config/wayu/tools.bash"; fi

# === Extra config ===
if [ -f "@HOME@/.config/wayu/extra.bash" ]; then source "@HOME@/.config/wayu/extra.bash"; fi

