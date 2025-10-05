package wayu

import "core:log"

// Build-time debug configuration
DEBUG :: #config(DEBUG, false)

debug :: proc(msg: string, args: ..any) {
	when DEBUG {
		log.debugf(msg, ..args)
	}
}