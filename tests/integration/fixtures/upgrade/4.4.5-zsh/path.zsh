#!/usr/bin/env zsh

# Centralized PATH registry
# Managed by wayu - Add entries below
# Note: add_to_path() calls from v2.x are replaced by WAYU_PATHS array entries
WAYU_PATHS=(
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

# Final deduplication pass (Zsh-compatible method)
remove_path_duplicates() {
    local new_path=""
    local dir
    local -a dirs
    dirs=(${(s/:/)PATH})
    for dir in "${dirs[@]}"; do
        if [[ ":$new_path:" != *":$dir:"* ]] && [ -n "$dir" ]; then
            if [ -z "$new_path" ]; then
                new_path="$dir"
            else
                new_path="$new_path:$dir"
            fi
        fi
    done
    export PATH="$new_path"
}

remove_path_duplicates
