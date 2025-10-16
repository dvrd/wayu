// constants.odin - CONSTANTS entry management (refactored to use config_entry abstraction)
//
// This module manages CONSTANTS entries using the generic config_entry system.
// All operations are delegated to the generic handler.

package wayu

// Main handler for CONSTANTS commands - delegates to generic handler
handle_constants_command :: proc(action: Action, args: []string) {
	// All actions (ADD, REMOVE, LIST, HELP) are handled generically
	handle_config_command(&CONSTANTS_SPEC, action, args)
}
