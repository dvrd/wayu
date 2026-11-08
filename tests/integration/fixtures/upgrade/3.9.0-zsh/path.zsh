#!/usr/bin/env zsh

# Centralized PATH registry
# Managed by wayu - Add entries below
# Note: add_to_path() calls from v2.x are replaced by WAYU_PATHS array entries
WAYU_PATHS=(
  "@HOME@/tools"
  "@HOME@/bin dir"
)

# Build PATH from registry with deduplication
for dir in "${WAYU_PATHS[@]}"; do
    # Check if directory exists
    if [ ! -d "$dir" ]; then
        continue
    fi

    # Check if directory is already in PATH
    if [[ ":$PATH:" == *":$dir:"* ]]; then
        continue
    fi

    # Add to PATH (prepend)
    export PATH="$dir:$PATH"
done

# PATH is already deduplicated by the loop above
