package wayu

import "core:fmt"
import "core:log"

// Build-time debug configuration
DEBUG :: #config(DEBUG, false)

debug_log :: proc(msg: string, args: ..any) {
	when DEBUG {
		log.debugf(msg, ..args)
	}
}

debug :: proc(msg: string, args: ..any) {
	when DEBUG {
		fmt.printf("[DEBUG] ")
		fmt.printf(msg, ..args)
		fmt.println()
	}
}

debug_error :: proc(msg: string, args: ..any) {
	when DEBUG {
		log.errorf(msg, ..args)
	}
}

init_debug :: proc() {
	when DEBUG {
		// Debug mode initialized (no output message)
	}
}