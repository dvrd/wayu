package wayu

// Shared types for wayu and its components

// Style system types (moved from style.odin to avoid circular imports)
Style :: struct {
	foreground: string,
	background: string,
	bold: bool,
	italic: bool,
	underline: bool,
	strikethrough: bool,
	dim: bool,
	blink: bool,
	reverse: bool,
	faint: bool,
	padding_top: int,
	padding_right: int,
	padding_bottom: int,
	padding_left: int,
	margin_top: int,
	margin_right: int,
	margin_bottom: int,
	margin_left: int,
	width: int,
	height: int,
	max_width: int,
	max_height: int,
	align_horizontal: Alignment,
	align_vertical: Alignment,
	border_style: BorderStyle,
	border_top: bool,
	border_right: bool,
	border_bottom: bool,
	border_left: bool,
	border_fg: string,
	border_bg: string,
	foreground_dark: string,
	background_dark: string,
}

Alignment :: enum {
	Left,
	Center,
	Right,
	Top,
	Middle,
	Bottom,
}

BorderStyle :: enum {
	None,
	Normal,
	Rounded,
	Thick,
	Double,
	Hidden,
}

// Color constants
Color :: struct {
	Red: string,
	Green: string,
	Yellow: string,
	Blue: string,
	Magenta: string,
	Cyan: string,
	White: string,
	Black: string,
}

COLOR_CONSTANTS :: Color{
	Red = "31",
	Green = "32",
	Yellow = "33",
	Blue = "34",
	Magenta = "35",
	Cyan = "36",
	White = "37",
	Black = "30",
}