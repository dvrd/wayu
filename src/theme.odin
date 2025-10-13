package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// Theme system for PRP-07 Phase 4

// Theme represents a complete styling theme
Theme :: struct {
	name:         string,
	mode:         ThemeMode,
	primary:      ColorPalette,
	secondary:    ColorPalette,
	accent:       ColorPalette,
	background:   ColorPalette,
	surface:      ColorPalette,
	error:        ColorPalette,
	warning:      ColorPalette,
	info:         ColorPalette,
	success:      ColorPalette,
	text:         TextColors,
	border:       BorderColors,
}

ThemeMode :: enum {
	Light,
	Dark,
	Auto, // Automatically detect based on terminal
}

ColorPalette :: struct {
	base:    string, // Base color
	light:   string, // Lighter variant
	dark:    string, // Darker variant
	rgb:     RGB,    // RGB values for calculations
}

TextColors :: struct {
	primary:   string, // Main text color
	secondary: string, // Secondary text color
	muted:     string, // Muted text color
	inverse:   string, // Inverse text color (for dark backgrounds)
}

BorderColors :: struct {
	primary:   string, // Main border color
	secondary: string, // Secondary border color
	accent:    string, // Accent border color
	muted:     string, // Muted border color
}

RGB :: struct {
	r, g, b: int,
}

// Global theme state
current_theme: Theme
theme_initialized := false

// Predefined themes
light_theme :: proc() -> Theme {
	return Theme{
		name = "Light",
		mode = .Light,
		primary = ColorPalette{
			base  = "36",        // Blue
			light = "96",        // Bright cyan
			dark  = "34",        // Dark blue
			rgb   = {0, 100, 200},
		},
		secondary = ColorPalette{
			base  = "35",        // Magenta
			light = "95",        // Bright magenta
			dark  = "33",        // Dark yellow
			rgb   = {150, 0, 150},
		},
		accent = ColorPalette{
			base  = "32",        // Green
			light = "92",        // Bright green
			dark  = "32",        // Green
			rgb   = {0, 150, 0},
		},
		background = ColorPalette{
			base  = "47",        // White background
			light = "47",        // White background
			dark  = "100",       // Gray background
			rgb   = {255, 255, 255},
		},
		surface = ColorPalette{
			base  = "107",       // Bright white
			light = "107",       // Bright white
			dark  = "47",        // White
			rgb   = {250, 250, 250},
		},
		error = ColorPalette{
			base  = "31",        // Red
			light = "91",        // Bright red
			dark  = "31",        // Red
			rgb   = {200, 0, 0},
		},
		warning = ColorPalette{
			base  = "33",        // Yellow
			light = "93",        // Bright yellow
			dark  = "33",        // Yellow
			rgb   = {200, 150, 0},
		},
		info = ColorPalette{
			base  = "36",        // Cyan
			light = "96",        // Bright cyan
			dark  = "36",        // Cyan
			rgb   = {0, 150, 200},
		},
		success = ColorPalette{
			base  = "32",        // Green
			light = "92",        // Bright green
			dark  = "32",        // Green
			rgb   = {0, 150, 0},
		},
		text = TextColors{
			primary   = "30",    // Black
			secondary = "90",    // Dark gray
			muted     = "37",    // Light gray
			inverse   = "97",    // Bright white
		},
		border = BorderColors{
			primary   = "90",    // Dark gray
			secondary = "37",    // Light gray
			accent    = "36",    // Cyan
			muted     = "100",   // Bright black (dark gray)
		},
	}
}

dark_theme :: proc() -> Theme {
	return Theme{
		name = "Dark",
		mode = .Dark,
		primary = ColorPalette{
			base  = "96",        // Bright cyan
			light = "106",       // Bright cyan bg
			dark  = "36",        // Cyan
			rgb   = {100, 200, 255},
		},
		secondary = ColorPalette{
			base  = "95",        // Bright magenta
			light = "105",       // Bright magenta bg
			dark  = "35",        // Magenta
			rgb   = {200, 100, 200},
		},
		accent = ColorPalette{
			base  = "92",        // Bright green
			light = "102",       // Bright green bg
			dark  = "32",        // Green
			rgb   = {100, 255, 100},
		},
		background = ColorPalette{
			base  = "40",        // Black background
			light = "100",       // Gray background
			dark  = "40",        // Black background
			rgb   = {0, 0, 0},
		},
		surface = ColorPalette{
			base  = "100",       // Gray background
			light = "47",        // White background
			dark  = "40",        // Black background
			rgb   = {30, 30, 30},
		},
		error = ColorPalette{
			base  = "91",        // Bright red
			light = "101",       // Bright red bg
			dark  = "31",        // Red
			rgb   = {255, 100, 100},
		},
		warning = ColorPalette{
			base  = "93",        // Bright yellow
			light = "103",       // Bright yellow bg
			dark  = "33",        // Yellow
			rgb   = {255, 200, 100},
		},
		info = ColorPalette{
			base  = "96",        // Bright cyan
			light = "106",       // Bright cyan bg
			dark  = "36",        // Cyan
			rgb   = {100, 200, 255},
		},
		success = ColorPalette{
			base  = "92",        // Bright green
			light = "102",       // Bright green bg
			dark  = "32",        // Green
			rgb   = {100, 255, 100},
		},
		text = TextColors{
			primary   = "97",    // Bright white
			secondary = "37",    // Light gray
			muted     = "90",    // Dark gray
			inverse   = "30",    // Black
		},
		border = BorderColors{
			primary   = "37",    // Light gray
			secondary = "90",    // Dark gray
			accent    = "96",    // Bright cyan
			muted     = "100",   // Bright black (dark gray)
		},
	}
}

