#!/usr/bin/env fish

# Centralized PATH registry
# Managed by wayu - Add entries below

# Define PATH entries array
set -gx WAYU_PATHS

# Build PATH from registry with deduplication
for dir in $WAYU_PATHS
    # Check if directory exists
    if not test -d "$dir"
        continue
    end

    # Check if directory is already in PATH
    if contains "$dir" $PATH
        continue
    end

    # Add to PATH (prepend)
    set -gx PATH "$dir" $PATH
end
