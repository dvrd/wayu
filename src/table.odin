package wayu

import "core:fmt"
import "core:strings"

// Table component for displaying structured data
Table :: struct {
	headers: []string,
	rows: [dynamic][]string,
	style: Style,
	header_style: Style,
	border_style: BorderStyle,
	width: int,
	column_widths: []int,
}

// Create a new table with headers
new_table :: proc(headers: []string) -> Table {
	column_widths := make([]int, len(headers))

	// Initialize column widths based on header lengths
	for header, i in headers {
		column_widths[i] = visual_width(header)
	}

	return Table{
		headers = headers,
		rows = make([dynamic][]string),
		style = new_style(),
		header_style = style_bold(new_style(), true),
		border_style = .Normal,
		width = 0,
		column_widths = column_widths,
	}
}

// Add a row to the table
table_add_row :: proc(table: ^Table, row: []string) {
	if len(row) != len(table.headers) {
		return // Skip rows that don't match header count
	}

	// Clone the row data to avoid memory issues
	cloned_row := make([]string, len(row))
	for cell, i in row {
		cloned_row[i] = strings.clone(cell)
	}

	append(&table.rows, cloned_row)

	// Update column widths based on raw text (styles will be applied during rendering)
	for cell, i in row {
		cell_width := visual_width(cell)
		if cell_width > table.column_widths[i] {
			table.column_widths[i] = cell_width
		}
	}

	// Update header widths based on raw text
	for header, i in table.headers {
		header_width := visual_width(header)
		if header_width > table.column_widths[i] {
			table.column_widths[i] = header_width
		}
	}
}

// Style the table
table_style :: proc(table: ^Table, s: Style) -> ^Table {
	table.style = s
	return table
}

// Style the table headers
table_header_style :: proc(table: ^Table, s: Style) -> ^Table {
	table.header_style = s
	return table
}

// Set table border style
table_border :: proc(table: ^Table, border: BorderStyle) -> ^Table {
	table.border_style = border
	return table
}

// Helper to recalculate column widths ensuring they fit all content
recalculate_column_widths :: proc(table: ^Table) {
	// Recalculate based on headers
	for header, i in table.headers {
		table.column_widths[i] = visual_width(header)
	}

	// Recalculate based on all rows
	for row in table.rows {
		for cell, i in row {
			cell_width := visual_width(cell)
			if cell_width > table.column_widths[i] {
				table.column_widths[i] = cell_width
			}
		}
	}
}

// Clamp column widths so the total table fits within max_width.
// Strategy: shrink the widest columns first, keeping a minimum of 4 chars per column.
clamp_table_widths :: proc(table: ^Table, max_width: int) {
	ncols := len(table.column_widths)
	if ncols == 0 do return

	// Table overhead: │ + (" X ") per column + │
	// Each column: 1 space + content + 1 space = width + 2
	// Separators: │ between columns = ncols - 1 separators × 1
	// Borders: │ left + │ right = 2
	// Total = sum(widths) + 2*ncols + (ncols-1) + 2
	overhead := 2 * ncols + (ncols - 1) + 2
	available := max_width - overhead
	if available < ncols * 4 {
		// Even minimum widths don't fit — set all to minimum
		for i in 0..<ncols {
			table.column_widths[i] = 4
		}
		return
	}

	// Check if current widths fit
	total := 0
	for w in table.column_widths {
		total += w
	}
	if total <= available {
		return  // Already fits
	}

	// Shrink proportionally, respecting minimum of 4 chars
	min_per_col := 4
	widths_copy := make([]int, ncols)
	for i in 0..<ncols {
		widths_copy[i] = table.column_widths[i]
	}

	// Iteratively shrink the widest column until it fits
	for total > available {
		// Find widest column
		max_idx := 0
		for i in 1..<ncols {
			if widths_copy[i] > widths_copy[max_idx] {
				max_idx = i
			}
		}
		if widths_copy[max_idx] <= min_per_col {
			break  // Can't shrink more
		}
		widths_copy[max_idx] -= 1
		total -= 1
	}

	for i in 0..<ncols {
		table.column_widths[i] = widths_copy[i]
	}
	delete(widths_copy)
}