// Initialize theme system
init_theme :: proc(mode: ThemeMode = .Auto) {
	switch mode {
	case .Light:
		current_theme = light_theme()
	case .Dark:
		current_theme = dark_theme()
	case .Auto:
		if is_dark_terminal() {
			current_theme = dark_theme()
		} else {
			current_theme = light_theme()
		}
	}
	theme_initialized = true
}

// Get current theme
get_theme :: proc() -> Theme {
	if !theme_initialized {
		init_theme()
	}
	return current_theme
}

// Set theme
set_theme :: proc(theme: Theme) {
	current_theme = theme
	theme_initialized = true
}

// Theme-aware style creation
themed_style :: proc(color_type: ColorType, variant: ColorVariant = .Base) -> Style {
	theme := get_theme()
	color := get_theme_color(theme, color_type, variant)

	return style_foreground(new_style(), color)
}

themed_background_style :: proc(color_type: ColorType, variant: ColorVariant = .Base) -> Style {
	theme := get_theme()
	color := get_theme_color(theme, color_type, variant)

	return style_background(new_style(), color)
}

themed_border_style :: proc(border_type: BorderColorType = .Primary) -> Style {
	theme := get_theme()

	color: string
	switch border_type {
	case .Primary:
		color = theme.border.primary
	case .Secondary:
		color = theme.border.secondary
	case .Accent:
		color = theme.border.accent
	case .Muted:
		color = theme.border.muted
	}

	return style_border_foreground(new_style(), color)
}

ColorType :: enum {
	Primary,
	Secondary,
	Accent,
	Background,
	Surface,
	Error,
	Warning,
	Info,
	Success,
	TextPrimary,
	TextSecondary,
	TextMuted,
	TextInverse,
}

ColorVariant :: enum {
	Base,
	Light,
	Dark,
}

BorderColorType :: enum {
	Primary,
	Secondary,
	Accent,
	Muted,
}

// Get color from theme
get_theme_color :: proc(theme: Theme, color_type: ColorType, variant: ColorVariant = .Base) -> string {
	palette: ColorPalette

	switch color_type {
	case .Primary:
		palette = theme.primary
	case .Secondary:
		palette = theme.secondary
	case .Accent:
		palette = theme.accent
	case .Background:
		palette = theme.background
	case .Surface:
		palette = theme.surface
	case .Error:
		palette = theme.error
	case .Warning:
		palette = theme.warning
	case .Info:
		palette = theme.info
	case .Success:
		palette = theme.success
	case .TextPrimary:
		return theme.text.primary
	case .TextSecondary:
		return theme.text.secondary
	case .TextMuted:
		return theme.text.muted
	case .TextInverse:
		return theme.text.inverse
	}

	switch variant {
	case .Base:
		return palette.base
	case .Light:
		return palette.light
	case .Dark:
		return palette.dark
	}

	return palette.base
}

// Theme-aware component styles
theme_table_style :: proc() -> Style {
	return themed_style(.TextPrimary)
}

theme_table_header_style :: proc() -> Style {
	return style_bold(themed_style(.Primary), true)
}

theme_table_border_style :: proc() -> BorderStyle {
	theme := get_theme()
	if theme.mode == .Dark {
		return .Normal
	}
	return .Normal
}

theme_success_style :: proc() -> Style {
	return themed_style(.Success)
}

theme_error_style :: proc() -> Style {
	return themed_style(.Error)
}

theme_warning_style :: proc() -> Style {
	return themed_style(.Warning)
}

theme_info_style :: proc() -> Style {
	return themed_style(.Info)
}

theme_muted_style :: proc() -> Style {
	return themed_style(.TextMuted)
}

