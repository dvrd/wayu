# wayu

A shell configuration management CLI written in Odin that helps you manage PATH entries, aliases, and environment constants across your shell environment.

## Features

- **PATH Management** - Add, remove, and list PATH entries with duplicate detection
- **Alias Management** - Manage shell aliases with interactive removal
- **Constants Management** - Handle environment variables and constants
- **Interactive Mode** - Fuzzy search for removing entries
- **Zero Dependencies** - Written in Odin for fast compilation and execution

## Installation

### Prerequisites

- [Odin compiler](https://odin-lang.org/docs/install/)
- [Task](https://taskfile.dev/) (optional, for using the Taskfile)

### Build & Install

```bash
# Setup configuration directory
task setup

# Build and install
task install
```

Or manually:

```bash
# Build
odin build src -out:bin/wayu -o:speed

# Install
cp bin/wayu /usr/local/bin/wayu
chmod +x /usr/local/bin/wayu
```

## Usage

```
wayu <command> <action> [arguments]
```

### Commands

- `path` - Manage PATH entries
- `alias` - Manage shell aliases
- `constants` - Manage environment constants
- `help` - Show help message

### Actions

- `add` - Add a new entry
- `remove`, `rm` - Remove an entry (interactive if no args provided)
- `list`, `ls` - List all entries
- `help` - Show command-specific help

### Examples

```bash
# PATH management
wayu path add /usr/local/bin
wayu path add                    # Uses current directory
wayu path rm                     # Interactive removal
wayu path list

# Alias management
wayu alias add ll 'ls -la'
wayu alias add gs 'git status'
wayu alias rm                    # Interactive removal
wayu alias list

# Constants management
wayu constants add MY_VAR value
wayu constants add API_KEY secret_key
wayu constants rm                # Interactive removal
wayu constants list
```

## Configuration

wayu stores configuration files in `~/.config/wayu/`:

- `path.zsh` - PATH entries
- `aliases.zsh` - Shell aliases
- `constants.zsh` - Environment constants

Source these files in your shell profile:

```bash
# Add to ~/.zshrc
source ~/.config/wayu/path.zsh
source ~/.config/wayu/aliases.zsh
source ~/.config/wayu/constants.zsh
```

## Development

```bash
# Build for development
task build-dev

# Build with debug info
task build-debug

# Run tests
task test

# Check code
task check

# Development workflow
task dev CLI_ARGS="path list"
```

## License

MIT
