# Bash Setup Examples

This guide shows common Bash setup scenarios using wayu.

## Scenario 1: New Bash User Setup

### Initial Setup
```bash
# Check your shell
echo $SHELL
# Output: /bin/bash

# Initialize wayu (automatic shell detection)
wayu init
# Output:
# Detected shell: Bash
# Using shell: Bash (config files will use .bash extension)
# Created directory: ~/.config/wayu
# Created config file: ~/.config/wayu/path.bash
# Created config file: ~/.config/wayu/aliases.bash
# Created config file: ~/.config/wayu/constants.bash
# Created config file: ~/.config/wayu/init.bash
# Created config file: ~/.config/wayu/tools.bash
```

### Add Common Development Paths
```bash
# Add Homebrew paths (macOS)
wayu path add /opt/homebrew/bin
wayu path add /opt/homebrew/sbin

# Add user local paths
wayu path add ~/.local/bin
wayu path add ~/bin

# Add language-specific paths
wayu path add ~/.cargo/bin          # Rust
wayu path add ~/.go/bin             # Go
wayu path add ~/.npm-global/bin     # Node.js global

# Verify all paths
wayu path list
```

### Set Up Common Aliases
```bash
# Navigation shortcuts
wayu alias add ll "ls -alF"
wayu alias add la "ls -A"
wayu alias add l "ls -CF"
wayu alias add .. "cd .."
wayu alias add ... "cd ../.."

# Git shortcuts
wayu alias add gs "git status"
wayu alias add ga "git add"
wayu alias add gc "git commit"
wayu alias add gp "git push"
wayu alias add gl "git pull"
wayu alias add gd "git diff"

# Development shortcuts
wayu alias add serve "python3 -m http.server"
wayu alias add myip "curl ifconfig.me"
wayu alias add weather "curl wttr.in"

# List all aliases
wayu alias list
```

### Configure Environment Constants
```bash
# Development environment
wayu constants add EDITOR "vim"
wayu constants add BROWSER "firefox"
wayu constants add TERM "xterm-256color"

# Development tools
wayu constants add GOPATH "$HOME/go"
wayu constants add CARGO_HOME "$HOME/.cargo"
wayu constants add RUSTUP_HOME "$HOME/.rustup"

# Custom project paths
wayu constants add PROJECTS_DIR "$HOME/dev/projects"
wayu constants add WORKSPACE "$HOME/workspace"

# List all constants
wayu constants list
```

## Scenario 2: Ubuntu Server Setup

### System Administrator Setup
```bash
# Initialize wayu
wayu init

# Add system admin paths
wayu path add /usr/local/sbin
wayu path add /usr/sbin
wayu path add /sbin

# System maintenance aliases
wayu alias add ll "ls -alF --color=auto"
wayu alias add grep "grep --color=auto"
wayu alias add fgrep "fgrep --color=auto"
wayu alias add egrep "egrep --color=auto"

# System shortcuts
wayu alias add update "sudo apt update && sudo apt upgrade"
wayu alias add install "sudo apt install"
wayu alias add search "apt search"
wayu alias add services "sudo systemctl status"

# Monitoring shortcuts
wayu alias add processes "ps aux | grep"
wayu alias add ports "netstat -tulpn | grep"
wayu alias add memory "free -h"
wayu alias add disk "df -h"

# System constants
wayu constants add LOG_DIR "/var/log"
wayu constants add CONFIG_DIR "/etc"
wayu constants add BACKUP_DIR "/opt/backups"
```

## Scenario 3: Docker Development Environment

### Container Development Setup
```bash
# Initialize wayu
wayu init

# Docker-specific paths
wayu path add ~/.docker/bin

# Docker aliases
wayu alias add d "docker"
wayu alias add dc "docker-compose"
wayu alias add dcu "docker-compose up"
wayu alias add dcd "docker-compose down"
wayu alias add dcb "docker-compose build"
wayu alias add dps "docker ps"
wayu alias add di "docker images"

# Container management
wayu alias add dstop "docker stop \$(docker ps -q)"
wayu alias add drm "docker rm \$(docker ps -aq)"
wayu alias add drmi "docker rmi \$(docker images -q)"
wayu alias add dprune "docker system prune -f"

# Development constants
wayu constants add DOCKER_BUILDKIT "1"
wayu constants add COMPOSE_PROJECT_NAME "myproject"
wayu constants add REGISTRY "docker.io"
```

## Scenario 4: CI/CD Environment

