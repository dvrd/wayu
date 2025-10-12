# ZSH Setup Examples

This guide shows common ZSH setup scenarios using wayu, leveraging ZSH-specific features and optimizations.

## Scenario 1: macOS ZSH User Setup

### Initial Setup
```zsh
# Check your shell
echo $SHELL
# Output: /bin/zsh

# Initialize wayu (automatic shell detection)
wayu init
# Output:
# Detected shell: ZSH
# Using shell: ZSH (config files will use .zsh extension)
# Created directory: ~/.config/wayu
# Created config file: ~/.config/wayu/path.zsh
# Created config file: ~/.config/wayu/aliases.zsh
# Created config file: ~/.config/wayu/constants.zsh
# Created config file: ~/.config/wayu/init.zsh
# Created config file: ~/.config/wayu/tools.zsh
```

### Add macOS Development Paths
```zsh
# Homebrew paths (Intel Mac)
wayu path add /usr/local/bin
wayu path add /usr/local/sbin

# Homebrew paths (Apple Silicon Mac)
wayu path add /opt/homebrew/bin
wayu path add /opt/homebrew/sbin

# User development paths
wayu path add ~/.local/bin
wayu path add ~/bin

# Language ecosystems
wayu path add ~/.cargo/bin          # Rust
wayu path add ~/.go/bin             # Go
wayu path add ~/.npm-global/bin     # Node.js global
wayu path add ~/.gem/ruby/bin       # Ruby gems
wayu path add ~/.composer/vendor/bin # PHP Composer

# Verify all paths
wayu path list
```

### Set Up ZSH-Enhanced Aliases
```zsh
# Enhanced navigation with ZSH features
wayu alias add ll "ls -alF"
wayu alias add la "ls -A"
wayu alias add l "ls -CF"
wayu alias add .. "cd .."
wayu alias add ... "cd ../.."
wayu alias add .... "cd ../../.."

# Git shortcuts optimized for ZSH
wayu alias add gs "git status"
wayu alias add ga "git add"
wayu alias add gaa "git add ."
wayu alias add gc "git commit"
wayu alias add gcm "git commit -m"
wayu alias add gp "git push"
wayu alias add gpl "git pull"
wayu alias add gd "git diff"
wayu alias add gl "git log --oneline"
wayu alias add gb "git branch"
wayu alias add gco "git checkout"

# ZSH-specific development shortcuts
wayu alias add serve "python3 -m http.server"
wayu alias add json "python3 -m json.tool"
wayu alias add server "http-server -p 8000"
wayu alias add myip "curl ifconfig.me"
wayu alias add weather "curl wttr.in"

# macOS-specific shortcuts
wayu alias add finder "open ."
wayu alias add desktop "cd ~/Desktop"
wayu alias add downloads "cd ~/Downloads"
wayu alias add documents "cd ~/Documents"

# List all aliases
wayu alias list
```

### Configure Development Environment
```zsh
# Shell and editor preferences
wayu constants add EDITOR "code"  # VS Code
wayu constants add BROWSER "open -a 'Google Chrome'"
wayu constants add TERM "xterm-256color"

# ZSH-specific configurations
wayu constants add HISTSIZE "10000"
wayu constants add SAVEHIST "10000"
wayu constants add HISTFILE "$HOME/.zsh_history"

# Development tools
wayu constants add GOPATH "$HOME/go"
wayu constants add CARGO_HOME "$HOME/.cargo"
wayu constants add RUSTUP_HOME "$HOME/.rustup"
wayu constants add NPM_CONFIG_PREFIX "$HOME/.npm-global"

# Project organization
wayu constants add PROJECTS_DIR "$HOME/dev/projects"
wayu constants add WORKSPACE "$HOME/workspace"
wayu constants add DOTFILES "$HOME/.dotfiles"

# macOS-specific
wayu constants add HOMEBREW_NO_ANALYTICS "1"
wayu constants add HOMEBREW_NO_AUTO_UPDATE "1"

# List all constants
wayu constants list
```

## Scenario 2: ZSH with Oh My Zsh Integration

### Oh My Zsh Compatibility Setup
```zsh
# Initialize wayu
wayu init

# Oh My Zsh theme and plugin paths
wayu path add ~/.oh-my-zsh/custom/plugins
wayu path add ~/.oh-my-zsh/custom/themes

# Git aliases that complement Oh My Zsh
wayu alias add gst "git status"
wayu alias add gca "git commit -a"
wayu alias add gcam "git commit -a -m"
wayu alias add gba "git branch -a"
wayu alias add glog "git log --oneline --decorate --graph"

# Development workflow aliases
wayu alias add dev "cd $PROJECTS_DIR"
wayu alias add work "cd $WORKSPACE"
wayu alias add dots "cd $DOTFILES"

# Oh My Zsh constants
wayu constants add ZSH_THEME "powerlevel10k/powerlevel10k"
wayu constants add DISABLE_AUTO_UPDATE "true"
wayu constants add COMPLETION_WAITING_DOTS "true"
```

## Scenario 3: ZSH for DevOps/Infrastructure

