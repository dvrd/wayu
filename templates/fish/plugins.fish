#!/usr/bin/env fish

# Plugin Configuration for Fish Shell
# This file manages plugin loading and configuration

# Plugin loading helper function
function wayu_load_plugin
    set plugin_name $argv[1]
    set plugin_path "$HOME/.config/wayu/plugins/$plugin_name"

    if test -d "$plugin_path"
        # Load all .fish files in plugin directory
        for f in $plugin_path/*.fish
            if test -f "$f"
                source "$f"
            end
        end
    else
        echo "[wayu] Plugin not found: $plugin_name"
    end
end

# Plugin configuration storage
set -g WAYU_PLUGINS_LOADED

# Register a loaded plugin
function wayu_register_plugin
    set -a WAYU_PLUGINS_LOADED $argv[1]
end

# List loaded plugins
function wayu_list_plugins
    echo "Loaded plugins:"
    for plugin in $WAYU_PLUGINS_LOADED
        echo "  - $plugin"
    end
end
