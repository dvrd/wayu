package wayu_tui

import "core:fmt"

Cell :: struct {
	char:  rune,
	fg:    string,
	bg:    string,
	bold:  bool,
	dim:   bool,
}

Screen :: struct {
	buffer:      [][]Cell,
	prev_buffer: [][]Cell,
	width:       int,
	height:      int,
	cursor_x:    int,
	cursor_y:    int,
}

// Create screen with dimensions
screen_create :: proc(width, height: int) -> Screen {
	buffer := make([][]Cell, height)
	prev_buffer := make([][]Cell, height)

	for y in 0..<height {
		buffer[y] = make([]Cell, width)
		prev_buffer[y] = make([]Cell, width)

		// Initialize with space cells
		for x in 0..<width {
			buffer[y][x] = Cell{char = ' '}
			prev_buffer[y][x] = Cell{char = ' '}
		}
	}

	return Screen{
		buffer = buffer,
		prev_buffer = prev_buffer,
		width = width,
		height = height,
	}
}

// Destroy screen and free memory
screen_destroy :: proc(screen: ^Screen) {
	for y in 0..<len(screen.buffer) {
		delete(screen.buffer[y])
		delete(screen.prev_buffer[y])
	}
	delete(screen.buffer)
	delete(screen.prev_buffer)
}

// Resize screen, preserving content
screen_resize :: proc(screen: ^Screen, new_width, new_height: int) {
	// Allocate new buffers
	new_buffer := make([][]Cell, new_height)
	new_prev_buffer := make([][]Cell, new_height)

	for y in 0..<new_height {
		new_buffer[y] = make([]Cell, new_width)
		new_prev_buffer[y] = make([]Cell, new_width)

		// Initialize with spaces
		for x in 0..<new_width {
			new_buffer[y][x] = Cell{char = ' '}
			new_prev_buffer[y][x] = Cell{char = ' '}
		}

		// Copy existing content
		if y < screen.height {
			copy_width := min(new_width, screen.width)
			copy(new_buffer[y][:copy_width], screen.buffer[y][:copy_width])
			copy(new_prev_buffer[y][:copy_width], screen.prev_buffer[y][:copy_width])
		}
	}

	// Free old buffers
	screen_destroy(screen)

	// Update screen
	screen.buffer = new_buffer
	screen.prev_buffer = new_prev_buffer
	screen.width = new_width
	screen.height = new_height
}

// Set cell at position
screen_set_cell :: proc(screen: ^Screen, x, y: int, cell: Cell) {
	if x >= 0 && x < screen.width && y >= 0 && y < screen.height {
		screen.buffer[y][x] = cell
	}
}

// Clear screen (fill with spaces)
screen_clear :: proc(screen: ^Screen) {
	for y in 0..<screen.height {
		for x in 0..<screen.width {
			screen.buffer[y][x] = Cell{char = ' '}
		}
	}
}
