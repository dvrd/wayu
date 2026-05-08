package wayu

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// ============================================================================
// Hooks View
// ============================================================================

render_hooks_view :: proc(state: ^TUIState, screen: ^Screen) {
	border_width, border_height := calculate_border_dimensions(state.terminal_width, state.terminal_height)
	render_box_styled(screen, BORDER_LEFT_WIDTH, BORDER_TOP_HEIGHT, border_width, border_height, TUI_BORDER_NORMAL)

	render_view_header(screen, state, "HOOKS", "Pre/post operation hooks configured", border_width)

	header_x := BORDER_LEFT_WIDTH + CONTENT_PADDING_LEFT
	text_x := header_x + MENU_ACCENT_BAR_WIDTH + MENU_ACCENT_GAP
	content_start := LIST_ITEM_START_LINE + 1

	// Read-only display of configured hooks from wayu.toml
	// Shows hook name and command for all configured hooks

	// In a real implementation, we'd load hooks from the bridge.
	// For now, show a helpful message directing users to the CLI.
	render_text_styled(screen, text_x, content_start, "Hooks Configuration", TUI_PRIMARY, "", true)
	render_text_styled(screen, text_x, content_start + 2, "To configure hooks, edit your wayu.toml file:", TUI_DIM)
	render_text_styled(screen, text_x, content_start + 3, "", TUI_DIM)
	render_text_styled(screen, text_x, content_start + 4, "  wayu config edit", TUI_DIM)
	render_text_styled(screen, text_x, content_start + 5, "", TUI_DIM)
	render_text_styled(screen, text_x, content_start + 6, "Or view configured hooks with:", TUI_DIM)
	render_text_styled(screen, text_x, content_start + 7, "", TUI_DIM)
	render_text_styled(screen, text_x, content_start + 8, "  wayu hooks list", TUI_DIM)
}

// Settings View
