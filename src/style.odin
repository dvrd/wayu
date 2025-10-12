package wayu

import "core:fmt"
import "core:strings"

// Minimal style system for PRP-07 Phase 1
// Note: Style, Alignment, and BorderStyle types are defined in types.odin

// Simple render function that just returns the text for now
render :: proc(s: Style, text: string) -> string {
	if s.bold {
		return fmt.aprintf("\x1b[1m%s\x1b[0m", text)
	}
	return text
}

// Basic style creation
new_style :: proc() -> Style {
	return Style{}
}

// Helper functions for creating predefined styles
style_success :: proc() -> Style {
	return Style{foreground = "green"}
}

style_error :: proc() -> Style {
	return Style{foreground = "red", bold = true}
}

style_warning :: proc() -> Style {
	return Style{foreground = "yellow"}
}

style_info :: proc() -> Style {
	return Style{foreground = "blue"}
}

// Note: Color constants are defined in types.odin

// Utility functions needed by tests
hex_to_rgb :: proc(hex: string) -> (r: int, g: int, b: int) {
	return 0, 0, 0  // Placeholder
}

is_dark_terminal :: proc() -> bool {
	return true
}

// Style builder methods (minimal set for compilation)
style_foreground :: proc(s: Style, color: string) -> Style {
	result := s
	result.foreground = color
	return result
}

style_background :: proc(s: Style, color: string) -> Style {
	result := s
	result.background = color
	return result
}

style_bold :: proc(s: Style, enable: bool = true) -> Style {
	result := s
	result.bold = enable
	return result
}

style_italic :: proc(s: Style, enable: bool = true) -> Style {
	result := s
	result.italic = enable
	return result
}

style_underline :: proc(s: Style, enable: bool = true) -> Style {
	result := s
	result.underline = enable
	return result
}

style_strikethrough :: proc(s: Style, enable: bool = true) -> Style {
	result := s
	result.strikethrough = enable
	return result
}

style_padding :: proc(s: Style, i: int) -> Style {
	result := s
	result.padding_top = i
	result.padding_right = i
	result.padding_bottom = i
	result.padding_left = i
	return result
}

style_padding_top :: proc(s: Style, i: int) -> Style {
	result := s
	result.padding_top = i
	return result
}

style_padding_right :: proc(s: Style, i: int) -> Style {
	result := s
	result.padding_right = i
	return result
}

style_padding_bottom :: proc(s: Style, i: int) -> Style {
	result := s
	result.padding_bottom = i
	return result
}

style_padding_left :: proc(s: Style, i: int) -> Style {
	result := s
	result.padding_left = i
	return result
}

style_margin :: proc(s: Style, i: int) -> Style {
	result := s
	result.margin_top = i
	result.margin_right = i
	result.margin_bottom = i
	result.margin_left = i
	return result
}

style_margin_top :: proc(s: Style, i: int) -> Style {
	result := s
	result.margin_top = i
	return result
}

style_margin_right :: proc(s: Style, i: int) -> Style {
	result := s
	result.margin_right = i
	return result
}

style_margin_bottom :: proc(s: Style, i: int) -> Style {
	result := s
	result.margin_bottom = i
	return result
}

style_margin_left :: proc(s: Style, i: int) -> Style {
	result := s
	result.margin_left = i
	return result
}

style_width :: proc(s: Style, w: int) -> Style {
	result := s
	result.width = w
	return result
}

style_height :: proc(s: Style, h: int) -> Style {
	result := s
	result.height = h
	return result
}

style_max_width :: proc(s: Style, w: int) -> Style {
	result := s
	result.max_width = w
	return result
}

style_max_height :: proc(s: Style, h: int) -> Style {
	result := s
	result.max_height = h
	return result
}

style_border :: proc(s: Style, border_type: BorderStyle = .Normal) -> Style {
	result := s
	result.border_style = border_type
	return result
}

style_border_top :: proc(s: Style, enable: bool = true) -> Style {
	result := s
	result.border_top = enable
	return result
}

style_border_right :: proc(s: Style, enable: bool = true) -> Style {
	result := s
	result.border_right = enable
	return result
}

style_border_bottom :: proc(s: Style, enable: bool = true) -> Style {
	result := s
	result.border_bottom = enable
	return result
}

style_border_left :: proc(s: Style, enable: bool = true) -> Style {
	result := s
	result.border_left = enable
	return result
}

style_border_foreground :: proc(s: Style, color: string) -> Style {
	result := s
	result.border_fg = color
	return result
}

style_border_background :: proc(s: Style, color: string) -> Style {
	result := s
	result.border_bg = color
	return result
}

style_align_horizontal :: proc(s: Style, a: Alignment) -> Style {
	result := s
	result.align_horizontal = a
	return result
}

style_align_vertical :: proc(s: Style, a: Alignment) -> Style {
	result := s
	result.align_vertical = a
	return result
}

style_foreground_rgb :: proc(s: Style, r: int, g: int, b: int) -> Style {
	result := s
	result.foreground = fmt.aprintf("%d;%d;%d", r, g, b)
	return result
}

style_background_rgb :: proc(s: Style, r: int, g: int, b: int) -> Style {
	result := s
	result.background = fmt.aprintf("%d;%d;%d", r, g, b)
	return result
}

style_foreground_hex :: proc(s: Style, hex: string) -> Style {
	r, g, b := hex_to_rgb(hex)
	return style_foreground_rgb(s, r, g, b)
}

style_background_hex :: proc(s: Style, hex: string) -> Style {
	r, g, b := hex_to_rgb(hex)
	return style_background_rgb(s, r, g, b)
}

style_foreground_adaptive :: proc(s: Style, light: string, dark: string) -> Style {
	result := s
	result.foreground = light
	result.foreground_dark = dark
	return result
}