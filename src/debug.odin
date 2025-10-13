package wayu

import "core:log"

// Debug logging that only activates when built with -define:DEBUG=true
debug :: proc(msg: string, args: ..any) {
	when ODIN_DEBUG {
		log.debugf(msg, ..args)
	}
}
