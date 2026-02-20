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

// Render the table to string
table_render :: proc(table: Table) -> string {
	if len(table.headers) == 0 {
		return ""
	}

	// Make a mutable copy to recalculate widths
	mutable_table := table
	recalculate_column_widths(&mutable_table)

	result := strings.Builder{}
	defer strings.builder_destroy(&result)

	// Calculate total width
	total_width := 0
	for width in mutable_table.column_widths {
		total_width += width + 3 // +3 for " | "
	}
	total_width -= 1 // Remove last separator

	// Render top border with color (Hot pink - Zellij primary)
	if table.border_style != .None {
		border_line := render_border_line(mutable_table, '─', '╭', '╮', '┬')
		defer delete(border_line)
		strings.write_string(&result, "\x1b[38;2;228;0;80m") // Hot pink
		strings.write_string(&result, border_line)
		strings.write_string(&result, "\x1b[0m") // Reset
		strings.write_string(&result, "\n")
	}

	// Render headers
	strings.write_string(&result, "\x1b[38;2;228;0;80m│\x1b[0m ")  // Colored border
	for header, i in table.headers {
		// Apply only text styles (bold, colors) without borders/padding
		styled_header := apply_text_only_style(table.header_style, header)
		defer delete(styled_header)
		padded_header := pad_string(styled_header, mutable_table.column_widths[i])
		defer delete(padded_header)
		strings.write_string(&result, padded_header)

		if i < len(table.headers) - 1 {
			strings.write_string(&result, " \x1b[38;2;228;0;80m│\x1b[0m ")  // Colored separator
		}
	}
	strings.write_string(&result, " \x1b[38;2;228;0;80m│\x1b[0m\n")  // Colored right border

	// Render header separator with color
	if table.border_style != .None {
		separator_line := render_border_line(mutable_table, '─', '├', '┤', '┼')
		defer delete(separator_line)
		strings.write_string(&result, "\x1b[38;2;228;0;80m") // Hot pink
		strings.write_string(&result, separator_line)
		strings.write_string(&result, "\x1b[0m") // Reset
		strings.write_string(&result, "\n")
	}

	// Render rows
	for row in table.rows {
		strings.write_string(&result, "\x1b[38;2;228;0;80m│\x1b[0m ")  // Colored border
		for cell, i in row {
			// Apply only text styles (bold, colors) without borders/padding
			styled_cell := apply_text_only_style(table.style, cell)
			defer delete(styled_cell)
			padded_cell := pad_string(styled_cell, mutable_table.column_widths[i])
			defer delete(padded_cell)
			strings.write_string(&result, padded_cell)

			if i < len(row) - 1 {
				strings.write_string(&result, " \x1b[38;2;228;0;80m│\x1b[0m ")  // Colored separator
			}
		}
		strings.write_string(&result, " \x1b[38;2;228;0;80m│\x1b[0m\n")  // Colored right border
	}

	// Render bottom border with color and curved corners
	if table.border_style != .None {
		bottom_line := render_border_line(mutable_table, '─', '╰', '╯', '┴')
		defer delete(bottom_line)
		strings.write_string(&result, "\x1b[38;2;228;0;80m") // Hot pink
		strings.write_string(&result, bottom_line)
		strings.write_string(&result, "\x1b[0m") // Reset
		strings.write_string(&result, "\n")
	}

	return strings.clone(strings.to_string(result))
}

// Helper function to pad string to specific width
// NOTE: Always returns an ALLOCATED string — caller must delete()
pad_string :: proc(str: string, width: int) -> string {
	current_width := visual_width(str)
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