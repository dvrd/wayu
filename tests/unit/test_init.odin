package test_wayu

import "core:testing"
import "core:strings"
import "core:os"
import wayu "../../src"

@(test)
test_parse_args_init :: proc(t: ^testing.T) {
	args := []string{"init"}
	parsed := wayu.parse_args(args)

	testing.expect_value(t, parsed.command, wayu.Command.INIT)
}

@(test)
test_zshrc_detection_patterns :: proc(t: ^testing.T) {
	// Test different ways wayu might be sourced in .zshrc
	test_contents := []string{
		`source "/Users/test/.config/wayu/init.zsh"`,
		`source /Users/test/.config/wayu/init.zsh`,
		`source "$HOME/.config/wayu/init.zsh"`,
		`source $HOME/.config/wayu/init.zsh`,
	}

	for content in test_contents {
		has_wayu := strings.contains(content, "wayu/init.zsh") ||
		            strings.contains(content, "wayu") && strings.contains(content, "source")
		testing.expect(t, has_wayu, "Should detect wayu in .zshrc")
	}
}

@(test)
test_zshrc_without_wayu :: proc(t: ^testing.T) {
	test_content := `# My .zshrc
export PATH="/usr/local/bin:$PATH"
alias ll="ls -la"
# Some other config
`

	// Should not contain wayu references
	has_wayu := strings.contains(test_content, "wayu")
	testing.expect(t, !has_wayu, "Should not detect wayu in clean .zshrc")
}

@(test)
test_template_structure :: proc(t: ^testing.T) {
	// Test that templates have proper structure
	testing.expect(t, strings.has_prefix(wayu.PATH_TEMPLATE, "#!/usr/bin/env zsh"),
		"PATH_TEMPLATE should have zsh shebang")
	testing.expect(t, strings.has_prefix(wayu.ALIASES_TEMPLATE, "#!/usr/bin/env zsh"),
		"ALIASES_TEMPLATE should have zsh shebang")
	testing.expect(t, strings.has_prefix(wayu.CONSTANTS_TEMPLATE, "#!/usr/bin/env zsh"),
		"CONSTANTS_TEMPLATE should have zsh shebang")
	testing.expect(t, strings.has_prefix(wayu.INIT_TEMPLATE, "#!/usr/bin/env zsh"),
		"INIT_TEMPLATE should have zsh shebang")
	testing.expect(t, strings.has_prefix(wayu.TOOLS_TEMPLATE, "#!/usr/bin/env zsh"),
		"TOOLS_TEMPLATE should have zsh shebang")
}

@(test)
test_init_template_loads_all_configs :: proc(t: ^testing.T) {
	// Verify init template sources all required files
	testing.expect(t, strings.contains(wayu.INIT_TEMPLATE, "constants.zsh"),
		"INIT_TEMPLATE should source constants.zsh")
	testing.expect(t, strings.contains(wayu.INIT_TEMPLATE, "path.zsh"),
		"INIT_TEMPLATE should source path.zsh")
	testing.expect(t, strings.contains(wayu.INIT_TEMPLATE, "aliases.zsh"),
		"INIT_TEMPLATE should source aliases.zsh")
	testing.expect(t, strings.contains(wayu.INIT_TEMPLATE, "tools.zsh"),
		"INIT_TEMPLATE should source tools.zsh")
}

@(test)
test_init_template_order :: proc(t: ^testing.T) {
	// Verify init template loads files in correct order
	constants_pos := strings.index(wayu.INIT_TEMPLATE, "constants.zsh")
	path_pos := strings.index(wayu.INIT_TEMPLATE, "path.zsh")
	aliases_pos := strings.index(wayu.INIT_TEMPLATE, "aliases.zsh")
	tools_pos := strings.index(wayu.INIT_TEMPLATE, "tools.zsh")

	// Constants should load first
	testing.expect(t, constants_pos < path_pos, "Constants should load before PATH")
	testing.expect(t, path_pos < aliases_pos, "PATH should load before aliases")
	testing.expect(t, aliases_pos < tools_pos, "Aliases should load before tools")
}

@(test)
test_path_template_has_add_function :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(wayu.PATH_TEMPLATE, "add_to_path()"),
		"PATH_TEMPLATE should contain add_to_path function")
	testing.expect(t, strings.contains(wayu.PATH_TEMPLATE, "export PATH="),
		"PATH_TEMPLATE should export PATH")
}

@(test)
test_tools_template_has_examples :: proc(t: ^testing.T) {
	// Verify tools template has useful commented examples
	testing.expect(t, strings.contains(wayu.TOOLS_TEMPLATE, "NVM"),
		"TOOLS_TEMPLATE should mention NVM")
	testing.expect(t, strings.contains(wayu.TOOLS_TEMPLATE, "Starship") ||
	               strings.contains(wayu.TOOLS_TEMPLATE, "starship"),
		"TOOLS_TEMPLATE should mention Starship")
	testing.expect(t, strings.contains(wayu.TOOLS_TEMPLATE, "Zoxide") ||
	               strings.contains(wayu.TOOLS_TEMPLATE, "zoxide"),
		"TOOLS_TEMPLATE should mention Zoxide")
}
