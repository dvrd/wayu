package wayu

import "core:fmt"
import "core:strings"

Native_Location :: struct {
	path: string,
	line: int,
}

Native_Definition :: struct {
	body:     string,
	location: Native_Location,
}

native_define :: proc(s: ^Native_Session, name, body: string, line: int) {
	definition := Native_Definition {
		body     = strings.clone(body),
		location = {strings.clone(s.location.path), line},
	}

	if previous, found := s.definitions[name]; found {
		delete(previous.body)
		delete(previous.location.path)
		entry := &s.definitions[name]
		entry^ = definition
	} else {
		s.definitions[strings.clone(name)] = definition
	}
}

native_eval_at :: proc(s: ^Native_Session, source: string, location: Native_Location) {
	previous := s.location
	s.location = location
	defer s.location = previous

	native_eval(s, source)
}

native_location_label :: proc(location: Native_Location) -> string {
	if location.path == "" {
		return "wayu"
	}

	return fmt.tprintf("%s, line %d", location.path, max(1, location.line))
}

native_should_explain :: proc(s: ^Native_Session) -> bool {
	return !s.tested_status && !s.quiet_failure
}

native_report_failure :: proc(s: ^Native_Session, command: string) {
	if s.pipeline_child {
		return
	}

	label := native_location_label(s.location)
	action :=
		"Execution stopped here." if s.location.path != "" else "The current command stopped."
	fmt.eprintfln(
		"%s: %s exited with status %d. %s",
		label,
		command if command != "" else "The command",
		s.status,
		action,
	)
}
