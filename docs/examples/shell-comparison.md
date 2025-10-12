# Shell Comparison: Bash vs ZSH with wayu

This guide compares how wayu works with Bash and ZSH, highlighting the differences and optimizations for each shell.

## Quick Comparison

| Feature | Bash | ZSH | Notes |
|---------|------|-----|-------|
| **File Extensions** | `.bash` | `.zsh` | Automatic shell detection |
| **PATH Deduplication** | Array-based loops | `awk` + `sed` | ZSH method is more concise |
| **Variable Scoping** | `local` declarations | Implicit local in functions | Bash is more explicit |
| **RC File** | `.bashrc`/`.bash_profile` | `.zshrc` | System-dependent for Bash |
| **Shebang** | `#!/usr/bin/env bash` | `#!/usr/bin/env zsh` | Shell-specific interpreters |
| **History** | Basic settings | Advanced options | ZSH has more features |
| **Completions** | Basic | Advanced | ZSH has richer completion system |

## Template Differences

### PATH Management

**Bash Version** (`path.bash`):
```bash
#!/usr/bin/env bash

add_to_path() {
    local dir="$1"
    local position="${2:-prepend}"

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

add_to_path "/usr/local/bin"
remove_path_duplicates
```

**ZSH Version** (`path.zsh`):
```zsh
#!/usr/bin/env zsh

add_to_path() {
    local dir="$1"
    local position="${2:-prepend}"

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

add_to_path "/usr/local/bin"

# Remove duplicates from PATH (ZSH-optimized method)
export PATH=$(echo "$PATH" | awk -v RS=':' -v ORS=':' '!seen[$0]++' | sed 's/:$//')
```

**Key Differences:**
- **Bash**: Uses arrays and explicit loops for deduplication
- **ZSH**: Uses `awk` one-liner for more concise deduplication
- **Bash**: More verbose but compatible with strict POSIX compliance
- **ZSH**: Leverages advanced shell features for brevity

### Tools Integration

**Bash Version** (`tools.bash`):
```bash
#!/usr/bin/env bash

# External Tool Integration for Bash

# NVM (Node Version Manager)
export NVM_DIR="$HOME/.nvm"
if [ -s "$NVM_DIR/nvm.sh" ]; then
    source "$NVM_DIR/nvm.sh"
fi
if [ -s "$NVM_DIR/bash_completion" ]; then
    source "$NVM_DIR/bash_completion"
fi

# Starship Prompt (Cross-shell)
if command -v starship &> /dev/null; then
    eval "$(starship init bash)"
fi

# Zoxide (Better cd)
if command -v zoxide &> /dev/null; then
    eval "$(zoxide init bash)"
fi

# Homebrew (macOS)
if [ -f "/opt/homebrew/bin/brew" ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi
```

**ZSH Version** (`tools.zsh`):
```zsh
#!/usr/bin/env zsh

# External Tool Integration for ZSH

# NVM (Node Version Manager)
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && source "$NVM_DIR/bash_completion"

# Starship Prompt (Cross-shell)
if command -v starship &> /dev/null; then
    eval "$(starship init zsh)"
fi

# Zoxide (Better cd)
if command -v zoxide &> /dev/null; then
    eval "$(zoxide init zsh)"
fi

# Homebrew (macOS)
if [ -f "/opt/homebrew/bin/brew" ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# ZSH-specific completions
if type brew &>/dev/null; then
    FPATH=$(brew --prefix)/share/zsh-completions:$FPATH
    autoload -Uz compinit
    compinit
fi
```

**Key Differences:**
- **Both**: Very similar for most tools
- **ZSH**: Includes completion system setup
- **ZSH**: Can leverage more advanced completion features

## Command Equivalence

All wayu commands work identically across both shells:

```bash
# These commands work the same in both Bash and ZSH
wayu init
wayu path add /usr/local/bin
wayu alias add ll "ls -la"
wayu constants add MY_VAR "value"
wayu path list
```

The only difference is the file extensions used internally:
- **Bash**: Modifies `.bash` files
- **ZSH**: Modifies `.zsh` files

## Shell-Specific Features

### ZSH Advantages

1. **Advanced Completions**:
   ```zsh
   # ZSH has more sophisticated completion
   git <TAB>  # Shows git subcommands with descriptions
   ssh <TAB>  # Completes from ~/.ssh/config
   ```

2. **Globbing**:
   ```zsh
   # ZSH has extended globbing
   ls **/*.txt  # Recursive search
   ls *.txt~README.txt  # Exclude pattern
   ```

3. **History Features**:
   ```zsh
   # Better history search and sharing
   setopt HIST_IGNORE_DUPS
   setopt SHARE_HISTORY
   ```