### Cloud and Infrastructure Tools
```zsh
# Initialize wayu
wayu init

# Cloud CLI tools paths
wayu path add ~/.local/bin/aws
wayu path add ~/.local/bin/gcloud
wayu path add ~/.local/bin/az

# Container and orchestration paths
wayu path add ~/.docker/bin
wayu path add ~/.krew/bin  # kubectl plugins

# Infrastructure aliases
wayu alias add k "kubectl"
wayu alias add kgp "kubectl get pods"
wayu alias add kgs "kubectl get services"
wayu alias add kgd "kubectl get deployments"
wayu alias add kdp "kubectl describe pod"
wayu alias add klogs "kubectl logs -f"

# Docker & Kubernetes
wayu alias add d "docker"
wayu alias add dc "docker-compose"
wayu alias add k8s "kubectl"

# Terraform shortcuts
wayu alias add tf "terraform"
wayu alias add tfi "terraform init"
wayu alias add tfp "terraform plan"
wayu alias add tfa "terraform apply"
wayu alias add tfd "terraform destroy"

# Cloud provider shortcuts
wayu alias add awsp "aws-profile"
wayu alias add gcpauth "gcloud auth login"

# Infrastructure constants
wayu constants add KUBE_CONFIG_PATH "$HOME/.kube/config"
wayu constants add AWS_DEFAULT_REGION "us-west-2"
wayu constants add TERRAFORM_LOG "WARN"
wayu constants add DOCKER_BUILDKIT "1"
```

## Scenario 4: ZSH for Frontend Development

### Modern JavaScript Development
```zsh
# Initialize wayu
wayu init

# Node.js ecosystem paths
wayu path add ~/.npm-global/bin
wayu path add ~/.yarn/bin
wayu path add ~/.pnpm
wayu path add ./node_modules/.bin

# Frontend development aliases
wayu alias add npm-list "npm list -g --depth=0"
wayu alias add npm-update "npm update -g"
wayu alias add yarn-upgrade "yarn global upgrade"

# Package managers
wayu alias add ni "npm install"
wayu alias add nid "npm install --save-dev"
wayu alias add nig "npm install -g"
wayu alias add nr "npm run"
wayu alias add ns "npm start"
wayu alias add nt "npm test"
wayu alias add nb "npm run build"

# Yarn shortcuts
wayu alias add ya "yarn add"
wayu alias add yad "yarn add --dev"
wayu alias add yr "yarn run"
wayu alias add ys "yarn start"
wayu alias add yt "yarn test"
wayu alias add yb "yarn build"

# Development servers
wayu alias add serve-react "npx serve -s build"
wayu alias add serve-spa "npx http-server -p 3000 -c-1"

# Frontend constants
wayu constants add NODE_ENV "development"
wayu constants add NPM_CONFIG_PREFIX "$HOME/.npm-global"
wayu constants add YARN_GLOBAL_FOLDER "$HOME/.yarn"
wayu constants add BROWSER "none"  # Disable auto-opening browser
```

## Generated Configuration Examples

### path.zsh (ZSH-optimized PATH management)
```zsh
#!/usr/bin/env zsh

add_to_path() {
    local dir="$1"
    local position="${2:-prepend}"  # prepend or append, default is prepend

    # Check if directory exists
    if [ ! -d "$dir" ]; then
        return 1
    fi

    # Check if directory is already in PATH
    if [[ ":$PATH:" == *":$dir:"* ]]; then
        return 0
    fi

    # Add to PATH
    if [ "$position" = "append" ]; then
        export PATH="$PATH:$dir"
    else
        export PATH="$dir:$PATH"
    fi
}

# Your PATH entries
add_to_path "/opt/homebrew/bin"
add_to_path "/opt/homebrew/sbin"
add_to_path "$HOME/.local/bin"
add_to_path "$HOME/bin"
add_to_path "$HOME/.cargo/bin"
add_to_path "$HOME/.go/bin"

# Remove duplicates from PATH (ZSH-optimized method)
export PATH=$(echo "$PATH" | awk -v RS=':' -v ORS=':' '!seen[$0]++' | sed 's/:$//')
```

### aliases.zsh
```zsh
#!/usr/bin/env zsh

# Shell Aliases Configuration
# Enhanced navigation
alias ll="ls -alF"
alias la="ls -A"
alias l="ls -CF"
alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."

# Git shortcuts optimized for ZSH
alias gs="git status"
alias ga="git add"
alias gaa="git add ."
alias gc="git commit"
alias gcm="git commit -m"
alias gp="git push"
alias gpl="git pull"
alias gd="git diff"
alias gl="git log --oneline"
alias gb="git branch"
alias gco="git checkout"

# Development shortcuts
alias serve="python3 -m http.server"
alias json="python3 -m json.tool"
alias myip="curl ifconfig.me"
alias weather="curl wttr.in"

# macOS-specific shortcuts
alias finder="open ."
alias desktop="cd ~/Desktop"
alias downloads="cd ~/Downloads"
alias documents="cd ~/Documents"
```

