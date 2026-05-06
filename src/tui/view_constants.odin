package wayu_tui

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// ============================================================================
// Constants View
// ============================================================================

render_constants_view :: proc(state: ^TUIState, screen: ^Screen) {
	render_list_view(state, screen, ListViewConfig{
		view_key     = .CONSTANTS_VIEW,
		title        = "ENVIRONMENT CONSTANTS",
		count_format = "%d constants",
		row_kind     = .Table,
		col_label_0  = "NAME",
		col_label_1  = "VALUE",
		empty_line_1 = "No constants found",
		footer       = get_footer_data_view(state.terminal_width),
	})
}

