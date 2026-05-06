package wayu_tui

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// ============================================================================
// PATH View
// ============================================================================

render_path_view :: proc(state: ^TUIState, screen: ^Screen) {
	render_list_view(state, screen, ListViewConfig{
		view_key     = .PATH_VIEW,
		title        = "PATH CONFIGURATION",
		count_format = "%d entries",  // Unused (calculated from source counts)
		row_kind     = .Single,
		empty_line_1 = "No PATH entries found",
		footer       = get_footer_data_view(state.terminal_width),
	})
}

