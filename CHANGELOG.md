# Changelog

All notable changes to wayu will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.15.0] - 2026-04-23

### Added

- **profile**: Per-phase breakdown of init-core.zsh via EPOCHREALTIME
## [3.14.1] - 2026-04-23

### Fixed

- **memory**: Eliminate all tracked-allocator leaks (68 -> 0)
## [3.14.0] - 2026-04-23

### Added

- **fuzzy**: Subsequence matching + score-sorting in interactive pickers
## [3.13.0] - 2026-04-23

### Added

- **build**: Implement 'wayu build profile' as a real timer
## [3.12.0] - 2026-04-23

### Added

- **init**: Auto-regenerate init-core; init.ext fast-paths to it
## [3.11.1] - 2026-04-23

### Fixed

- **templates,fish**: Route through wayu.toml + read [constants] as env
## [3.11.0] - 2026-04-23

### Added

- **completions**: Shell-aware naming for add/remove/list
## [3.10.1] - 2026-04-23

### Fixed

- **reload**: Make status/stop work on macOS + BSD
## [3.10.0] - 2026-04-23

### Added

- Implement doctor command, fuzzy plugin matching, and config scan
- Implement adaptive SIMD/GPU optimization system
- Implement wayu build --eval for optimized shell startup
- Complete wayu build eval with real config parsing
- Pre-compute Starship, Zoxide, Atuin in eval mode
- Inline Starship, lazy load rest of tools
- Cache eval output to init-cache.zsh
- Implementa TODAS las optimizaciones de zsh en wayu build
- Prompt nativo wayu pre-compilado sin starship
- Prompt nativo completo con todos los modulos de starship
- Soporte para newline (\n) en prompt format
- Iconos Nerd Fonts de Starship + nuevos lenguajes
- 20+ lenguajes con iconos Nerd Fonts/Unicode
- Iconos Nerd Fonts exactos de nerd-font-symbols.toml
- Modo VI visual completo con selección de texto
- Modo visual con símbolo y color diferentes
- Colores VI mode personalizados - naranja/verde/púrpura
- Línea separadora entre output y prompt
- Prompt con marco decorativo - líneas arriba y abajo con espacios
- Líneas divisorias continuas con espacios alrededor del prompt
- Mostrar versión de lenguaje en el prompt
- Icono Odin Nerd Font - símbolo sin fondo azul
- SVG limpio de Odin para Fontello
- **prompt**: Show lang version in context icon for Rust, Node, Go, Python, Zig, Bun, Deno, Ruby, Elixir, Dart
- **init**: Export all [env] vars from wayu.toml dynamically
- Add 'env' alias for constants command
- **init**: Generate aliases from wayu.toml [[aliases]] dynamically
- Expand TOML-driven config to aliases, constants, and plugins
- **cli**: Wire reload/hot-reload command
- **config**: Honor WAYU_CONFIG_DIR env var for config directory
- **env**: Add snapshot module for PATH/aliases/env cross-reference
- **cli**: Show source column in path/alias/constants list commands
- **cli**: Add --json output for list commands
- **cli**: Surface external entries from env not in wayu.toml
- **doctor**: Report wayu vs env sync status
- **tui/bridge**: Expose source classification per entry
- **tui**: Header counts + per-row source glyphs in list views
- **tui**: Footer hint update for source filter (s key)
- **completions**: Add bash completion generator
- **shell**: Complete fish shell support across init + completions
- **init**: Emit wayu.toml scaffold alongside shell init files
- **scan**: Implement --fix to import shell rc declarations
- **build**: Implement profile subcommand
- **migrate**: Implement legacy-to-TOML migration (dry-run)
- Improve path-missing warning format with colored output
- Add fuzzy-match fallback to env/alias/path get commands
- Extend search to match on entry values in addition to names
- **tui**: Source filter cycled with `s` in data views
- **tui**: Parse `source:X` token inline in text filter
- **plugins**: Complete fish shell support (types, registry, generator)
- **migrate**: Implement legacy-layout → wayu.toml conversion
- **tui**: Settings view shows real data (version, toml, backups, plugins)
- **json**: Fix --json on alias/constants, extend to backup/plugin
- **completions**: Write wayu.fish alongside zsh + bash on generate
- **fish**: Native init-core.fish generator
- **migrate**: Recognize fish syntax in legacy parsers
- **migrate**: Shell-to-shell conversion supports fish

### Changed

