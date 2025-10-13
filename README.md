# wayu

A shell configuration management CLI written in Odin that helps you manage PATH entries, aliases, and environment constants across **both Bash and ZSH environments**.

## Features

- **Multi-Shell Support** - Works seamlessly with Bash and ZSH with automatic shell detection
- **PATH Management** - Add, remove, and list PATH entries with shell-optimized duplicate detection
- **Alias Management** - Manage shell aliases with interactive removal
- **Constants Management** - Handle environment variables and constants
- **Interactive Mode** - Fuzzy search for removing entries
- **Modern UI Components** - Tables, progress bars, spinners, and styled output
- **Theme System** - Light and dark themes with automatic terminal detection
- **Backward Compatible** - Existing ZSH configurations work unchanged
- **Shell-Specific Templates** - Optimized configuration templates for each shell
- **Zero Dependencies** - Written in Odin for fast compilation and execution

## Installation

### Prerequisites

- [Odin compiler](https://odin-lang.org/docs/install/)
- [Task](https://taskfile.dev/) (optional, for using the Taskfile)

### Build & Install

```bash
# Build and install
task install

# Setup configuration directory
wayu init
```

Or manually:

```bash
# Build
odin build src -out:bin/wayu -o:speed

# Install
cp bin/wayu /usr/local/bin/wayu
chmod +x /usr/local/bin/wayu
wayu init
```

## Usage

```
wayu <command> <action> [arguments]
```

### Commands

- `path` - Manage PATH entries
- `alias` - Manage shell aliases
- `constants` - Manage environment constants
- `completions` - Manage shell completion scripts
- `backup` - Manage configuration backups
- `init` - Initialize wayu configuration
- `migrate` - Migrate configuration between shells
- `version` - Show version information
- `help` - Show help message

### Actions

- `add` - Add a new entry
- `remove`, `rm` - Remove an entry (interactive if no args provided)
- `list`, `ls` - List all entries
- `restore` - Restore from backup (backup command only)
- `help` - Show command-specific help

### Flags

- `--shell <bash|zsh>` - Override shell detection
- `--dry-run`, `-n` - Preview changes without modifying files
- `--from <shell>` - Source shell for migration (migrate command only)
- `--to <shell>` - Target shell for migration (migrate command only)
- `-v`, `--version` - Show version information

### Examples

```bash
# Basic usage (automatic shell detection)
wayu init                        # Creates shell-appropriate config files
wayu path add /usr/local/bin     # Adds to path.zsh or path.bash automatically
wayu path list                   # Shows current PATH entries

# PATH management
wayu path add /usr/local/bin     # Add specific path
wayu path add                    # Uses current directory
wayu path rm                     # Interactive removal
wayu path list                   # List all entries

# Alias management
wayu alias add ll 'ls -la'       # Add alias
wayu alias add gs 'git status'   # Git shortcut
wayu alias rm                    # Interactive removal
wayu alias list                  # List all aliases

# Constants management
wayu constants add MY_VAR value  # Add environment variable
wayu constants add API_KEY token # Add secret
wayu constants rm                # Interactive removal
wayu constants list              # List all constants

# Completions management
wayu completions add jj /path/to/_jj  # Add completion script
wayu completions rm               # Interactive removal
wayu completions list             # List all completions

# Backup management
wayu backup list                  # Show all backups
wayu backup restore path         # Restore path config from backup
wayu backup restore alias        # Restore alias config from backup

# Shell migration
wayu migrate --from zsh --to bash    # Migrate ZSH config to Bash
wayu migrate --from bash --to zsh    # Migrate Bash config to ZSH

# Version information
wayu version                      # Show version
wayu -v                          # Short version flag

# Multi-shell usage
wayu --shell bash init           # Force Bash configuration
wayu --shell zsh path add /bin   # Force ZSH mode for this command
wayu --dry-run path add /test    # Preview changes without applying

# Cross-shell compatibility
SHELL=/bin/bash wayu path add /usr/local/bin  # Use with specific shell
SHELL=/bin/zsh wayu alias add gc 'git commit' # ZSH-specific alias
```

## Configuration

wayu automatically creates shell-specific configuration files in `~/.config/wayu/`:

### For ZSH users:
- `path.zsh` - PATH entries
- `aliases.zsh` - Shell aliases
- `constants.zsh` - Environment constants
- `init.zsh` - Main orchestrator file
- `tools.zsh` - External tool integration

### For Bash users:
- `path.bash` - PATH entries (Bash-optimized)
- `aliases.bash` - Shell aliases
- `constants.bash` - Environment constants
- `init.bash` - Main orchestrator file
- `tools.bash` - External tool integration

### Automatic Shell Detection
wayu detects your shell automatically and uses the appropriate file extensions. Existing ZSH users can continue using `.zsh` files unchanged.

### Mixed Usage
If you use both shells, wayu maintains separate config files for each shell, allowing you to have shell-specific configurations while sharing common patterns.

## Migration from v1.x

**Existing ZSH users**: No action required! Your `.zsh` files continue to work unchanged.

**New Bash users**: Simply run `wayu init` and it will detect your shell automatically.

**Switching shells**: See the comprehensive [Migration Guide](docs/MIGRATION.md) for detailed instructions on switching between shells or using both.

## Development

```bash
# Build for production
task build

# Build with debug info
task debug

# Run tests
task test

# Check code
task check

# Development workflow
task dev -- path list
```

## UI & Styling

wayu v2.1.0 includes a modern style system inspired by Charm's CLI ecosystem:

### Visual Components

- **Tables** - Formatted tables with borders for listing PATH entries, aliases, and constants
- **Progress Bars** - Visual feedback for long-running operations
- **Spinners** - Loading indicators with multiple animation styles
- **Styled Output** - Color-coded messages (success, error, warning, info)

### Theme System

wayu automatically detects your terminal's color scheme and applies appropriate themes:

- **Dark Mode** (default) - Optimized for dark terminal backgrounds
- **Light Mode** - Optimized for light terminal backgrounds
- **Auto Detection** - Automatically selects theme based on terminal settings

The theme system uses a comprehensive color palette with variants for primary, secondary, accent, success, error, warning, and info colors.

### Configuration

Control the visual output with environment variables:

```bash
# Disable all colors (accessibility mode)
NO_COLOR=1 wayu path list

# Force plain output (no fancy UI components)
WAYU_PLAIN=1 wayu alias list

# The style system automatically:
# - Detects terminal capabilities (ANSI, 256-color, TrueColor)
# - Falls back gracefully on limited terminals
# - Respects NO_COLOR environment variable
# - Works with screen readers and accessibility tools
```

## License

MIT
