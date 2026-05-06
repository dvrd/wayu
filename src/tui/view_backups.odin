package wayu_tui

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// ============================================================================
// Backups View
// ============================================================================

render_backups_view :: proc(state: ^TUIState, screen: ^Screen) {
	render_list_view(state, screen, ListViewConfig{
		view_key     = .BACKUPS_VIEW,
		title        = "BACKUPS",
		count_format = "%d backups available",
		row_kind     = .Single,
		empty_line_1 = "No backups found",
		footer       = get_footer_backup_view(state.terminal_width),
	})
}