// Render the table to string, fitting within max_width columns if specified (> 0).
// When max_width > 0, columns are proportionally truncated to fit.
table_render :: proc(table: Table, max_width: int = 0) -> string {
	if len(table.headers) == 0 {
		return ""
	}

	// Make a mutable copy to recalculate widths
	mutable_table := table
	recalculate_column_widths(&mutable_table)

	// Clamp column widths to fit within max_width
	if max_width > 0 {
		clamp_table_widths(&mutable_table, max_width)
	}

	result := strings.Builder{}
	defer strings.builder_destroy(&result)

	// Border color: adaptive primary color from colors.odin (truecolor/256/ANSI).
	border_on  := get_primary()
	border_off :: "\x1b[0m"

	// Calculate total width
	total_width := 0
	for width in mutable_table.column_widths {
		total_width += width + 3 // +3 for " | "
	}
	total_width -= 1 // Remove last separator

	// Render top border
	if table.border_style != .None {
		border_line := render_border_line(mutable_table, '─', '╭', '╮', '┬')
		defer delete(border_line)
		strings.write_string(&result, border_on)
		strings.write_string(&result, border_line)
		strings.write_string(&result, border_off)
		strings.write_string(&result, "\n")
	}

	// Render headers
	strings.write_string(&result, border_on)
	strings.write_string(&result, "│")
	strings.write_string(&result, border_off)
	strings.write_string(&result, " ")
	for header, i in table.headers {
		// Apply only text styles (bold, colors) without borders/padding
		styled_header := apply_text_only_style(table.header_style, header)
		defer delete(styled_header)
		padded_header := pad_string(styled_header, mutable_table.column_widths[i])
		defer delete(padded_header)
		strings.write_string(&result, padded_header)

		if i < len(table.headers) - 1 {
			strings.write_string(&result, " ")
			strings.write_string(&result, border_on)
			strings.write_string(&result, "│")
			strings.write_string(&result, border_off)
			strings.write_string(&result, " ")
		}
	}
	strings.write_string(&result, " ")
	strings.write_string(&result, border_on)
	strings.write_string(&result, "│")
	strings.write_string(&result, border_off)
	strings.write_string(&result, "\n")

	// Render header separator
	if table.border_style != .None {
		separator_line := render_border_line(mutable_table, '─', '├', '┤', '┼')
		defer delete(separator_line)
		strings.write_string(&result, border_on)
		strings.write_string(&result, separator_line)
		strings.write_string(&result, border_off)
		strings.write_string(&result, "\n")
	}

	// Render rows
	for row in table.rows {
		strings.write_string(&result, border_on)
		strings.write_string(&result, "│")
		strings.write_string(&result, border_off)
		strings.write_string(&result, " ")
		for cell, i in row {
			// Apply only text styles (bold, colors) without borders/padding
			styled_cell := apply_text_only_style(table.style, cell)
			defer delete(styled_cell)
			padded_cell := pad_string(styled_cell, mutable_table.column_widths[i])
			defer delete(padded_cell)
			strings.write_string(&result, padded_cell)

			if i < len(row) - 1 {
				strings.write_string(&result, " ")
				strings.write_string(&result, border_on)
				strings.write_string(&result, "│")
				strings.write_string(&result, border_off)
				strings.write_string(&result, " ")
			}
		}
		strings.write_string(&result, " ")
		strings.write_string(&result, border_on)
		strings.write_string(&result, "│")
		strings.write_string(&result, border_off)
		strings.write_string(&result, "\n")
	}

	// Render bottom border with curved corners
	if table.border_style != .None {
		bottom_line := render_border_line(mutable_table, '─', '╰', '╯', '┴')
		defer delete(bottom_line)
		strings.write_string(&result, border_on)
		strings.write_string(&result, bottom_line)
		strings.write_string(&result, border_off)
		strings.write_string(&result, "\n")
	}

	return strings.clone(strings.to_string(result))
}

// Truncate a string (which may contain ANSI codes) to fit within max_width visual columns.
// Returns an allocated string (caller must delete).
truncate_visual :: proc(str: string, max_width: int) -> string {
	if max_width <= 0 do return strings.clone("")

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	visual := 0
	in_escape := false
	for ch in str {
		if ch == '\x1b' {
			in_escape = true
			strings.write_rune(&builder, ch)
			continue
		}
		if in_escape {
			strings.write_rune(&builder, ch)
			if ch == 'm' {
				in_escape = false
			}
			continue
		}
		if visual >= max_width - 1 {
			strings.write_rune(&builder, '\u2026')  // …
			break
		}
		strings.write_rune(&builder, ch)
		visual += 1
	}

	return strings.clone(strings.to_string(builder))
}

// Helper function to pad string to specific width
// NOTE: Always returns an ALLOCATED string — caller must delete()
pad_string :: proc(str: string, width: int) -> string {
	current_width := visual_width(str)

	// Truncate if wider than target width
	if current_width > width {
		truncated := truncate_visual(str, width)
		defer delete(truncated)
		return strings.clone(truncated)
	}

	if current_width >= width {
		return strings.clone(str)
	}

	padding := width - current_width
	padding_str := strings.repeat(" ", padding)
	defer delete(padding_str)

	return fmt.aprintf("%s%s", str, padding_str)
}

// Helper function to render border lines with proper column separators
render_border_line :: proc(table: Table, fill: rune, left: rune, right: rune, sep: rune) -> string {
	result := strings.Builder{}
	defer strings.builder_destroy(&result)

	strings.write_rune(&result, left)

	for i in 0..<len(table.column_widths) {
		// Add padding characters for each column
		for j in 0..<table.column_widths[i] + 2 { // +2 for padding spaces
			strings.write_rune(&result, fill)
		}

		// Add separator between columns (except for last column)
		if i < len(table.column_widths) - 1 {
			strings.write_rune(&result, sep)
		}
	}

	strings.write_rune(&result, right)

	return strings.clone(strings.to_string(result))
}

// Clean up table memory
table_destroy :: proc(table: ^Table) {
	for row in table.rows {
		for cell in row {
			delete(cell)
		}
		delete(row)
	}
	delete(table.rows)
	delete(table.column_widths)
}