// Create a themed table
new_themed_table :: proc(headers: []string) -> Table {
	table := new_table(headers)

	// Apply theme-aware styling
	table_style(&table, theme_table_style())
	table_header_style(&table, theme_table_header_style())
	table_border(&table, theme_table_border_style())

	return table
}

// Create themed spinner
new_themed_spinner :: proc(spinner_type: SpinnerType) -> Spinner {
	spinner := new_spinner(spinner_type)

	// Apply theme-aware styling
	spinner_style(&spinner, themed_style(.Primary))

	return spinner
}

// Create themed progress bar
new_themed_progress_bar :: proc(total: f64) -> ProgressBar {
	pb := new_progress_bar(total)

	// Apply theme-aware styling
	progress_style(&pb, theme_table_style())
	progress_filled_style(&pb, themed_style(.Success))
	progress_empty_style(&pb, themed_style(.TextMuted))
	progress_text_style(&pb, themed_style(.TextPrimary))

	return pb
}

// Detect terminal theme preference
detect_terminal_theme :: proc() -> ThemeMode {
	// Check environment variables for theme hints
	term_program := os.get_env("TERM_PROGRAM")
	defer delete(term_program)
	if len(term_program) > 0 {
		// Some terminals set specific environment variables
		if strings.contains(term_program, "dark") {
			return .Dark
		}
		if strings.contains(term_program, "light") {
			return .Light
		}
	}

	// Check COLORFGBG environment variable (some terminals set this)
	colorfgbg := os.get_env("COLORFGBG")
	defer delete(colorfgbg)
	if len(colorfgbg) > 0 {
		// Format is usually "foreground;background"
		// Light terminals often have dark text (0) on light background (15)
		// Dark terminals often have light text (15) on dark background (0)
		if strings.contains(colorfgbg, ";0") || strings.contains(colorfgbg, ";8") {
			return .Dark
		}
		if strings.contains(colorfgbg, ";15") || strings.contains(colorfgbg, ";7") {
			return .Light
		}
	}

	// Default to dark mode as it's more common in modern terminals
	return .Dark
}

// Enhanced terminal detection
enhanced_is_dark_terminal :: proc() -> bool {
	mode := detect_terminal_theme()
	return mode == .Dark || mode == .Auto
}

// Color manipulation utilities
lighten_color :: proc(rgb: RGB, amount: f32) -> RGB {
	return RGB{
		r = int(f32(rgb.r) + (255.0 - f32(rgb.r)) * amount),
		g = int(f32(rgb.g) + (255.0 - f32(rgb.g)) * amount),
		b = int(f32(rgb.b) + (255.0 - f32(rgb.b)) * amount),
	}
}

darken_color :: proc(rgb: RGB, amount: f32) -> RGB {
	return RGB{
		r = int(f32(rgb.r) * (1.0 - amount)),
		g = int(f32(rgb.g) * (1.0 - amount)),
		b = int(f32(rgb.b) * (1.0 - amount)),
	}
}

// Convert RGB to ANSI color code
rgb_to_ansi :: proc(rgb: RGB) -> string {
	return fmt.aprintf("38;2;%d;%d;%d", rgb.r, rgb.g, rgb.b)
}

rgb_to_ansi_bg :: proc(rgb: RGB) -> string {
	return fmt.aprintf("48;2;%d;%d;%d", rgb.r, rgb.g, rgb.b)
}

// Create custom theme
create_custom_theme :: proc(name: string, mode: ThemeMode, primary_rgb: RGB, secondary_rgb: RGB, accent_rgb: RGB) -> Theme {
	base_theme := mode == .Light ? light_theme() : dark_theme()

	// Override with custom colors
	custom_theme := base_theme
	custom_theme.name = name
	custom_theme.mode = mode

	custom_theme.primary.rgb = primary_rgb
	custom_theme.primary.base = rgb_to_ansi(primary_rgb)
	custom_theme.primary.light = rgb_to_ansi(lighten_color(primary_rgb, 0.2))
	custom_theme.primary.dark = rgb_to_ansi(darken_color(primary_rgb, 0.2))

	custom_theme.secondary.rgb = secondary_rgb
	custom_theme.secondary.base = rgb_to_ansi(secondary_rgb)
	custom_theme.secondary.light = rgb_to_ansi(lighten_color(secondary_rgb, 0.2))
	custom_theme.secondary.dark = rgb_to_ansi(darken_color(secondary_rgb, 0.2))

	custom_theme.accent.rgb = accent_rgb
	custom_theme.accent.base = rgb_to_ansi(accent_rgb)
	custom_theme.accent.light = rgb_to_ansi(lighten_color(accent_rgb, 0.2))
	custom_theme.accent.dark = rgb_to_ansi(darken_color(accent_rgb, 0.2))

	return custom_theme
}