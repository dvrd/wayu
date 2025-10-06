package wayu

import "core:log"

debug :: proc(msg: string, args: ..any) {
	log.debugf(msg, ..args)
}