- Wayu.toml is now single source of truth
- Wayu build eval is now just 'source init.zsh'
- Config de usuario ahora en config.zsh, no hardcodeada
- Eliminar comandos lentos del prompt para reducir tiempo de carga
- Migrate PATH to wayu.toml, remove icon tooling
- **init_generator**: Add per-segment coloring to path-missing warning
- **toml**: Make `toml convert` an alias for `wayu migrate`
- **toml**: Alias/constants/path writes always target wayu.toml
- **backup,dry-run**: Align with wayu.toml as source of truth

### Fixed

- **doctor**: Use arena allocator for memory safety
- Add missing components to wayu build eval
- Generate absolute PATH without accumulation
- Load plugins inline in eval mode
- Remove heavy inline starship, lazy load everything
- Remove background subshell that broke shell
- Load helpers before using _wayu_evalcache
- Arregla PATH incompleto y plugins no cargaban
- Añade bindkeys para autosuggestions (Ctrl+Y)
- Añade || true a sources condicionales para evitar error exit code
- Glob errors y funcion prompt faltante
- Prompt exit_code y VI mode correctos
- Modo visual detection y color naranja 256-color
- Detector de contexto busca archivos en subdirectorios
- Mover detector Odin antes que Nim y usar find para ambos
- Líneas separadoras correctas con cursor en el prompt
- Usar $'\n' para newline literal en PROMPT
- Mover detector Go antes que Nim para evitar falsos positivos
- Usar código \ue800 para icono Odin de Fontello
- Eliminar caracteres < > del output de wayu build eval
- Usar emoji ⚔️ para Odin en lugar de icono Nerd Font
- Detector Odin compatible con bash y zsh
- **hooks**: Implement hook execution and editor integration
- **toml**: Allow hyphens in alias names
- **tui**: Add Hooks entry to main menu
- **cli**: Recognize --help/-h flag for all subcommands
- **tui**: Load PATH, Aliases, Constants from wayu.toml
- **tui**: Replace Settings view placeholders with real values
- **toml**: Implement show/keys actions to display TOML content and keys
- **reload**: Add --help support and make reload print 'watching' message
- **toml**: Parse [[paths]] array of tables in TOML config
- **shell**: Emit bash-specific syntax instead of zsh in init generation
- **hooks**: Add missing 'run' action to hooks help text
- **hooks**: Integrate hook execution into add/remove flows
- **validation**: Sanitize shell metacharacters in alias/constant values
- **config**: Clarify default action and list available subcommands
- **tui**: Replace hooks placeholder with helpful guidance
- **validation**: Idempotent sanitize preserving $ expansion
- **hooks**: Distinguish hook types by resource and fix string memory bug
- **tui**: Align backup list filtering with CLI behavior
- **toml**: Preserve escape sequences when reading and writing TOML values
- **toml**: Preserve [env] section through constants writer round-trip
- **init**: Do not block on interactive prompt when stdin is not a TTY
- **toml**: Do not duplicate [env] entries into [constants] on write
- **env_snapshot**: Clone PATH strings to prevent dangling pointers
- **env_snapshot**: Parse alias subshell output and match by name
- **tui**: Constants view must merge [env] and [constants] sections
- **tui**: Preserve alias name column when rendering source glyph
- **tui**: Remove s Source hint from all footer variants
- **tui constants**: Add external entries classification to match CLI output
- **tui**: Clear full row width in list rendering to prevent scroll overlap
- **tui**: Scroll offset applied correctly to viewport render
- **tui**: Move source glyph color from char stream to Cell.fg
- **init_generator**: Lowercase 'path' in missing-path warning message
- **search**: Read from wayu.toml instead of legacy shell files
- **reload**: Delete path strings only when not handed off to watch array
- **tui**: Main menu item count was 7 but there are 8 items
- **init**: Avoid freeing string literal in generate_full_prompt
- **completions**: Repair broken wayu.fish top-level completion
- **validation**: Reject hyphens in alias/constant identifiers
- **fish**: Repair shell_fish generators and route static_generate to fish
- **memory**: Overhaul TOML/lock/config cleanup to prevent bad frees
## [3.9.0] - 2026-04-15

### Added

- Implement all requested features
## [3.8.0] - 2026-04-15

### Added

- **toml**: Expose TOML commands to CLI
## [3.7.1] - 2026-04-15

### Changed

- **export**: Rename turbo file to turbo.zsh
## [3.7.0] - 2026-04-15

### Added

- **export**: Add turbo export mode for faster shell startup
## [3.6.0] - 2026-04-15

### Added

- Add shared interfaces for parallel workstreams
- **search**: Add global fuzzy search commands
## [3.5.0] - 2026-04-09

### Added

