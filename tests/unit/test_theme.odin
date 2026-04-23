// test_theme.odin - Unit tests for theme management

package test_wayu

import "core:testing"
import "core:fmt"
import "core:os"
import "core:strings"
import wayu "../../src"

@(test)
test_theme_type_from_string :: proc(t: ^testing.T) {
	// Test theme type parsing
	testing.expect_value(t, wayu.theme_type_from_string("minimal"), wayu.ThemeType.Minimal)
	testing.expect_value(t, wayu.theme_type_from_string("powerline"), wayu.ThemeType.Powerline)
	testing.expect_value(t, wayu.theme_type_from_string("starship"), wayu.ThemeType.Starship)
	testing.expect_value(t, wayu.theme_type_from_string("custom"), wayu.ThemeType.Custom)
	testing.expect_value(t, wayu.theme_type_from_string("unknown"), wayu.ThemeType.Custom)
}

@(test)
test_theme_type_to_string :: proc(t: ^testing.T) {
	// Test theme type to string conversion
	testing.expect_value(t, wayu.theme_type_to_string(wayu.ThemeType.Minimal), "minimal")
	testing.expect_value(t, wayu.theme_type_to_string(wayu.ThemeType.Powerline), "powerline")
	testing.expect_value(t, wayu.theme_type_to_string(wayu.ThemeType.Starship), "starship")
	testing.expect_value(t, wayu.theme_type_to_string(wayu.ThemeType.Custom), "custom")
}

@(test)
test_is_built_in_theme :: proc(t: ^testing.T) {
	// Test built-in theme detection
	testing.expect(t, wayu.is_built_in_theme("minimal"))
	testing.expect(t, wayu.is_built_in_theme("powerline"))
	testing.expect(t, wayu.is_built_in_theme("default"))
	testing.expect(t, !wayu.is_built_in_theme("my-custom-theme"))
	testing.expect(t, !wayu.is_built_in_theme("starship"))
}

@(test)
test_parse_theme_action :: proc(t: ^testing.T) {
	// Test theme action parsing
	testing.expect_value(t, wayu.parse_theme_action("list"), wayu.ThemeAction.LIST)
	testing.expect_value(t, wayu.parse_theme_action("ls"), wayu.ThemeAction.LIST)
	testing.expect_value(t, wayu.parse_theme_action("add"), wayu.ThemeAction.ADD)
	testing.expect_value(t, wayu.parse_theme_action("remove"), wayu.ThemeAction.REMOVE)
	testing.expect_value(t, wayu.parse_theme_action("rm"), wayu.ThemeAction.REMOVE)
	testing.expect_value(t, wayu.parse_theme_action("enable"), wayu.ThemeAction.ENABLE)
	testing.expect_value(t, wayu.parse_theme_action("get-active"), wayu.ThemeAction.GET_ACTIVE)
	testing.expect_value(t, wayu.parse_theme_action("active"), wayu.ThemeAction.GET_ACTIVE)
	testing.expect_value(t, wayu.parse_theme_action("help"), wayu.ThemeAction.HELP)
	testing.expect_value(t, wayu.parse_theme_action("-h"), wayu.ThemeAction.HELP)
	testing.expect_value(t, wayu.parse_theme_action("unknown"), wayu.ThemeAction.UNKNOWN)
}

@(test)
test_validate_theme_name :: proc(t: ^testing.T) {
	// Test valid theme names
	result1 := wayu.validate_theme_name("my-theme")
	testing.expect(t, result1.valid)
	delete(result1.error_message)

	result2 := wayu.validate_theme_name("my_theme")
	testing.expect(t, result2.valid)
	delete(result2.error_message)

	result3 := wayu.validate_theme_name("theme123")
	testing.expect(t, result3.valid)
	delete(result3.error_message)

	// Test invalid theme names
	result4 := wayu.validate_theme_name("")
	testing.expect(t, !result4.valid)
	delete(result4.error_message)

	result5 := wayu.validate_theme_name("my theme")  // space not allowed
	testing.expect(t, !result5.valid)
	delete(result5.error_message)

	result6 := wayu.validate_theme_name("my.theme")  // dot not allowed
	testing.expect(t, !result6.valid)
	delete(result6.error_message)

	// Test long name
	long_name := strings.repeat("a", 65)
	result7 := wayu.validate_theme_name(long_name)
	testing.expect(t, !result7.valid)
	delete(result7.error_message)
	delete(long_name)
}

@(test)
test_theme_type_from_name :: proc(t: ^testing.T) {
	// Test theme type from name
	testing.expect_value(t, wayu.theme_type_from_name("minimal"), wayu.ThemeType.Minimal)
	testing.expect_value(t, wayu.theme_type_from_name("powerline"), wayu.ThemeType.Powerline)
	testing.expect_value(t, wayu.theme_type_from_name("starship"), wayu.ThemeType.Starship)
	testing.expect_value(t, wayu.theme_type_from_name("custom"), wayu.ThemeType.Custom)
	testing.expect_value(t, wayu.theme_type_from_name("unknown"), wayu.ThemeType.Custom)
}

@(test)
test_get_built_in_theme_content :: proc(t: ^testing.T) {
	// Test that built-in themes return content
	minimal_content := wayu.get_built_in_theme_content("minimal")
	testing.expect(t, len(minimal_content) > 0)
	testing.expect(t, strings.contains(minimal_content, "name = \"minimal\""))

	powerline_content := wayu.get_built_in_theme_content("powerline")
	testing.expect(t, len(powerline_content) > 0)
	testing.expect(t, strings.contains(powerline_content, "name = \"powerline\""))

	default_content := wayu.get_built_in_theme_content("default")
	testing.expect(t, len(default_content) > 0)
	testing.expect(t, strings.contains(default_content, "name = \"default\""))

	// Test unknown theme returns empty
	unknown_content := wayu.get_built_in_theme_content("unknown")
	testing.expect(t, len(unknown_content) == 0)
}

@(test)
test_generate_custom_theme_template :: proc(t: ^testing.T) {
	// Test custom theme template generation
	template := wayu.generate_custom_theme_template("my-theme")
	defer delete(template)

	testing.expect(t, strings.contains(template, "name = \"my-theme\""))
	testing.expect(t, strings.contains(template, "type = \"custom\""))
	testing.expect(t, strings.contains(template, "[colors]"))
	testing.expect(t, strings.contains(template, "primary = \"cyan\""))
}

@(test)
test_generate_starship_toml :: proc(t: ^testing.T) {
	// Test starship config generation
	config := wayu.generate_starship_toml()
	// Note: generate_starship_toml returns a static string literal, don't delete

	testing.expect(t, len(config) > 0)
	testing.expect(t, strings.contains(config, "format ="))
	testing.expect(t, strings.contains(config, "[character]"))
	testing.expect(t, strings.contains(config, "[directory]"))
	testing.expect(t, strings.contains(config, "[git_branch]"))
}

@(test)
test_generate_theme_shell_config :: proc(t: ^testing.T) {
	// Test theme shell config generation for built-in themes
	minimal_config := wayu.generate_theme_shell_config("minimal")
	testing.expect(t, len(minimal_config) > 0)
	testing.expect(t, strings.contains(minimal_config, "WAYU THEME BEGIN"))
	testing.expect(t, strings.contains(minimal_config, "WAYU THEME END"))
	delete(minimal_config)

	starship_config := wayu.generate_starship_shell_config()
	testing.expect(t, len(starship_config) > 0)
	testing.expect(t, strings.contains(starship_config, "WAYU THEME BEGIN"))
	testing.expect(t, strings.contains(starship_config, "starship"))
	delete(starship_config)
}
