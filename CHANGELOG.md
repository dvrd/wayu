# Changelog

All notable changes to wayu will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.2.0] - 2025-10-16

### 🚀 Major Features

- **CLI/TUI Isolation (PRP-13)**: Complete separation of interactive and non-interactive modes
  - CLI is now fully non-interactive for scripting and automation
  - All interactive features consolidated in TUI mode (`--tui`)
  - Perfect for CI/CD, automation scripts, and pipes

- **BSD sysexits.h Exit Codes**: Industry-standard exit codes for proper error handling
  - `0` - Success
  - `1` - General error
  - `64` - Usage error (invalid arguments)
  - `65` - Data format error
  - `66` - Input file not found
  - `73` - Cannot create output file
  - `74` - I/O error
  - `77` - Permission denied
  - `78` - Configuration error

- **`--yes` Flag**: Skip confirmation prompts for automation
  - `wayu path clean --yes` - Remove missing directories
  - `wayu path dedup --yes` - Remove duplicates

- **CI/CD Integration**: GitHub Actions workflows for automated testing and releases
  - Automated testing on Ubuntu and macOS
  - Multi-shell testing (bash and zsh)
  - Automated release builds for multiple platforms

### ✨ Added

- Comprehensive exit code documentation in help command
- Error messages now show usage examples and suggest `--tui` for interactive mode
- Smoke test script for quick validation (`scripts/smoke-test.sh`)
- Manual testing guide (`docs/MANUAL_TESTING.md`)
- CI/CD workflows (`.github/workflows/ci.yml`, `.github/workflows/release.yml`)

### 🔄 Changed

- **BREAKING**: CLI commands now require explicit arguments
  - Old: `wayu path rm` → Opens fuzzy finder
  - New: `wayu path rm /specific/path` → Requires explicit path

- **BREAKING**: Confirmation operations require `--yes` flag
  - Old: `wayu path clean` → Prompts [y/N]
  - New: `wayu path clean --yes` → Requires explicit flag

- **BREAKING**: List commands default to static output
  - Old: `wayu path list` → Opens interactive selector
  - New: `wayu path list` → Shows static table
  - Use `wayu --tui` for interactive browsing

- Exit codes are now categorized (not all 1)
- Backup handlers split: CLI fails immediately, TUI prompts user

### 📚 Documentation

- Updated README.md with:
  - CLI vs TUI Modes section
  - Exit Codes table
  - Scripting & automation examples
  - Updated all usage examples

- Updated CLAUDE.md with:
  - CLI/TUI separation architecture
  - Exit code system documentation
  - PRP-13 implementation details

- New testing documentation:
  - `docs/MANUAL_TESTING.md` - Comprehensive testing guide
  - `docs/TESTING_COMPLETE.md` - Release status report

### 🧪 Testing

- 37/37 tests passing (27 integration + 10 UI)
- Smoke test validates all key behaviors
- CI/CD pipeline tests on multiple platforms

### 🔧 Internal

- Split backup handlers for CLI vs TUI
- Removed all interactive fallbacks from CLI path
- Updated 87 exit points with proper categorized codes
- Improved error message quality

### 📦 Migration Guide

For users upgrading from v2.1.x or earlier:

**Scripts using explicit arguments (no changes needed):**
```bash
wayu path add /usr/local/bin    # ✓ Still works
wayu alias add ll "ls -la"      # ✓ Still works
```

**Scripts relying on interactive prompts (need updates):**
```bash
# Old (v2.1.x)
wayu path rm                    # Opens fuzzy finder
wayu path clean                 # Prompts [y/N]

# New (v2.2.0)
wayu path rm /specific/path     # Explicit argument required
wayu path clean --yes           # --yes flag required
wayu --tui                      # Use TUI for interactive mode
```

**For interactive management:**
```bash
wayu --tui    # Launch Terminal UI mode
```

---

## [2.1.0] - 2025-10-15

### Added

- Full TUI mode with The Elm Architecture (TEA) pattern
- Component testing infrastructure
- Modern style system with themes
- UI components (tables, progress bars, spinners)

### Changed

- Improved visual design with bordered panels
- Added Vim-style keyboard navigation

---

## [2.0.0] - 2025-10-14

### Added

- Multi-shell support (Bash and ZSH)
- Automatic shell detection
- Shell migration command
- Shell-specific templates

### Changed

- Configuration files now use shell-specific extensions (`.bash`, `.zsh`)

---

## [1.0.0] - Initial Release

### Added

- PATH management
- Alias management
- Environment constants management
- Backup system
- Configuration initialization

---

[2.2.0]: https://github.com/user/wayu/releases/tag/v2.2.0
[2.1.0]: https://github.com/user/wayu/releases/tag/v2.1.0
[2.0.0]: https://github.com/user/wayu/releases/tag/v2.0.0
[1.0.0]: https://github.com/user/wayu/releases/tag/v1.0.0