- Add 'wayu config' command to edit extra config in $EDITOR
## [3.4.0] - 2026-04-09

### Added

- Integrate extra.zsh as a managed config file
## [3.3.0] - 2026-04-09

### Added

- Make TUI the default when running 'wayu' with no arguments
- **tui**: Responsive layout with breakpoints and dynamic dimensions

### Fixed

- **tui**: Use select() with 50ms timeout for non-blocking event polling
## [3.2.0] - 2026-03-20

### Added

- Rename landing to docs to use on github pages
- Add SVG favicon with transparent background for landing page
- Add release target to build script — tests + tag + push to trigger CI
- Add git-cliff for automatic CHANGELOG generation on release
- Add wayu constants get command ([#3](https://github.com/dvrd/wayu/pull/3))
- Add 'const' as alias for 'constants' command ([#5](https://github.com/dvrd/wayu/pull/5))
- Automatic changelog and versioning system

### Fixed

- Source plugins/config.zsh in shell init templates for both zsh and bash
- Add og:image meta tags and screenshot
- Mention 'const' alias in wayu help output ([#5](https://github.com/dvrd/wayu/pull/5))
## [3.1.0] - 2026-02-26

### Added

- Expand environment variables and relative paths in PATH operations
- More updates and fixes
- Add TUI detail overlay views and inline fuzzy filter
- Update gitignore
- Add TUI notification system with auto-dismiss
- **tui**: Add two-column table layout for alias and constants views
- Multiple updates
- Optimize shell templates for fast startup + fix TUI buffer reuse
- **tui**: Dashboard-style main menu with accent bars and dividers
- **tui**: Dashboard views, delete confirmation modal, vim keys, arena memory
- **tui**: Focusable delete modal buttons with h/l navigation and Enter to confirm
- **tui**: Add modal for PATH/ALIAS/CONSTANTS + orange focused button highlight
- **tui**: Focus-aware add modal + Tab navigation in both modals
- Replace Taskfile with bld build system
- **plugin**: Document search action, remove dead dfs_visit_with_priority, update README
- **plugin**: Expand registry to 54 plugins with category search
- **tui/plugin**: Wire registry load + install into TUI bridge
- Show external alias sources in alias list via alias-sources.conf

### Changed

- Extract truncate_to_width, merge enable/disable, add PATH ops tests
- Consolidate layout/theme into style.odin, add subprocess module, clean up TUI and plugin layers

### Fixed

- Harden shell injection, decompose plugin, add tests and docs
- Rewrite screen_flush with active-state ANSI tracking to fix TUI color bleeding
- Migrate to new Odin core:os API (dev-2026-02)
- **tui**: Memory safety and UB fixes for release builds
- **tui**: Responsive terminal size with 3-method fallback
- **tui**: Cursor persistence bug and visual delete confirmation buttons
- **tui**: Modal button margin, border overlap, and no-background button style
- **tui**: Add extra blank row between modal body and buttons
- **tui**: Move extra modal margin above buttons, not below
- **tui**: H/l type freely in fields; bordered box input indicator
- Eliminate all memory leaks and bad frees (116 -> 0)
- CI failures — bad free in plugin config, missing dirs, CLAUDE.md check, single-threaded tests
- Code review fixes — self-rebuild mtime bug, install/dev run built binary, extract bin_path()
- Code review — arena allocs, shell-ext hardcode, parse_args dedup, table theme colors, plugin map global
- Code review — circular dep check result, backup no-op semantics, validate_constant stdout side effect
- **tui**: Viewport follows cursor in list views
- **tui**: Reserve scroll-indicator row so last item is never hidden
- **tui**: Main menu clips to terminal bounds and scrolls with cursor
- **plugin**: Memory leak in check loop, swallowed loader error, duplicate bridge procs
- **tests**: Isolate Ruby integration tests to /tmp, never touch real config
- **tui**: Registry tab always loads + clean exit with no residue
- **tui**: Tab and Enter keys never reached plugins view handler
- TUI plugin install from Registry tab end-to-end
## [3.0.0] - 2025-11-09

### Added

- Implement Phase 1 of plugin system enhancement (PRP-15)
- Implement completions view and apply layout constants across all TUI views
- Implement Phase 3 plugin enable/disable (PRP-15)
- Implement Phase 4 dependency management (PRP-15)
- Implement array-based PATH system (v3.0.0)

### Changed

- Remove tui_ prefix from files in src/tui/ directory
## [2.2.0] - 2025-10-16

### Added

- Initial implementation of wayu
- Add wayu init command for setup
- Add test coverage reporting with Ruby script
- Add input validation and sanitization (PRP-01)
- Add enhanced error handling system (PRP-02)
- Add completions command and convert tests to Ruby (PRP-03)
- Add shell detection and backup system for multi-shell support
- Add shell-specific configuration templates
- Implement multi-shell support and migration system (v2.0.0)
- Update command handlers for multi-shell compatibility
- Implement comprehensive style system and UI components
- Integrate style system across all commands
- Implement vibrant color system with TrueColor support (PRP-09 Phase 1)
- Replace Charm colors with Zellij 'dvrd' theme (PRP-09 Phase 1)
- Enhance visual aesthetics with colored symbols and curved table borders
- Implement PRP-09 Phase 2 - Interactive Add Commands (TUI mode)
- Add container border to interactive forms
- Add interactive TUI mode to alias and constants commands
- Complete PRP-07 style system render pipeline
- Integrate style system with all help commands (PRP-07 100%)
- **tui**: Implement Phase 3 enhanced fuzzy finder foundation
- **tui**: Integrate enhanced fuzzy finder into path list command
- **tui**: Integrate enhanced fuzzy finder into alias list command
- **tui**: Integrate enhanced fuzzy finder into constants list command
- Phase 5 - Terminal state safety with termios
- Add Vim-like modal keybindings and confirmation prompts
- Implement full TUI mode with memory bug fixes (PRP-12)
- Implement PRP-11 command handler abstraction
- Add TUI component system and box generator tools
- Add component testing infrastructure (PRP-13)
- Add component testing infrastructure (PRP-13)

### Changed

- Clean up code and improve error handling
- Improve memory management and UI consistency
- Remove shell script integration tests in favor of Ruby tests

### Fixed

- Resolve shell detection global variable initialization order
- Initialize HOME and WAYU_CONFIG in init_shell_globals
- Make init_shell_globals idempotent to prevent parallel test race conditions
- Correct emoji alignment, validation triggering, and memory leaks in forms
- Improve emoji width detection with precise Unicode ranges
- Resolve memory leak from double-free of validation strings
- Clone string literals to prevent freeing unallocated pointers
- Table rendering and help commands
- Simplify backup, plugin, and migrate help commands
- **tui**: Fix alignment issues in fuzzy finder rendering
- **tui**: Add carriage returns for raw mode terminal rendering
- **tui**: Improve alignment and add keyboard actions to list commands
- Resolve fuzzy finder delete actions and title alignment issues
- Correct border alignment in fuzzy finder list and details panels
- Correct border alignment to match 62-char line width
- Correct termios struct for macOS compatibility
- Resolve unit test failures and improve test robustness
- Rename run_component_test to run_component_testing
[3.15.0]: https://github.com/dvrd/wayu/releases/tag/v3.15.0
[3.14.1]: https://github.com/dvrd/wayu/releases/tag/v3.14.1
[3.14.0]: https://github.com/dvrd/wayu/releases/tag/v3.14.0
[3.13.0]: https://github.com/dvrd/wayu/releases/tag/v3.13.0
[3.12.0]: https://github.com/dvrd/wayu/releases/tag/v3.12.0
[3.11.1]: https://github.com/dvrd/wayu/releases/tag/v3.11.1
[3.11.0]: https://github.com/dvrd/wayu/releases/tag/v3.11.0
[3.10.1]: https://github.com/dvrd/wayu/releases/tag/v3.10.1
[3.10.0]: https://github.com/dvrd/wayu/releases/tag/v3.10.0
[3.9.0]: https://github.com/dvrd/wayu/releases/tag/v3.9.0
[3.8.0]: https://github.com/dvrd/wayu/releases/tag/v3.8.0
[3.7.1]: https://github.com/dvrd/wayu/releases/tag/v3.7.1
[3.7.0]: https://github.com/dvrd/wayu/releases/tag/v3.7.0
[3.6.0]: https://github.com/dvrd/wayu/releases/tag/v3.6.0
[3.5.0]: https://github.com/dvrd/wayu/releases/tag/v3.5.0
[3.4.0]: https://github.com/dvrd/wayu/releases/tag/v3.4.0
[3.3.0]: https://github.com/dvrd/wayu/releases/tag/v3.3.0
[3.2.0]: https://github.com/dvrd/wayu/releases/tag/v3.2.0
[3.1.0]: https://github.com/dvrd/wayu/releases/tag/v3.1.0
[3.0.0]: https://github.com/dvrd/wayu/releases/tag/v3.0.0
[2.2.0]: https://github.com/dvrd/wayu/releases/tag/v2.2.0

