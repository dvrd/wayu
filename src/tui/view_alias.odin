package wayu_tui

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// ============================================================================
// Alias View
// ============================================================================

render_alias_view :: proc(state: ^TUIState, screen: ^Screen) {
	render_list_view(state, screen, ListViewConfig{
		view_key     = .ALIAS_VIEW,
		title        = "ALIASES",
		count_format = "%d aliases",
		row_kind     = .Table,
		col_label_0  = "ALIAS",
		col_label_1  = "COMMAND",
		empty_line_1 = "No aliases found",
		footer       = get_footer_data_view(state.terminal_width),
	})
}

