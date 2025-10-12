# Migrating to Multi-Shell Wayu v2.0.0

Wayu v2.0.0 introduces full Bash compatibility alongside existing ZSH support. This guide covers migration strategies and usage patterns for the new multi-shell functionality.

## 🎯 Quick Start

### For New Users
```bash
# Wayu automatically detects your shell and sets up appropriate config files
wayu init

# That's it! Your shell is detected automatically
```

### For Existing ZSH Users
**Good news: No action required!** Your existing `.zsh` config files will continue to work seamlessly.

## 📋 What's New in v2.0.0

- **Automatic Shell Detection**: Detects Bash vs ZSH automatically
- **Shell-Specific Templates**: Optimized templates for each shell's features
- **Backward Compatibility**: Existing `.zsh` files work unchanged
- **Cross-Shell Configuration**: Switch shells without losing your setup
- **Improved Performance**: Shell-optimized PATH management and aliases

## 🔄 Migration Scenarios

### Scenario 1: Keep Using ZSH (Recommended)
**Action Required**: None

Your existing workflow continues unchanged:
```bash
wayu path add /usr/local/bin    # Still works exactly the same
wayu alias add ll "ls -la"      # Still modifies your .zsh files
wayu constants list             # Still reads from .zsh files
```

### Scenario 2: Switch to Bash
If you want to switch from ZSH to Bash:

1. **Backup your current setup**:
   ```bash
   cp -r ~/.config/wayu ~/.config/wayu.backup
   ```

2. **Initialize for Bash**:
   ```bash
   # Tell wayu to use Bash explicitly
   SHELL=/bin/bash wayu --shell bash init
   ```

3. **Your old .zsh files remain as backup**. The new Bash setup will:
   - Create new `.bash` config files with appropriate templates
   - Preserve your existing `.zsh` files unchanged
   - Allow you to manually migrate settings if desired

### Scenario 3: Using Both Shells
If you use both Bash and ZSH on different systems:

1. **Initialize for both shells**:
   ```bash
   # On systems where you use Bash
   wayu --shell bash init

   # On systems where you use ZSH
   wayu --shell zsh init
   ```

2. **Your configuration will automatically use the right files** based on your current shell.

## 🛠️ Shell-Specific Features

### Bash Templates
New Bash configurations include:
- **Bash-compatible PATH deduplication**: Using arrays and loops
- **Proper variable scoping**: `local` declarations for function variables
- **Bash-specific shebang**: `#!/usr/bin/env bash`
- **Compatible syntax**: Avoids ZSH-specific features

### ZSH Templates (Enhanced)
ZSH configurations have been updated with:
- **Optimized PATH management**: Using `awk` and `sed` for deduplication
- **ZSH-specific features**: Where beneficial for performance
- **ZSH-specific shebang**: `#!/usr/bin/env zsh`

## 📁 File Structure Changes

### Before v2.0.0 (ZSH Only)
```
~/.config/wayu/
├── path.zsh
├── aliases.zsh
├── constants.zsh
├── init.zsh
└── tools.zsh
```

### After v2.0.0 (Multi-Shell)
Your file structure depends on your shell:

**For ZSH users (no change)**:
```
~/.config/wayu/
├── path.zsh      # Still used
├── aliases.zsh   # Still used
├── constants.zsh # Still used
├── init.zsh      # Still used
└── tools.zsh     # Still used
```

**For Bash users (new)**:
```
~/.config/wayu/
├── path.bash     # New Bash-optimized version
├── aliases.bash  # New Bash-compatible version
├── constants.bash # New Bash-compatible version
├── init.bash     # New Bash orchestrator
└── tools.bash    # New Bash tool integration
```

**For mixed usage**:
```
~/.config/wayu/
├── path.zsh      # Used when SHELL=zsh
├── path.bash     # Used when SHELL=bash
├── aliases.zsh   # ZSH aliases
├── aliases.bash  # Bash aliases
├── constants.zsh # ZSH constants
├── constants.bash # Bash constants
├── init.zsh      # ZSH orchestrator
├── init.bash     # Bash orchestrator
├── tools.zsh     # ZSH tools
└── tools.bash    # Bash tools
```

## 🔧 Advanced Usage

