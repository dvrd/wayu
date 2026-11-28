package wayu

import "base:intrinsics"
import "core:fmt"
import "core:strings"

Native_Deferred :: struct {
	command:  string,
	location: Native_Location,
}

// A deferred command outlives the parser and its expansion arena. Quote each
// expanded argument independently to preserve empty words and literal operators.
native_register_defer :: proc(
	s: ^Native_Session,
	args: []string,
	redirects: []Native_Redirect,
) -> int {
	if len(args) == 0 || args[0] == "" {
		fmt.eprintln("defer needs a command to run when this scope ends")
		return EXIT_USAGE
	}

	command := strings.builder_make(context.temp_allocator)
	for arg, i in args {
		if i != 0 {
			strings.write_byte(&command, ' ')
		}

		strings.write_string(&command, shell_quote(arg, .ZSH))
	}

	for redir in redirects {
		path, ok := native_expand(redir.path, s.status, false, s)
		if !ok || strings.contains(path, "\x00") {
			if s.expansion_failure == 0 && native_should_explain(s) {
				fmt.eprintln("defer could not expand the redirection target")
			}

			return max(EXIT_FAILURE, s.expansion_failure)
		}

		fmt.sbprintf(&command, " %d%s%s", redir.target, redir.op, shell_quote(path, .ZSH))
	}

	location := s.location
	location.path = strings.clone(location.path)
	append(&s.deferred, Native_Deferred{strings.clone(strings.to_string(command)), location})
	return EXIT_SUCCESS
}

native_run_deferred :: proc(s: ^Native_Session, mark: int) {
	if len(s.deferred) <= mark {
		return
	}

	status := s.status
	sigpipe := s.failure_sigpipe
	unhandled := s.unhandled
	exiting, returning, loop_action := s.exiting, s.returning, s.loop_action
	tested, quiet := s.tested_status, s.quiet_failure
	s.quiet_failure = quiet || tested
	interrupted := intrinsics.volatile_load(&native_interrupted)

	for len(s.deferred) > mark {
		cleanup := pop(&s.deferred)
		s.exiting, s.returning, s.loop_action = false, false, .None
		s.unhandled, s.tested_status = false, false
		s.status = 0
		intrinsics.volatile_store(&native_interrupted, false)
		native_eval_at(s, cleanup.command, cleanup.location)
		if status == 0 && s.status != 0 {
			status = s.status
			sigpipe = s.failure_sigpipe
			unhandled = s.unhandled
		}

		delete(cleanup.command)
		delete(cleanup.location.path)
	}

	intrinsics.volatile_store(&native_interrupted, interrupted)
	s.failure_sigpipe = sigpipe
	s.quiet_failure, s.tested_status = quiet, tested
	s.status, s.unhandled = status, unhandled && !tested
	s.exiting, s.returning, s.loop_action = exiting, returning, loop_action
}
