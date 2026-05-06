package wayu_tui

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// ============================================================================
// Completions View
// ============================================================================

render_completions_view :: proc(state: ^TUIState, screen: ^Screen) {
	render_list_view(state, screen, ListViewConfig{
		view_key     = .COMPLETIONS_VIEW,
		title        = "COMPLETIONS",
		count_format = "%d completion scripts",
		row_kind     = .Single,
		empty_line_1 = "No completion scripts found",
		empty_line_2 = "Add completions with: wayu completions add <name> <file>",
		footer       = get_footer_readonly_view(state.terminal_width),
	})
}