### Force a Specific Shell
You can override shell detection:
```bash
# Force Bash mode even if using ZSH
wayu --shell bash path add /usr/local/bin

# Force ZSH mode even if using Bash
wayu --shell zsh alias add gc "git commit"
```

### Dry Run Mode
Preview changes before applying them:
```bash
# See what would be modified (shell-aware)
wayu --dry-run path add /new/path
wayu --dry-run --shell bash constants add MY_VAR "value"
```

### Shell Detection Info
Check what shell wayu detects:
```bash
# The init command shows detected shell
wayu init
# Output: "Detected shell: Bash" or "Detected shell: ZSH"
```

## 🚨 Troubleshooting

### Shell Not Detected Correctly
If wayu doesn't detect your shell correctly:
```bash
# Check your SHELL environment variable
echo $SHELL

# Override detection explicitly
wayu --shell bash init  # or --shell zsh
```

### Mixed Configuration Files
If you have both `.bash` and `.zsh` files, wayu will:
1. **Prefer shell-specific files** (e.g., `path.bash` when using Bash)
2. **Fall back to `.zsh` files** if shell-specific files don't exist
3. **Never create empty shell-specific files** if fallback files exist

### RC File Integration
Wayu will suggest the correct RC file for your shell:
- **Bash**: `.bashrc` or `.bash_profile` (system-dependent)
- **ZSH**: `.zshrc`

### Migration Not Working
If you encounter issues:
1. **Backup first**: `cp -r ~/.config/wayu ~/.config/wayu.backup`
2. **Check permissions**: Ensure wayu can read/write config files
3. **Reset if needed**: Remove `~/.config/wayu` and run `wayu init`
4. **Force shell**: Use `--shell bash` or `--shell zsh` explicitly

## 📚 Examples

### Example 1: New Bash User
```bash
$ echo $SHELL
/bin/bash

$ wayu init
Detected shell: Bash
Using shell: Bash (config files will use .bash extension)
Created directory: /home/user/.config/wayu
Created config file: /home/user/.config/wayu/path.bash
Created config file: /home/user/.config/wayu/aliases.bash
# ... etc

$ wayu path add /usr/local/bin
Path added successfully: /usr/local/bin

$ wayu path list
🗂️  Current PATH entries:
  /usr/local/bin
```

### Example 2: Existing ZSH User
```bash
$ echo $SHELL
/bin/zsh

$ wayu path list  # Works with existing .zsh files
🗂️  Current PATH entries:
  /usr/local/bin
  /opt/homebrew/bin

$ wayu --shell bash init  # Create Bash config too
Detected shell: ZSH (but using Bash due to --shell flag)
Using shell: Bash (config files will use .bash extension)
# Creates .bash files alongside existing .zsh files
```

### Example 3: Cross-Shell Migration
```bash
# On ZSH system, export your current paths
$ SHELL=/bin/zsh wayu path list > my-paths.txt

# On Bash system, review and add them
$ cat my-paths.txt
$ SHELL=/bin/bash wayu --shell bash path add /usr/local/bin
$ SHELL=/bin/bash wayu --shell bash path add /opt/homebrew/bin
```

## 🎉 Benefits of Multi-Shell Support

### For Individual Users
- **Freedom of Choice**: Use your preferred shell without changing tools
- **Easy Migration**: Switch shells without losing your configuration
- **Learning Opportunity**: See best practices for both shells
- **System Compatibility**: Same tool works on Ubuntu (Bash) and macOS (ZSH)

### For Teams & Organizations
- **Standardization**: Everyone uses wayu regardless of shell preference
- **Onboarding**: New team members can use their preferred shell
- **Documentation**: Shell-specific examples for different audiences
- **CI/CD Integration**: Works in both Bash and ZSH environments

## 🔮 Future Compatibility

This multi-shell foundation enables future support for:
- **Fish shell**: Community-requested shell support
- **PowerShell**: Windows/cross-platform compatibility
- **Custom shells**: Extensible architecture for new shells

---

## Need Help?

- **Issues**: Report bugs at [wayu GitHub Issues](https://github.com/user/wayu/issues)
- **Discussions**: Join conversations in [GitHub Discussions](https://github.com/user/wayu/discussions)
- **Documentation**: See the full documentation in `docs/`

**Migration successful?** Consider starring the project and sharing your experience!