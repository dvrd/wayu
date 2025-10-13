package test_wayu

import "core:testing"
import "core:strings"
import "core:os"
import wayu "../src"

// Test table creation
@(test)
test_table_creation :: proc(t: ^testing.T) {
    headers := []string{"Column 1", "Column 2"}
    table := wayu.new_table(headers)
    defer wayu.table_destroy(&table)

    testing.expect_value(t, len(table.headers), 2)
    testing.expect_value(t, table.headers[0], "Column 1")
    testing.expect_value(t, table.headers[1], "Column 2")
    testing.expect_value(t, len(table.rows), 0)
    testing.expect_value(t, len(table.column_widths), 2)
}

// Test adding rows to table
@(test)
test_table_add_row :: proc(t: ^testing.T) {
    headers := []string{"Name", "Age"}
    table := wayu.new_table(headers)
    defer wayu.table_destroy(&table)

    row1 := []string{"Alice", "25"}
    wayu.table_add_row(&table, row1)

    testing.expect_value(t, len(table.rows), 1)
    testing.expect_value(t, table.rows[0][0], "Alice")
    testing.expect_value(t, table.rows[0][1], "25")

    row2 := []string{"Bob", "30"}
    wayu.table_add_row(&table, row2)

    testing.expect_value(t, len(table.rows), 2)
    testing.expect_value(t, table.rows[1][0], "Bob")
    testing.expect_value(t, table.rows[1][1], "30")
}

// Test column width calculation
@(test)
test_table_column_widths :: proc(t: ^testing.T) {
    headers := []string{"Short", "Very Long Header"}
    table := wayu.new_table(headers)
    defer wayu.table_destroy(&table)

    // Initial widths should be based on headers
    testing.expect_value(t, table.column_widths[0], 5) // "Short"
    testing.expect_value(t, table.column_widths[1], 16) // "Very Long Header"

    // Add row with longer content in first column
    row := []string{"This is a very long entry", "Small"}
    wayu.table_add_row(&table, row)

    // Column widths should expand to fit content
    testing.expect_value(t, table.column_widths[0], 25) // Expanded for long entry
    testing.expect_value(t, table.column_widths[1], 16) // Should keep header width
}

// Test table styling
@(test)
test_table_styling :: proc(t: ^testing.T) {
    headers := []string{"Test"}
    table := wayu.new_table(headers)
    defer wayu.table_destroy(&table)

    // Test style setting
    test_style := wayu.style_foreground(wayu.new_style(), "red")
    result_table := wayu.table_style(&table, test_style)
    testing.expect_value(t, result_table.style.foreground, "red")

    // Test header style setting
    header_style := wayu.style_bold(wayu.new_style(), true)
    wayu.table_header_style(&table, header_style)
    testing.expect_value(t, table.header_style.bold, true)

    // Test border style setting
    wayu.table_border(&table, .Rounded)
    testing.expect_value(t, table.border_style, wayu.BorderStyle.Rounded)
}

// Test table rendering
@(test)
test_table_render :: proc(t: ^testing.T) {
    headers := []string{"Name", "Status"}
    table := wayu.new_table(headers)
    defer wayu.table_destroy(&table)

    row := []string{"Test", "OK"}
    wayu.table_add_row(&table, row)

    output := wayu.table_render(table)
    defer delete(output)

    // Check that output contains expected elements
    testing.expect_value(t, strings.contains(output, "Name"), true)
    testing.expect_value(t, strings.contains(output, "Status"), true)
    testing.expect_value(t, strings.contains(output, "Test"), true)
    testing.expect_value(t, strings.contains(output, "OK"), true)
    testing.expect_value(t, strings.contains(output, "┌"), true) // Top border
    testing.expect_value(t, strings.contains(output, "└"), true) // Bottom border
    testing.expect_value(t, strings.contains(output, "│"), true) // Side borders
}

// Test empty table rendering
@(test)
test_empty_table_render :: proc(t: ^testing.T) {
    headers: []string = {}
    table := wayu.new_table(headers)
    defer wayu.table_destroy(&table)

    output := wayu.table_render(table)
    defer delete(output)

    testing.expect_value(t, output, "")
}

// Test pad_string helper function
@(test)
test_pad_string :: proc(t: ^testing.T) {
    result := wayu.pad_string("test", 10)
    defer delete(result)

    testing.expect_value(t, len(result), 10)
    testing.expect_value(t, strings.has_prefix(result, "test"), true)
    testing.expect_value(t, strings.has_suffix(result, "      "), true) // 6 spaces
}

// Test environment variable expansion for table display
@(test)
test_table_expand_env_vars :: proc(t: ^testing.T) {
    // Test basic expansion (if HOME is set)
    home_path := "$HOME/test"
    expanded := wayu.expand_env_vars(home_path)
    defer delete(expanded)

    // Should not contain $ if HOME is set
    if len(os.get_env("HOME")) > 0 {
        testing.expect_value(t, strings.contains(expanded, "$"), false)
        testing.expect_value(t, strings.contains(expanded, "/test"), true)
    }

    // Test path without variables
    normal_path := "/usr/bin"
    expanded_normal := wayu.expand_env_vars(normal_path)
    defer delete(expanded_normal)
    testing.expect_value(t, expanded_normal, "/usr/bin")
}