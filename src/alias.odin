// alias.odin - ALIAS entry management (refactored to use config_entry abstraction)
//
// This module manages ALIAS entries using the generic config_entry system.
// LIST is augmented with external alias sources (alias-sources.conf).
// All other operations are delegated to the generic handler.

package wayu

// Main handler for ALIAS commands - delegates to generic handler.
// For LIST, also appends external alias source sections.
handle_alias_command :: proc(action: Action, args: []string) {
	handle_config_command(&ALIAS_SPEC, action, args)

	if action == .LIST {
		print_external_alias_sources()
	}
}
