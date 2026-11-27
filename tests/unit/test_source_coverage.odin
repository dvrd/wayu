package test_wayu

import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
test_each_source_file_has_unit_tests :: proc(t: ^testing.T) {
	sources := #load_directory("../../src")
	units := #load_directory(".")
	tested := make(map[string]bool, context.temp_allocator)
	for unit in units {
		content := string(unit.data)
		for line in strings.split_lines_iterator(&content) {
			if strings.trim_space(line) == "@(test)" {
				tested[unit.name] = true
				break
			}
		}
	}

	for source in sources {
		if strings.has_suffix(source.name, ".odin") {
			name := fmt.tprintf("test_%s", source.name)
			testing.expectf(
				t,
				tested[name],
				"%s needs an active unit test in %s",
				source.name,
				name,
			)
		}
	}
}