### Bash Advantages

1. **Universal Compatibility**:
   ```bash
   # Works on virtually every Unix system
   # Default shell on most Linux distributions
   ```

2. **Strict Standards Compliance**:
   ```bash
   # Better for scripting that needs to be portable
   # More predictable behavior across systems
   ```

3. **Enterprise Support**:
   ```bash
   # Often required in corporate environments
   # Better documentation for system administration
   ```

## Performance Comparison

### Startup Time
- **Bash**: Generally faster startup
- **ZSH**: Slightly slower due to more features

### Memory Usage
- **Bash**: Lower memory footprint
- **ZSH**: Higher due to advanced features

### Feature Richness
- **Bash**: Focused on scripting and compatibility
- **ZSH**: Rich interactive features

## Migration Between Shells

### From ZSH to Bash
```bash
# 1. Create Bash config
wayu --shell bash init

# 2. Your ZSH files remain unchanged
ls ~/.config/wayu/
# Shows both .zsh and .bash files

# 3. Switch to Bash and test
chsh -s /bin/bash
# Or just: SHELL=/bin/bash wayu path list
```

### From Bash to ZSH
```zsh
# 1. Create ZSH config
wayu --shell zsh init

# 2. Your Bash files remain unchanged
ls ~/.config/wayu/
# Shows both .bash and .zsh files

# 3. Switch to ZSH and test
chsh -s /bin/zsh
# Or just: SHELL=/bin/zsh wayu path list
```

## Mixed Environment Usage

### Scenario: Development Machine (ZSH) + Production Server (Bash)

**Development setup**:
```zsh
# On your local machine (ZSH)
wayu --shell zsh init
wayu path add ~/.local/bin
wayu alias add deploy "ssh production"
```

**Production setup**:
```bash
# On production server (Bash)
wayu --shell bash init
wayu path add /opt/app/bin
wayu alias add logs "tail -f /var/log/app.log"
```

**Shared config strategy**:
```bash
# Create a shared config repository
mkdir ~/dotfiles/wayu-shared
echo 'wayu path add ~/.local/bin' > ~/dotfiles/wayu-shared/common-paths.sh
echo 'wayu alias add ll "ls -la"' > ~/dotfiles/wayu-shared/common-aliases.sh

# Apply shared config on both systems
source ~/dotfiles/wayu-shared/common-paths.sh
source ~/dotfiles/wayu-shared/common-aliases.sh
```

## Best Practices by Shell

### Bash Best Practices
1. **Use explicit local variables**:
   ```bash
   my_function() {
       local var="value"  # Always use local
   }
   ```

2. **Prefer arrays for complex data**:
   ```bash
   paths=("/usr/local/bin" "/opt/bin")
   for path in "${paths[@]}"; do
       wayu path add "$path"
   done
   ```

3. **Use explicit error checking**:
   ```bash
   if ! command -v git &> /dev/null; then
       echo "Git not found"
       exit 1
   fi
   ```

### ZSH Best Practices
1. **Leverage advanced globbing**:
   ```zsh
   # Find all .js files except node_modules
   ls **/*.js~**/node_modules/*
   ```

2. **Use ZSH-specific features**:
   ```zsh
   # Parameter expansion
   files=(*.txt)
   echo ${#files}  # Count of files
   ```

3. **Configure completion system**:
   ```zsh
   autoload -Uz compinit
   compinit
   zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
   ```

## Troubleshooting Shell-Specific Issues

### Bash Issues
1. **Array syntax differences**:
   ```bash
   # Bash requires specific array syntax
   arr=("one" "two" "three")
   echo "${arr[@]}"  # Correct
   echo "$arr"       # Only shows first element
   ```

2. **Function local variables**:
   ```bash
   # Always declare local variables
   my_func() {
       local name="$1"  # Without local, it's global
   }
   ```

### ZSH Issues
1. **Array indexing differences**:
   ```zsh
   # ZSH arrays start at 1, not 0
   arr=(one two three)
   echo $arr[1]  # "one" in ZSH, would be $arr[0] in Bash
   ```

2. **Globbing differences**:
   ```zsh
   # ZSH enables extended globbing by default
   ls *.txt  # May behave differently than Bash
   ```

## Summary

Both shells work excellently with wayu:

- **Choose Bash** for maximum compatibility, enterprise environments, or when writing portable scripts
- **Choose ZSH** for rich interactive features, advanced completions, or when you want a more modern shell experience
- **Use both** if you work across different environments

wayu automatically handles the differences, so you can focus on your work rather than shell compatibility issues.