### Automated Build Environment
```bash
# Initialize wayu for CI
wayu --shell bash init

# CI-specific paths
wayu path add ~/.local/bin
wayu path add /opt/ci-tools/bin

# Build aliases
wayu alias add build "make build"
wayu alias add test "make test"
wayu alias add deploy "make deploy"
wayu alias add lint "make lint"

# CI constants
wayu constants add CI "true"
wayu constants add BUILD_ENV "production"
wayu constants add PARALLEL_JOBS "4"
```

## Generated Configuration Examples

### path.bash (Bash-optimized PATH management)
```bash
#!/usr/bin/env bash

add_to_path() {
    local dir="$1"
    local position="${2:-prepend}"

    if [ ! -d "$dir" ]; then
        return 1
    fi

    if [[ ":$PATH:" == *":$dir:"* ]]; then
        return 0
    fi

    if [ "$position" = "append" ]; then
        export PATH="$PATH:$dir"
    else
        export PATH="$dir:$PATH"
    fi
}

# Remove duplicates from PATH (Bash-compatible method)
remove_path_duplicates() {
    local new_path=""
    local dir
    IFS=':' read -ra DIRS <<< "$PATH"
    for dir in "${DIRS[@]}"; do
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

# Your PATH entries
add_to_path "/opt/homebrew/bin"
add_to_path "/opt/homebrew/sbin"
add_to_path "$HOME/.local/bin"
add_to_path "$HOME/bin"
add_to_path "$HOME/.cargo/bin"

remove_path_duplicates
```

### aliases.bash
```bash
#!/usr/bin/env bash

# Shell Aliases Configuration
# Navigation shortcuts
alias ll="ls -alF"
alias la="ls -A"
alias l="ls -CF"
alias ..="cd .."
alias ...="cd ../.."

# Git shortcuts
alias gs="git status"
alias ga="git add"
alias gc="git commit"
alias gp="git push"
alias gl="git pull"
alias gd="git diff"

# Development shortcuts
alias serve="python3 -m http.server"
alias myip="curl ifconfig.me"
alias weather="curl wttr.in"
```

### constants.bash
```bash
#!/usr/bin/env bash

# Environment Constants and Configuration Variables
export EDITOR="vim"
export BROWSER="firefox"
export TERM="xterm-256color"
export GOPATH="$HOME/go"
export CARGO_HOME="$HOME/.cargo"
export RUSTUP_HOME="$HOME/.rustup"
export PROJECTS_DIR="$HOME/dev/projects"
export WORKSPACE="$HOME/workspace"
```

### init.bash (Main orchestrator)
```bash
#!/usr/bin/env bash

# Wayu Shell Initialization - Main Orchestrator (Bash)
# This file loads all configuration modules in the correct order

# === 1. Core Configuration ===
# Load constants and environment variables first (they may be needed by other modules)
source "$HOME/.config/wayu/constants.bash"

# === 2. PATH Configuration ===
# Set up PATH with all your custom directories
source "$HOME/.config/wayu/path.bash"

# === 3. Aliases and Shortcuts ===
# Load all your custom aliases and command shortcuts
source "$HOME/.config/wayu/aliases.bash"

# === 4. External Tool Integration ===
# Initialize external tools and frameworks (NVM, Starship, etc.)
source "$HOME/.config/wayu/tools.bash"

# === 5. Local Customizations ===
# Source local config if it exists (for machine-specific settings)
if [ -f "$HOME/.config/wayu/local.bash" ]; then
    source "$HOME/.config/wayu/local.bash"
fi
```

## Integration with .bashrc

Add this line to your `~/.bashrc`:
```bash
# Wayu shell configuration
source "$HOME/.config/wayu/init.bash"
```

Or let wayu add it for you:
```bash
wayu init
# It will prompt: "Would you like to add wayu to your ~/.bashrc? [Y/n]:"
```

## Testing Your Setup

```bash
# Test PATH additions
echo $PATH | tr ':' '\n' | grep -E "(homebrew|local|cargo)"

# Test aliases
ll
gs  # Should show git status

# Test constants
echo $EDITOR
echo $GOPATH

# List all wayu-managed configurations
wayu path list
wayu alias list
wayu constants list
```

## Troubleshooting

### Shell Detection Issues
```bash
# If wayu doesn't detect Bash correctly
echo $SHELL
wayu --shell bash init  # Force Bash mode

# Check what shell wayu detected
wayu init  # Look for "Detected shell: Bash" message
```

### PATH Not Working
```bash
# Check if init.bash is sourced in .bashrc
grep -n wayu ~/.bashrc

# Manually source to test
source ~/.config/wayu/init.bash
echo $PATH
```

### Aliases Not Loading
```bash
# Test alias loading
source ~/.config/wayu/aliases.bash
alias | grep -E "(ll|gs|gc)"
```