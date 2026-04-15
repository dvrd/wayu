# wayu TOML Configuration Guide

Complete reference for using TOML-based declarative configuration with wayu.

## Table of Contents

1. [Overview](#overview)
2. [File Locations](#file-locations)
3. [Configuration Format](#configuration-format)
4. [PATH Configuration](#path-configuration)
5. [Alias Configuration](#alias-configuration)
6. [Constants Configuration](#constants-configuration)
7. [Plugin Configuration](#plugin-configuration)
8. [Profile-Based Configuration](#profile-based-configuration)
9. [Environment-Specific Settings](#environment-specific-settings)
10. [Lock Files](#lock-files)
11. [CLI Integration](#cli-integration)
12. [Migration from CLI to TOML](#migration-from-cli-to-toml)
13. [Best Practices](#best-practices)

---

## Overview

wayu supports two configuration modes:

1. **Imperative (CLI)** - Default mode: `wayu path add /usr/local/bin`
2. **Declarative (TOML)** - Configuration files: `~/.config/wayu/wayu.toml`

Both modes can coexist. CLI commands modify the shell config files directly, while TOML is used for advanced features like profiles, templates, and version locking.

### When to Use TOML

| Use Case | Recommended Approach |
|----------|---------------------|
| Quick edits | CLI (`wayu path add ...`) |
| Team/dotfiles sharing | TOML + version control |
| Profile-based configs | TOML profiles |
| Plugin dependencies | TOML plugin sections |
| Reproducible setups | TOML + lock files |
| CI/CD environments | TOML declarative |

---

## File Locations

| File | Purpose |
|------|---------|
| `~/.config/wayu/wayu.toml` | Main user configuration |
| `~/.config/wayu/wayu.local.toml` | Machine-specific overrides (gitignored) |
| `~/.config/wayu/wayu.lock` | Lock file for reproducible builds |
| `~/.config/wayu/profiles/*.toml` | Profile-specific configurations |
| `./wayu.toml` | Project-specific configuration |

### Load Order

1. `~/.config/wayu/wayu.toml` (base config)
2. `~/.config/wayu/profiles/<active>.toml` (profile overlay)
3. `~/.config/wayu/wayu.local.toml` (machine-specific)
4. `./wayu.toml` (project-specific, if exists)

Later files override earlier ones.

---

## Configuration Format

```toml
# wayu.toml - Main configuration file

# ─────────────────────────────────────────────────────────────────────────
# Global Settings
# ─────────────────────────────────────────────────────────────────────────

[settings]
# Shell to use (zsh, bash, auto)
shell = "zsh"

# Default profile to activate
profile = "default"

# Backup settings
[settings.backup]
enabled = true          # Auto-backup before modifications
keep_count = 5          # Number of backups to retain

# Fuzzy matching settings
[settings.fuzzy]
enabled = true          # Enable fuzzy search
auto_fallback = true    # Auto fuzzy match on GET commands
interactive = true      # Interactive selector when multiple matches

# ─────────────────────────────────────────────────────────────────────────
# PATH Configuration
# ─────────────────────────────────────────────────────────────────────────

[path]
# Entries are added in order (top = highest priority)
entries = [
    "/usr/local/bin",
    "/opt/homebrew/bin",
    "$HOME/.cargo/bin",
    "$HOME/.local/bin",
]

# Per-entry options
[[path.entry]]
path = "/custom/path"
condition = "[[ -d /custom/path ]]"  # Only add if directory exists

# ─────────────────────────────────────────────────────────────────────────
# Aliases
# ─────────────────────────────────────────────────────────────────────────

[aliases]
# Simple aliases
ll = "ls -la"
la = "ls -A"
l = "ls -CF"

# Grouped aliases (for organization)
[aliases.git]
g = "git"
ga = "git add"
gaa = "git add --all"
gc = "git commit -v"
gcm = "git commit -m"
gco = "git checkout"
gd = "git diff"
gl = "git pull"
gp = "git push"
gst = "git status"

[aliases.docker]
d = "docker"
dc = "docker compose"
dps = "docker ps"
dpsa = "docker ps -a"

# ─────────────────────────────────────────────────────────────────────────
# Environment Constants
# ─────────────────────────────────────────────────────────────────────────

[constants]
EDITOR = "nvim"
VISUAL = "nvim"
PAGER = "less"

# Conditional constants
[constants.conditional]
[constants.conditional.work]
condition = "[[ \$HOSTNAME == *'work'* ]]"
AWS_PROFILE = "work-account"
CORPORATE_PROXY = "http://proxy.company.com:8080"

# ─────────────────────────────────────────────────────────────────────────
# Plugin Management
# ─────────────────────────────────────────────────────────────────────────

[plugins]

# GitHub plugins with full URL
[plugins.zsh-autosuggestions]
source = "github:zsh-users/zsh-autosuggestions"
enable = true
priority = 50  # Lower = loads first

[plugins.zsh-syntax-highlighting]
source = "github:zsh-users/zsh-syntax-highlighting"
enable = true
priority = 60

# Oh My Zsh plugins
[plugins.git]
source = "github:ohmyzsh/ohmyzsh"
path = "plugins/git"
enable = true

[plugins.docker]
source = "github:ohmyzsh/ohmyzsh"
path = "plugins/docker"
enable = true

# Local plugins
[plugins.my-local-plugin]
source = "local:$HOME/.config/zsh/my-plugin"
enable = true

# Plugins with dependencies
[plugins.fzf-tab]
source = "github:Aloxaf/fzf-tab"
enable = true
depends_on = ["fzf"]

# Conditional plugins
[plugins.work-specific]
source = "local:$HOME/.work/config"
enable = true
profile = "work"  # Only load in "work" profile

# ─────────────────────────────────────────────────────────────────────────
# Completions
# ─────────────────────────────────────────────────────────────────────────

[completions]
# Completion script paths
paths = [
    "$HOME/.config/zsh/completions",
    "/usr/local/share/zsh/site-functions",
]

# Individual completion files
[[completions.file]]
name = "_docker"
source = "local:$HOME/.config/zsh/completions/_docker"

# ─────────────────────────────────────────────────────────────────────────
# External Tool Integration
# ─────────────────────────────────────────────────────────────────────────

[tools]
# Tool initialization scripts to source

[tools.starship]
enable = true
command = 'eval "$(starship init zsh)"'
condition = "command -v starship >/dev/null 2>&1"

[tools.fzf]
enable = true
command = 'eval "$(fzf --zsh)"'
condition = "command -v fzf >/dev/null 2>&1"

[tools.nvm]
enable = true
command = 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"'
condition = "[[ -d $HOME/.nvm ]]"

[tools.zoxide]
enable = true
command = 'eval "$(zoxide init zsh)"'
condition = "command -v zoxide >/dev/null 2>&1"

# ─────────────────────────────────────────────────────────────────────────
# Templates (Advanced)
# ─────────────────────────────────────────────────────────────────────────

[templates]
# Custom loading templates for plugins

[templates.defer]
before = "zsh-defer source {{file}}"

[templates.conditional]
before = "[[ -f {{file}} ]] && source {{file}}"

# ─────────────────────────────────────────────────────────────────────────
# Hooks
# ─────────────────────────────────────────────────────────────────────────

[hooks]
# Scripts to run at different lifecycle points

[hooks.pre_init]
# Run before generating init script
check_health = "$HOME/.config/wayu/hooks/health-check.sh"

[hooks.post_init]
# Run after init generation
notify = "echo 'wayu config loaded'"

[hooks.pre_plugin_load]
# Run before loading plugins
log_plugins = "$HOME/.config/wayu/hooks/log-plugins.sh"
```

---

## PATH Configuration

### Basic PATH Entries

```toml
[path]
entries = [
    "/usr/local/bin",
    "/opt/homebrew/bin",
    "$HOME/.cargo/bin",
]
```

### Conditional PATH Entries

```toml
[[path.entry]]
path = "/opt/homebrew/opt/llvm/bin"
condition = "[[ -d /opt/homebrew/opt/llvm/bin ]]"

[[path.entry]]
path = "$HOME/.local/share/gem/bin"
condition = "command -v gem >/dev/null 2>&1"
```

### Per-OS PATH

```toml
[[path.entry]]
path = "/Applications/Docker.app/Contents/Resources/bin"
condition = "[[ $OSTYPE == 'darwin'* ]]"

[[path.entry]]
path = "/usr/lib/wsl/lib"
condition = "[[ -f /proc/sys/fs/binfmt_misc/WSLInterop ]]"
```

### PATH Prepending vs Appending

```toml
[[path.entry]]
path = "/usr/local/opt/python@3.11/bin"
position = "prepend"  # Add to front of PATH

[[path.entry]]
path = "/usr/local/opt/python@3.11/share/man"
position = "append"   # Add to end (default)
```

---

## Alias Configuration

### Simple Aliases

```toml
[aliases]
ll = "ls -la"
la = "ls -A"
l = "ls -CF"
```

### Grouped Aliases

```toml
[aliases.git]
g = "git"
ga = "git add"
gc = "git commit"

[aliases.kubernetes]
k = "kubectl"
kgp = "kubectl get pods"
kgpa = "kubectl get pods --all-namespaces"
```

### Conditional Aliases

```toml
[[aliases.conditional]]
name = "docker"
value = "podman"
condition = "command -v podman >/dev/null 2>&1"
```

### Global Aliases (Zsh)

```toml
[aliases.global]
L = "| less"
G = "| grep"
H = "| head"
T = "| tail"
```

---

## Constants Configuration

### Basic Environment Variables

```toml
[constants]
EDITOR = "nvim"
VISUAL = "nvim"
PAGER = "less"
BROWSER = "firefox"
```

### Conditional Variables

```toml
[[constants.conditional]]
name = "WORKSPACE"
value = "/home/user/work"
condition = "[[ $HOSTNAME == 'work-laptop' ]]"

[[constants.conditional]]
name = "WORKSPACE"
value = "/home/user/personal"
condition = "[[ $HOSTNAME == 'personal-laptop' ]]"
```

### Computed Values

```toml
[[constants.computed]]
name = "SSH_AUTH_SOCK"
command = "gpgconf --list-dirs agent-ssh-socket"
condition = "command -v gpgconf >/dev/null 2>&1"
```

---

## Plugin Configuration

### GitHub Plugins

```toml
[plugins.zsh-autosuggestions]
source = "github:zsh-users/zsh-autosuggestions"
enable = true

[plugins.zsh-syntax-highlighting]
source = "github:zsh-users/zsh-syntax-highlighting"
enable = true
```

### Oh My Zsh Plugins

```toml
[plugins.git]
source = "github:ohmyzsh/ohmyzsh"
path = "plugins/git"
enable = true

[plugins.docker]
source = "github:ohmyzsh/ohmyzsh"
path = "plugins/docker"
enable = true
```

### Local Plugins

```toml
[plugins.my-functions]
source = "local:$HOME/.config/zsh/functions"
enable = true

[plugins.my-aliases]
source = "local:$HOME/.config/zsh/aliases.zsh"
enable = true
```

### Plugin Dependencies

```toml
[plugins.fzf]
source = "github:junegunn/fzf"
path = "shell"
enable = true

[plugins.fzf-tab]
source = "github:Aloxaf/fzf-tab"
enable = true
depends_on = ["fzf"]
```

### Plugin Templates

```toml
[plugins.zsh-autosuggestions]
source = "github:zsh-users/zsh-autosuggestions"
enable = true
template = "defer"  # Use defer template

[templates.defer]
before = "zsh-defer source {{file}}"
```

---

## Profile-Based Configuration

### Defining Profiles

Create `~/.config/wayu/profiles/work.toml`:

```toml
# work.toml - Work-specific configuration

[settings]
profile = "work"

[path]
entries = [
    "/opt/company/bin",
    "/usr/local/company-tools",
]

[constants]
AWS_PROFILE = "work-prod"
CORPORATE_REGISTRY = "registry.company.com"

[plugins.internal-tools]
source = "git@github.com:company/shell-tools.git"
enable = true
```

Create `~/.config/wayu/profiles/personal.toml`:

```toml
# personal.toml - Personal configuration

[settings]
profile = "personal"

[plugins.personal-theme]
source = "local:$HOME/.config/zsh/personal-theme.zsh"
enable = true
```

### Activating Profiles

```bash
# Via CLI
wayu profile set work

# Via TOML (in wayu.toml)
[settings]
profile = "work"

# Via environment variable
export WAYU_PROFILE=work
```

### Profile Inheritance

```toml
# work.toml
[settings]
profile = "work"
extends = "default"  # Inherit from default profile first

[constants]
# Override/add to default constants
```

---

## Environment-Specific Settings

### Per-OS Configuration

```toml
[[settings.conditional]]
os = "macos"
shell = "zsh"
path_format = "bsd"

[[settings.conditional]]
os = "linux"
shell = "bash"
path_format = "gnu"
```

### Per-Hostname Configuration

```toml
[[settings.conditional]]
hostname = "work-laptop"
profile = "work"

[[settings.conditional]]
hostname = "gaming-rig"
profile = "gaming"
```

---

## Lock Files

### Generating Lock Files

```bash
# Generate lock file from current config
wayu lock generate

# This creates wayu.lock with exact versions
```

### Lock File Format

```toml
# wayu.lock - Generated lock file
version = "1.0"
generated_at = "2025-04-15T10:30:00Z"

[[plugin]]
name = "zsh-autosuggestions"
source = "github:zsh-users/zsh-autosuggestions"
commit = "a411ef3e0992d4839f0733ebeb6d3f52f19f5b57"
timestamp = "2025-04-10T08:00:00Z"

[[plugin]]
name = "zsh-syntax-highlighting"
source = "github:zsh-users/zsh-syntax-highlighting"
commit = "5eb494b7a27c5b1a8d865fb3bb0c7b8020a0199d"
timestamp = "2025-04-12T14:20:00Z"
```

### Using Lock Files

```bash
# Install exact versions from lock file
wayu lock install

# Update all plugins and regenerate lock
wayu lock update

# Update specific plugin
wayu lock update zsh-autosuggestions
```

### CI/CD with Lock Files

```yaml
# .github/workflows/setup.yml
- name: Setup Shell Environment
  run: |
    brew install wayu
    wayu lock install  # Reproducible setup
```

---

## CLI Integration

### Importing TOML

```bash
# Import TOML file into wayu
wayu import toml wayu.toml

# Import specific section
wayu import toml wayu.toml --section plugins
wayu import toml wayu.toml --section aliases.git
```

### Exporting to TOML

```bash
# Export current config to TOML
wayu export toml > wayu-export.toml

# Export specific sections
wayu export toml --section path
wayu export toml --section aliases
```

### Syncing TOML with Live Config

```bash
# Apply TOML changes to live config
wayu sync

# Check what would change (dry-run)
wayu sync --dry-run
```

---

## Migration from CLI to TOML

### Step 1: Export Current Config

```bash
# Export everything to TOML
wayu export toml > ~/.config/wayu/wayu.toml
```

### Step 2: Organize Your TOML

```bash
# Edit wayu.toml to add structure
# - Group aliases
# - Add comments
# - Set up profiles
# - Add conditions
```

### Step 3: Enable TOML Mode

```bash
# In wayu.toml, enable TOML processing
[settings]
use_toml = true
source_toml = true
```

### Step 4: Sync

```bash
# Apply TOML to generate shell configs
wayu sync
```

### Step 5: Update Shell RC

```bash
# Change from individual sources to:
echo 'source "$HOME/.config/wayu/init.zsh"' > ~/.zshrc
```

---

## Best Practices

### 1. Version Control Your TOML

```bash
# Create a dotfiles repo
git init ~/.dotfiles
cd ~/.dotfiles
ln -s ~/.config/wayu/wayu.toml .
git add wayu.toml
git commit -m "Add wayu config"
```

### 2. Use Local Overrides

```bash
# Machine-specific settings in wayu.local.toml (gitignored)
echo "wayu.local.toml" >> ~/.config/wayu/.gitignore
```

### 3. Lock Dependencies for Teams

```bash
# Commit lock file for reproducible setups
wayu lock generate
git add wayu.lock
git commit -m "Lock plugin versions"
```

### 4. Use Profiles for Context Switching

```bash
# Quick switch between work and personal
alias work="wayu profile set work && exec zsh"
alias home="wayu profile set personal && exec zsh"
```

### 5. Document Your Config

```toml
# wayu.toml
# ==============
# Personal shell configuration
# Maintainer: Your Name
# Last updated: 2025-04-15
#
# Sections:
#   - path: Development tool paths
#   - aliases.git: Common git shortcuts
#   - plugins: Essential Zsh plugins
```

### 6. Test Changes

```bash
# Dry-run before applying
wayu sync --dry-run

# Or use TUI for visual confirmation
wayu --tui
```

### 7. Backup Before Major Changes

```bash
# wayu creates backups automatically, but for major migrations:
cp ~/.config/wayu ~/.config/wayu.backup.$(date +%Y%m%d)
```

---

## Complete Example

```toml
# ~/.config/wayu/wayu.toml
# Complete configuration example

[settings]
shell = "zsh"
profile = "default"

[settings.backup]
enabled = true
keep_count = 10

[settings.fuzzy]
enabled = true
auto_fallback = true

# ─────────────────────────────────────────────────────────────────────────
# PATH
# ─────────────────────────────────────────────────────────────────────────

[path]
entries = [
    "/opt/homebrew/bin",
    "/opt/homebrew/sbin",
    "$HOME/.cargo/bin",
    "$HOME/.local/bin",
    "$HOME/.config/emacs/bin",
]

# macOS-specific
[[path.entry]]
path = "/Applications/Docker.app/Contents/Resources/bin"
condition = "[[ $OSTYPE == 'darwin'* ]]"

# ─────────────────────────────────────────────────────────────────────────
# Aliases
# ─────────────────────────────────────────────────────────────────────────

[aliases]
ll = "ls -la"
la = "ls -A"
lt = "ls -ltr"

[aliases.git]
g = "git"
ga = "git add"
gaa = "git add --all"
gst = "git status"
gd = "git diff"
gc = "git commit -v"
gcm = "git commit -m"
gco = "git checkout"
gl = "git pull"
gp = "git push"

# ─────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────

[constants]
EDITOR = "nvim"
VISUAL = "nvim"
PAGER = "less -R"

# ─────────────────────────────────────────────────────────────────────────
# Plugins
# ─────────────────────────────────────────────────────────────────────────

[plugins.zsh-autosuggestions]
source = "github:zsh-users/zsh-autosuggestions"
enable = true
priority = 10

[plugins.zsh-syntax-highlighting]
source = "github:zsh-users/zsh-syntax-highlighting"
enable = true
priority = 20

[plugins.fzf]
source = "github:junegunn/fzf"
path = "shell"
enable = true
priority = 30

# ─────────────────────────────────────────────────────────────────────────
# Tools
# ─────────────────────────────────────────────────────────────────────────

[tools.starship]
enable = true
command = 'eval "$(starship init zsh)"'

[tools.zoxide]
enable = true
command = 'eval "$(zoxide init zsh)"'

[tools.nvm]
enable = true
command = 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"'
condition = "[[ -s $HOME/.nvm/nvm.sh ]]"
```

---

*For more information, see [README.md](./README.md) and [MIGRATION.md](./MIGRATION.md)*