### constants.zsh
```zsh
#!/usr/bin/env zsh

# Environment Constants and Configuration Variables
export EDITOR="code"
export BROWSER="open -a 'Google Chrome'"
export TERM="xterm-256color"

# ZSH-specific configurations
export HISTSIZE="10000"
export SAVEHIST="10000"
export HISTFILE="$HOME/.zsh_history"

# Development tools
export GOPATH="$HOME/go"
export CARGO_HOME="$HOME/.cargo"
export RUSTUP_HOME="$HOME/.rustup"
export NPM_CONFIG_PREFIX="$HOME/.npm-global"

# Project organization
export PROJECTS_DIR="$HOME/dev/projects"
export WORKSPACE="$HOME/workspace"
export DOTFILES="$HOME/.dotfiles"

# macOS-specific
export HOMEBREW_NO_ANALYTICS="1"
export HOMEBREW_NO_AUTO_UPDATE="1"
```

### init.zsh (Main orchestrator)
```zsh
#!/usr/bin/env zsh

# Wayu Shell Initialization - Main Orchestrator (ZSH)
# This file loads all configuration modules in the correct order

# === 1. Core Configuration ===
# Load constants and environment variables first (they may be needed by other modules)
source "$HOME/.config/wayu/constants.zsh"

# === 2. PATH Configuration ===
# Set up PATH with all your custom directories
source "$HOME/.config/wayu/path.zsh"

# === 3. Aliases and Shortcuts ===
# Load all your custom aliases and command shortcuts
source "$HOME/.config/wayu/aliases.zsh"

# === 4. External Tool Integration ===
# Initialize external tools and frameworks (NVM, Starship, etc.)
source "$HOME/.config/wayu/tools.zsh"

# === 5. Local Customizations ===
# Source local config if it exists (for machine-specific settings)
if [ -f "$HOME/.config/wayu/local.zsh" ]; then
    source "$HOME/.config/wayu/local.zsh"
fi
```

## Integration with .zshrc

Add this line to your `~/.zshrc`:
```zsh
# Wayu shell configuration
source "$HOME/.config/wayu/init.zsh"
```

Or let wayu add it for you:
```zsh
wayu init
# It will prompt: "Would you like to add wayu to your ~/.zshrc? [Y/n]:"
```

## ZSH-Specific Features

### History Configuration
ZSH templates include optimized history settings:
```zsh
export HISTSIZE=10000
export SAVEHIST=10000
export HISTFILE="$HOME/.zsh_history"
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE
setopt HIST_VERIFY
```

### Completion Enhancements
```zsh
# Enable advanced completions
autoload -Uz compinit
compinit

# Case-insensitive completion
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
```

### Oh My Zsh Integration
If you use Oh My Zsh, wayu works seamlessly:
```zsh
# In your .zshrc, after Oh My Zsh initialization
source $ZSH/oh-my-zsh.sh

# Then load wayu
source "$HOME/.config/wayu/init.zsh"
```

## Testing Your Setup

```zsh
# Test PATH additions
echo $PATH | tr ':' '\n' | grep -E "(homebrew|local|cargo)"

# Test aliases
ll
gs  # Should show git status
weather  # Should show weather info

# Test constants
echo $EDITOR
echo $GOPATH
echo $HISTSIZE

# List all wayu-managed configurations
wayu path list
wayu alias list
wayu constants list
```

## Advanced ZSH Features

### Custom Functions
You can add custom functions to `~/.config/wayu/local.zsh`:
```zsh
# Create a new project directory
mkproject() {
    mkdir -p "$PROJECTS_DIR/$1"
    cd "$PROJECTS_DIR/$1"
}

# Quick search in history
hist() {
    history | grep "$1"
}

# Extract any archive
extract() {
    if [ -f $1 ] ; then
        case $1 in
            *.tar.bz2)   tar xjf $1     ;;
            *.tar.gz)    tar xzf $1     ;;
            *.bz2)       bunzip2 $1     ;;
            *.rar)       unrar e $1     ;;
            *.gz)        gunzip $1      ;;
            *.tar)       tar xf $1      ;;
            *.tbz2)      tar xjf $1     ;;
            *.tgz)       tar xzf $1     ;;
            *.zip)       unzip $1       ;;
            *.Z)         uncompress $1  ;;
            *.7z)        7z x $1        ;;
            *)     echo "'$1' cannot be extracted via extract()" ;;
        esac
    else
        echo "'$1' is not a valid file"
    fi
}
```

### Troubleshooting

#### Shell Detection Issues
```zsh
# If wayu doesn't detect ZSH correctly
echo $SHELL
wayu --shell zsh init  # Force ZSH mode

# Check what shell wayu detected
wayu init  # Look for "Detected shell: ZSH" message
```

#### PATH Not Working
```zsh
# Check if init.zsh is sourced in .zshrc
grep -n wayu ~/.zshrc

# Manually source to test
source ~/.config/wayu/init.zsh
echo $PATH
```

#### Oh My Zsh Conflicts
```zsh
# If you have conflicts with Oh My Zsh plugins
# Load wayu after Oh My Zsh in your .zshrc:
source $ZSH/oh-my-zsh.sh
source "$HOME/.config/wayu/init.zsh"
```