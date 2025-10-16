# wayu

A shell configuration management CLI written in Odin that helps you manage PATH entries, aliases, and environment constants across **both Bash and ZSH environments**.

## Features

- **Multi-Shell Support** - Works seamlessly with Bash and ZSH with automatic shell detection
- **PATH Management** - Add, remove, and list PATH entries with shell-optimized duplicate detection
- **Alias Management** - Manage shell aliases with validation
- **Constants Management** - Handle environment variables and constants
- **Dual Modes** - Non-interactive CLI for automation + Interactive TUI for humans
- **Scriptable** - Fully non-interactive CLI with proper exit codes for CI/CD
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

- `add` - Add a new entry (requires explicit arguments)
- `remove`, `rm` - Remove an entry (requires explicit name)
- `list`, `ls` - List all entries (static table output)
- `restore` - Restore from backup (backup command only)
- `clean` - Remove missing directories from PATH (requires --yes)
- `dedup` - Remove duplicate PATH entries (requires --yes)
- `help` - Show command-specific help

### Flags

- `--shell <bash|zsh>` - Override shell detection
- `--dry-run`, `-n` - Preview changes without modifying files
- `--yes`, `-y` - Skip confirmation prompts (for clean/dedup operations)
- `--tui` - Launch interactive Terminal UI mode
- `-c=<component>` - Test individual TUI component (developer mode)
- `--snapshot` - Create golden file for component testing
- `--test` - Verify component output against golden file
- `--from <shell>` - Source shell for migration (migrate command only)
- `--to <shell>` - Target shell for migration (migrate command only)
- `-v`, `--version` - Show version information

### Examples

```bash
# Basic usage (automatic shell detection)
wayu init                        # Creates shell-appropriate config files
wayu path add /usr/local/bin     # Adds to path.zsh or path.bash automatically
wayu path list                   # Shows current PATH entries

# PATH management (CLI - requires explicit arguments)
wayu path add /usr/local/bin     # Add specific path
wayu path add /bin               # Add another path
wayu path rm /usr/local/bin      # Remove specific path (explicit name required)
wayu path list                   # List all entries (static table)
wayu path clean --yes            # Remove missing directories
wayu path dedup --yes            # Remove duplicates

# Alias management (CLI - requires explicit arguments)
wayu alias add ll 'ls -la'       # Add alias
wayu alias add gs 'git status'   # Git shortcut
wayu alias rm ll                 # Remove specific alias (explicit name required)
wayu alias list                  # List all aliases (static table)

# Constants management (CLI - requires explicit arguments)
wayu constants add MY_VAR value  # Add environment variable
wayu constants add API_KEY token # Add secret
wayu constants rm MY_VAR         # Remove specific constant (explicit name required)
wayu constants list              # List all constants (static table)

# Completions management (CLI - requires explicit arguments)
wayu completions add jj /path/to/_jj  # Add completion script
wayu completions rm jj            # Remove specific completion (explicit name required)
wayu completions list             # List all completions

# Interactive mode - use --tui flag for fuzzy finding and visual selection
wayu --tui                        # Launch full TUI for interactive management

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

# Scripting & automation (CLI is fully non-interactive)
wayu path add /new/path || echo "Failed with exit code $?"
wayu path clean --yes --dry-run  # Preview what would be removed
wayu path clean --yes            # Actually remove missing directories

# CI/CD integration
if ! wayu path add /app/bin; then
  echo "Failed to add path" >&2
  exit 1
fi
```

## Exit Codes

wayu uses BSD sysexits.h standard exit codes for scripting and automation:

| Code | Meaning | Description |
|------|---------|-------------|
| 0 | Success | Command completed successfully |
| 1 | General error | Unspecified error occurred |
| 64 | Usage error | Invalid command line arguments |
| 65 | Data format error | Invalid input data format |
| 66 | Input not found | Required input file not found |
| 73 | Cannot create | Cannot create output file |
| 74 | I/O error | File read/write operation failed |
| 77 | Permission denied | Insufficient permissions |
| 78 | Configuration error | Configuration not initialized or invalid |

**Example:**
```bash
#!/bin/bash
wayu path add /usr/local/bin
EXIT_CODE=$?

case $EXIT_CODE in
  0)   echo "Success!" ;;
  64)  echo "Usage error - check arguments" ;;
  74)  echo "I/O error - check file permissions" ;;
  78)  echo "Config error - run 'wayu init' first" ;;
  *)   echo "Unknown error: $EXIT_CODE" ;;
esac
```

## CLI vs TUI Modes

wayu offers two distinct modes of operation:

### CLI Mode (Default) - For Scripts & Automation

**Non-interactive by design:**
- All operations require explicit arguments
- No interactive prompts or fuzzy finders
- Proper exit codes for error handling
- Safe for use in pipes, CI/CD, and cron jobs
- Destructive operations require `--yes` flag

**Example:**
```bash
# CLI requires explicit arguments
wayu path add /usr/local/bin     # ✓ Works
wayu path add                    # ✗ Error: requires argument
wayu path rm                     # ✗ Error: requires explicit name
wayu path rm /usr/local/bin      # ✓ Works
```

### TUI Mode - For Interactive Use

**Human-friendly interface:**
- Launch with `wayu --tui`
- Fuzzy search and visual selection
- Vim-style keyboard navigation
- Live data loading and updates
- Confirmation prompts for destructive actions
- Automatic backups before modifications

