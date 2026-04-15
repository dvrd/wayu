# Migration Guide: Moving to wayu

A comprehensive guide for migrating your shell configuration from other environment managers to wayu.

## Table of Contents

1. [Overview](#overview)
2. [Migration from Oh My Zsh (OMZ)](#migration-from-oh-my-zsh)
3. [Migration from Zinit](#migration-from-zinit)
4. [Migration from Sheldon](#migration-from-sheldon)
5. [Migration from Antidote](#migration-from-antidote)
6. [Migration from Antigen](#migration-from-antigen)
7. [Migration from Prezto](#migration-from-prezto)
8. [Manual Shell Configuration](#manual-shell-configuration)
9. [Post-Migration Checklist](#post-migration-checklist)
10. [Troubleshooting](#troubleshooting)

---

## Overview

### Why Migrate to wayu?

| Feature | wayu Advantage |
|---------|---------------|
| **Speed** | Native Odin binary (20-40ms startup) vs shell scripts (50-1200ms) |
| **Fuzzy Matching** | Smart search with acronym support (unique to wayu) |
| **TUI** | Interactive management without editing files |
| **Dual Shell** | Both Zsh and Bash support (not just Zsh) |
| **Zero Dependencies** | Single binary, no runtime requirements |
| **Backups** | Automatic before every change |
| **Dry Run** | Preview changes before applying |

### Migration Strategy

1. **Install wayu** alongside your existing setup
2. **Export** your configuration from the old manager
3. **Import** into wayu using migration scripts or manual commands
4. **Test** in a new shell session
5. **Switch** once verified

---

## Migration from Oh My Zsh

### Before You Start

Back up your current Zsh configuration:

```bash
# Backup existing config
cp ~/.zshrc ~/.zshrc.backup.pre-wayu
cp -r ~/.oh-my-zsh ~/.oh-my-zsh.backup.pre-wayu
```

### Step 1: Install wayu

```bash
# Install wayu
brew tap dvrd/wayu
brew install wayu

# Initialize
wayu init
```

### Step 2: Extract OMZ Plugins

List your current plugins:

```bash
# From your .zshrc, find the plugins=(...) line
# Common plugins to migrate:
# - git → wayu plugin add ohmyzsh/ohmyzsh path:plugins/git
# - docker → wayu plugin add ohmyzsh/ohmyzsh path:plugins/docker
# - aws → wayu plugin add ohmyzsh/ohmyzsh path:plugins/aws
```

### Step 3: Migrate Aliases

OMZ aliases are scattered across plugins. Common ones to add manually:

```bash
# Git aliases (from git plugin)
wayu alias add g 'git'
wayu alias add ga 'git add'
wayu alias add gaa 'git add --all'
wayu alias add gc 'git commit -v'
wayu alias add gcm 'git commit -m'
wayu alias add gco 'git checkout'
wayu alias add gd 'git diff'
wayu alias add gl 'git pull'
wayu alias add gp 'git push'
wayu alias add gst 'git status'

# Docker aliases (from docker plugin)
wayu alias add d 'docker'
wayu alias add dc 'docker compose'
wayu alias add dps 'docker ps'
```

### Step 4: Migrate Theme/Prompt

OMZ themes are Zsh-specific. For modern prompts:

```bash
# Option 1: Keep using OMZ theme
# Source the theme file directly in your .zshrc after wayu init

# Option 2: Switch to Starship (cross-shell, faster)
brew install starship
wayu constants add STARSHIP_CONFIG "$HOME/.config/starship.toml"
# Add to ~/.config/wayu/tools.zsh: eval "$(starship init zsh)"
```

### Step 5: Clean Up

```bash
# Comment out or remove from .zshrc:
# - export ZSH="$HOME/.oh-my-zsh"
# - source $ZSH/oh-my-zsh.sh
# - ZSH_THEME=...
# - plugins=(...)

# Add wayu initialization instead:
echo 'source "$HOME/.config/wayu/init.zsh"' >> ~/.zshrc
```

---

## Migration from Zinit

### Before You Start

```bash
# Backup
cp ~/.zshrc ~/.zshrc.backup.pre-wayu
cp -r ~/.local/share/zinit ~/.local/share/zinit.backup
```

### Step 1: Extract Plugin List

From your `.zshrc`, extract all `zinit load`, `zinit light`, and `zinit snippet` commands:

```bash
# Example Zinit config:
# zinit light zsh-users/zsh-autosuggestions
# zinit light zsh-users/zsh-syntax-highlighting
# zinit snippet OMZ::plugins/git

# Convert to wayu:
wayu plugin add zsh-users/zsh-autosuggestions
wayu plugin add zsh-users/zsh-syntax-highlighting
wayu plugin add ohmyzsh/ohmyzsh path:plugins/git
```

### Step 2: Handle Turbo Mode

Zinit Turbo provides lazy loading. wayu uses a different approach:

```bash
# In Zinit:
# zinit ice wait lucid
# zinit light zsh-users/zsh-autosuggestions

# In wayu:
# Plugins are loaded via generated init script
# For true lazy loading, use zsh-defer in tools.zsh

# Add to ~/.config/wayu/tools.zsh:
# zsh-defer source ~/.config/wayu/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
```

### Step 3: Migrate Ice Modifiers

| Zinit Ice | wayu Equivalent |
|-----------|-----------------|
| `wait` | Manual defer in tools.zsh |
| `lucid` | No output suppression needed |
| `atload` | Add to tools.zsh |
| `pick` | wayu plugin add with path |
| `as"completion"` | wayu completions add |

### Step 4: Clean Up

```bash
# Remove from .zshrc:
# - ZINIT_HOME setup
# - zinit load/light/snippet commands
# - zinit ice commands

# Add wayu:
echo 'source "$HOME/.config/wayu/init.zsh"' >> ~/.zshrc
```

---

## Migration from Sheldon

### Before You Start

```bash
# Backup
cp ~/.config/sheldon/plugins.toml ~/.config/sheldon/plugins.toml.backup
cp ~/.zshrc ~/.zshrc.backup.pre-wayu
```

### Step 1: Convert TOML to wayu Commands

Read your `~/.config/sheldon/plugins.toml`:

```toml
# Sheldon config example:
[plugins.zsh-autosuggestions]
github = "zsh-users/zsh-autosuggestions"

[plugins.zsh-syntax-highlighting]
github = "zsh-users/zsh-syntax-highlighting"

[plugins.my-local]
local = "~/dotfiles/plugins/my-plugin"
```

Convert to wayu:

```bash
# GitHub plugins
wayu plugin add zsh-users/zsh-autosuggestions
wayu plugin add zsh-users/zsh-syntax-highlighting

# Local plugins
wayu plugin add ~/dotfiles/plugins/my-plugin
```

### Step 2: Handle Profiles

Sheldon profiles can be replicated with shell detection:

```bash
# In Sheldon:
# profiles = ["work"]

# In wayu (add to ~/.config/wayu/tools.zsh):
# if [[ "$(hostname)" == "work-machine" ]]; then
#     source ~/.config/wayu/plugins/work-specific/init.zsh
# fi
```

### Step 3: Convert Templates

| Sheldon Template | wayu Equivalent |
|------------------|-----------------|
| `{{ file }}` | Direct source |
| `defer` template | Add to tools.zsh with zsh-defer |
| `inline` | wayu constants/alias add |

### Step 4: Clean Up

```bash
# Remove from .zshrc:
# - eval "$(sheldon source)"

# Add wayu:
echo 'source "$HOME/.config/wayu/init.zsh"' >> ~/.zshrc
```

---

## Migration from Antidote

### Before You Start

```bash
# Backup
cp ~/.zsh_plugins.txt ~/.zsh_plugins.txt.backup
cp ~/.zshrc ~/.zshrc.backup.pre-wayu
```

### Step 1: Convert Plugin List

Your `.zsh_plugins.txt` contains one plugin per line:

```bash
# Example .zsh_plugins.txt:
# zsh-users/zsh-autosuggestions
# zsh-users/zsh-syntax-highlighting kind:defer
# ohmyzsh/ohmyzsh path:plugins/git
# $HOME/.my-custom-plugin

# Convert to wayu:
wayu plugin add zsh-users/zsh-autosuggestions
wayu plugin add zsh-users/zsh-syntax-highlighting
wayu plugin add ohmyzsh/ohmyzsh path:plugins/git
wayu plugin add ~/.my-custom-plugin
```

### Step 2: Handle Static Loading

Antidote generates a static `.zsh` file. wayu generates config dynamically:

```bash
# Antidote approach:
# Static file regenerated when plugins change

# wayu approach:
# Init script sources plugins dynamically
# For static-like performance, wayu's Odin binary is already fast enough
```

### Step 3: Handle kind:defer

```bash
# Antidote:
# zsh-users/zsh-autosuggestions kind:defer

# wayu: Add to tools.zsh with zsh-defer
# Install zsh-defer first if needed
```

### Step 4: Clean Up

```bash
# Remove from .zshrc:
# - source ${ZDOTDIR:-~}/.antidote/antidote.zsh
# - antidote load
# - zsh_plugins file reference

# Add wayu:
echo 'source "$HOME/.config/wayu/init.zsh"' >> ~/.zshrc
```

---

## Migration from Antigen

### Before You Start

```bash
cp ~/.zshrc ~/.zshrc.backup.pre-wayu
```

### Step 1: Convert antigen Commands

```bash
# Example Antigen config:
# source /usr/share/antigen/antigen.zsh
# antigen use oh-my-zsh
# antigen bundle git
# antigen bundle zsh-users/zsh-autosuggestions
# antigen apply

# Convert to wayu:
wayu init
wayu plugin add ohmyzsh/ohmyzsh path:plugins/git
wayu plugin add zsh-users/zsh-autosuggestions
```

### Step 2: Clean Up

```bash
# Remove all antigen-related lines from .zshrc
# Add wayu source line
echo 'source "$HOME/.config/wayu/init.zsh"' >> ~/.zshrc
```

---

## Migration from Prezto

### Before You Start

```bash
cp ~/.zshrc ~/.zshrc.backup.pre-wayu
cp -r ~/.zprezto ~/.zprezto.backup
```

### Step 1: Identify Modules

Prezto modules map to wayu plugins:

| Prezto Module | wayu Equivalent |
|--------------|-----------------|
| `git` | wayu plugin add ohmyzsh/ohmyzsh path:plugins/git |
| `docker` | wayu plugin add ohmyzsh/ohmyzsh path:plugins/docker |
| `syntax-highlighting` | wayu plugin add zsh-users/zsh-syntax-highlighting |
| `autosuggestions` | wayu plugin add zsh-users/zsh-autosuggestions |

### Step 2: Migrate Prompt

```bash
# Prezto themes are Zsh-specific
# Consider switching to Starship or keep using Prezto's prompt

# To keep Prezto prompt:
# Add to ~/.config/wayu/tools.zsh:
# autoload -Uz promptinit && promptinit
# prompt pure  # or your preferred prompt
```

### Step 3: Clean Up

```bash
# Remove from .zshrc:
# - source "${ZDOTDIR:-$HOME}/.zprezto/init.zsh"

# Add wayu:
echo 'source "$HOME/.config/wayu/init.zsh"' >> ~/.zshrc
```

---

## Manual Shell Configuration

If you're not using a manager currently, migrate from manual .zshrc/.bashrc:

### Extract PATH Entries

```bash
# From your .zshrc or .bashrc, find all PATH modifications:
# export PATH="/usr/local/bin:$PATH"
# export PATH="$HOME/.cargo/bin:$PATH"

# Add to wayu:
wayu path add /usr/local/bin
wayu path add ~/.cargo/bin
```

### Extract Aliases

```bash
# Find all alias definitions:
# alias ll='ls -la'
# alias g='git'

# Add to wayu:
wayu alias add ll 'ls -la'
wayu alias add g 'git'
```

### Extract Environment Variables

```bash
# Find export statements:
# export EDITOR=nvim
# export FZF_DEFAULT_OPTS='--height 40%'

# Add to wayu:
wayu constants add EDITOR nvim
wayu constants add FZF_DEFAULT_OPTS '--height 40%'
```

### Extract Completions

```bash
# Find fpath modifications and compinit:
# fpath+=~/.zsh/completions

# Add to wayu:
wayu completions add ~/.zsh/completions/_mycompletion
```

---

## Post-Migration Checklist

- [ ] wayu init completed successfully
- [ ] All PATH entries migrated (check with `wayu path list`)
- [ ] All aliases migrated (check with `wayu alias list`)
- [ ] All environment variables migrated (check with `wayu constants list`)
- [ ] Plugins installed (check with `wayu plugin list`)
- [ ] Shell starts without errors
- [ ] TUI works: `wayu --tui`
- [ ] Fuzzy search works: `wayu search <term>`
- [ ] Backups created (modify something, check `wayu backup list`)
- [ ] Old manager references removed from .zshrc/.bashrc
- [ ] New shell sessions work correctly

---

## Troubleshooting

### Issue: Shell starts slowly after migration

**Cause**: Both old and new manager may be active.

**Solution**:
```bash
# Check if multiple managers are loaded
grep -E "(source|\.).*(init|antigen|sheldon|zinit|oh-my-zsh)" ~/.zshrc

# Remove old manager lines
# Keep only: source "$HOME/.config/wayu/init.zsh"
```

### Issue: PATH order is wrong

**Cause**: Old manager may be modifying PATH after wayu.

**Solution**:
```bash
# Check PATH
echo $PATH | tr ':' '\n'

# Reorder in wayu:
wayu path rm /wrong/order/path
wayu path add /correct/order/path
```

### Issue: Plugins not loading

**Cause**: wayu plugins directory not sourced correctly.

**Solution**:
```bash
# Verify plugins are enabled
wayu plugin list

# Check init.zsh sources plugins
head ~/.config/wayu/init.zsh

# Re-enable if needed
wayu plugin enable <plugin-name>
```

### Issue: Fuzzy search not finding items

**Cause**: Data not in wayu config.

**Solution**:
```bash
# Verify items are in wayu
wayu path list
wayu alias list
wayu constants list

# Add missing items
```

### Issue: Shell functions not working

**Cause**: Functions are not migrated by wayu (currently limited support).

**Solution**:
```bash
# Add custom functions to ~/.config/wayu/functions.zsh
# Or keep them in .zshrc after wayu init
```

---

## Getting Help

- **Documentation**: Read [README.md](./README.md) and [TOML_GUIDE.md](./TOML_GUIDE.md)
- **CLI Help**: `wayu help` or `wayu <command> help`
- **TUI**: `wayu --tui` for interactive management
- **Issues**: Report at https://github.com/dvrd/wayu/issues

---

*Last updated: 2025-04*
