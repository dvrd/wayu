// alias.odin - ALIAS entry management (refactored to use config_entry abstraction)
//
// This module manages ALIAS entries using the generic config_entry system.
// All operations are delegated to the generic handler.

package wayu

// Main handler for ALIAS commands - delegates to generic handler
handle_alias_command :: proc(action: Action, args: []string) {
	// All actions (ADD, REMOVE, LIST, HELP) are handled generically
	handle_config_command(&ALIAS_SPEC, action, args)
}
