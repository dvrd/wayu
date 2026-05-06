package wayu_tui

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// ============================================================================

render_settings_view :: proc(state: ^TUIState, screen: ^Screen) {
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_NORMAL)

	render_view_header(screen, state, "SETTINGS", "wayu Configuration", border_width)

	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	text_x := header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP

	// Load settings from bridge (idempotent — only loads once).
	tui_load_settings_data(state)

	// Render lines live on context.temp_allocator — automatically freed at
	// end of frame, so we don't need per-line defer delete churn.
	dry_run_status := "off"
	if state.settings_dry_run { dry_run_status = "on" }

	toml_status := "missing"
	if state.settings_toml_exists {
		toml_status = state.settings_toml_path
	}

	settings := []string{
		fmt.tprintf("Version:     %s",    state.settings_version),
		fmt.tprintf("Shell:       %s",    state.settings_shell),
		fmt.tprintf("Config Dir:  %s",    state.settings_config_dir),
		fmt.tprintf("wayu.toml:   %s",    toml_status),
		fmt.tprintf("Backups:     %d",    state.settings_backups),
		fmt.tprintf("Plugins:     %d enabled", state.settings_plugins),
		fmt.tprintf("Dry-run:     %s",    dry_run_status),
	}

	content_start := LIST_ITEM_START_LINE + 2
	for setting, i in settings {
		render_text_styled(screen, text_x, content_start + i, setting, TUI_MUTED)
	}

	render_data_footer(screen, state, get_footer_static_view(state.terminal_width))
}