**Example:**
```bash
wayu --tui    # Launch interactive TUI
# Navigate with arrow keys or j/k
# Press 'd' to delete selected item
# Press 'Esc' to go back
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

**Switching shells**: Use `wayu migrate --from <shell> --to <shell>` to migrate configurations between shells. The migration preserves your PATH entries, aliases, and constants while adapting them to the target shell's syntax.

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

## TUI Mode (Interactive Terminal UI)

wayu includes a full-featured Terminal User Interface (TUI) for interactive configuration management. The TUI provides a modern, visual way to browse and manage your shell configuration.

### Launching TUI Mode

```bash
wayu --tui
```

### TUI Features

- **Modern Visual Design** - TrueColor (24-bit RGB) interface with Zellij-inspired theme
- **Bordered Panels** - Unicode box-drawing characters for clean panel separation
- **Interactive Navigation** - Browse all configuration options visually with cursor keys
- **Keyboard Shortcuts** - Vim-style navigation (j/k or ↑/↓)
- **Live Data Loading** - Automatically loads PATH, Alias, Constants, and Backups from config files
- **Safe Operations** - Automatic backups before all modifications
- **Real-time Updates** - Changes to config files are reflected immediately
- **Discoverable** - Help text displayed in each view

### TUI Color Scheme

The TUI uses a carefully designed color palette inspired by Zellij's "dvrd" theme:

- **Hot Pink** (#E40050) - Primary color for selected items, headers, and focus indicators
- **Teal-Cyan** (#0E7490) - Secondary color for success messages and info
- **Dark Backgrounds** - Purple-blue (#181825) for panels, almost-black (#09090B) for selections
- **Muted Grays** - Light gray (#D0D0D0) for normal text, dim gray (#646464) for secondary info

**Visual Elements:**
- Unicode box borders around all panels (┌─┐│└┘)
- High-contrast selection highlighting with background colors
- Color-coded headers and footers
- Adaptive borders (focused panels use hot pink, others use gray)

### Keyboard Shortcuts

**Global:**
- `↑/↓` or `j/k` - Navigate list
- `Enter` - Select item / Navigate to view
- `Esc` - Go back / Exit from main menu
- `Ctrl+C` - Quit immediately
- `q` - Quit from main menu

**View-Specific:**
- `d` or `x` - Delete selected item (PATH, Alias, Constants views)
- `c` - Cleanup old backups (Backups view)

### TUI Views

The TUI provides 8 different views:

1. **Main Menu** - Navigation hub to all features
2. **PATH View** - List and delete PATH entries
3. **Alias View** - List and delete shell aliases
4. **Constants View** - List and delete environment variables
5. **Completions View** - Manage completion scripts (placeholder)
6. **Backups View** - List backups and cleanup old ones
7. **Plugins View** - Plugin management (future feature)
8. **Settings View** - Configuration display

### TUI Architecture

```
┌─────────────────────────────────────────┐
│         Main Menu (8 options)           │
├─────────────────────────────────────────┤
│ 1. PATH Configuration                   │
│ 2. Aliases                              │
│ 3. Environment Constants                │
│ 4. Completions                          │
│ 5. Backups                              │
│ 6. Plugins                              │
│ 7. Settings                             │
│ 8. Exit                                 │
└─────────────────────────────────────────┘
```

**Data Flow:**
- TUI loads data lazily when entering each view
- Delete operations call the same wayu functions as the CLI
- Backups are created automatically before modifications
- Cache is cleared after modifications to force reload

### Troubleshooting

**TUI doesn't start:**
- Ensure terminal supports ANSI escape codes
- Try resizing terminal to at least 80x24
- Check that you're running in a TTY (not piped/redirected)

**Terminal left in raw mode:**
- Run `stty sane` or `reset` to restore terminal
- This should never happen - please report as bug if it does

**Changes not showing:**
- The TUI reloads data automatically when cache is cleared
- Try navigating away and back to the view to refresh
- Exit and re-enter TUI if data seems stale

**Performance issues:**
- Check terminal size (very large terminals may be slower)
- The TUI is optimized for < 50ms per frame
- Report performance issues with terminal details

### Design Principles

The TUI follows The Elm Architecture (TEA) pattern:

- **State Machine** - Centralized state management
- **Event Loop** - Non-blocking input polling
- **Differential Rendering** - Only updates changed screen areas
- **Immutable Updates** - State changes through pure functions
- **Lazy Loading** - Data loaded only when needed

### Implementation Notes

- **Zero Dependencies** - Pure Odin implementation with no external TUI libraries
- **Raw Mode** - Direct terminal control via termios
- **Alt Screen** - Uses alternate screen buffer (preserves terminal history)
- **Signal Handling** - Graceful cleanup on Ctrl+C and terminal resize
- **Memory Safe** - Proper cleanup of all allocated resources

## Component Testing (Developer Feature)

wayu includes a component testing infrastructure for isolated testing of TUI components. This is primarily useful for developers working on the TUI system.

### Testing Individual Components

```bash
# Render a component to stdout
wayu -c=box width=10 height=3
wayu -c=list-item width=40 height=1 text="Sample item" selected=true
wayu -c=header width=60 height=3 title="Test Header" emoji="🚀" count=15

# Create golden files for visual regression testing
wayu -c=box width=10 height=3 --snapshot

# Test against golden files
wayu -c=box width=10 height=3 --test
```

### Available Components

- `box` - Unicode border box rendering
- `list-item` - List item with selection indicator
- `header` - Header with optional emoji and count
- `footer` - Footer with keyboard shortcuts
- `scroll-indicator` - Pagination info display
- `empty-state` - Centered empty state message

### Running Component Tests

```bash
# Run component unit tests
task test:components

# Generate all golden files
task test:components:snapshot
```

### Golden File Testing

Golden files provide baseline comparisons for visual regression testing. Each component can be rendered with different dimensions and states, and the output is compared byte-for-byte against stored golden files.

Golden files are stored in `tests/golden/` and follow the naming convention: `<component>_<width>x<height>.txt`

## License

MIT
