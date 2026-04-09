package wayu_tui

import "core:os"
import "core:c"
import "core:time"

foreign import libc "system:c"

foreign libc {
    select :: proc(nfds: c.int, readfds: rawptr, writefds: rawptr, errorfds: rawptr, timeout: rawptr) -> c.int ---
}

// timeval struct for select timeout
timeval :: struct {
    tv_sec:  c.long,
    tv_usec: c.long,
}

// fd_set manipulation for select
FD_SETSIZE :: 1024

@(private)
fd_set :: struct #raw_union {
    bits: [FD_SETSIZE / (8 * size_of(c.long))]c.long,
}

@(private)
fd_zero :: proc(set: ^fd_set) {
    for i in 0..<len(set.bits) {
        set.bits[i] = 0
    }
}

@(private)
fd_set_bit :: proc(set: ^fd_set, fd: c.int) {
    set.bits[fd / (8 * size_of(c.long))] |= 1 << (uint(fd) % (8 * size_of(c.long)))
}

@(private)
fd_isset :: proc(set: ^fd_set, fd: c.int) -> bool {
    return (set.bits[fd / (8 * size_of(c.long))] >> (uint(fd) % (8 * size_of(c.long)))) & 1 != 0
}

// Poll for events with timeout (non-blocking)
// Returns: Event if available, nil if timeout or no data
poll_event :: proc() -> Event {
    // Use select with 50ms timeout to allow periodic resize checks
    readfds: fd_set
    fd_zero(&readfds)
    fd_set_bit(&readfds, c.int(STDIN_FILENO))

    timeout := timeval{
        tv_sec  = 0,
        tv_usec = 50_000,  // 50ms
    }

    ready := select(c.int(STDIN_FILENO) + 1, &readfds, nil, nil, &timeout)

    // No data available (timeout)
    if ready <= 0 {
        return nil
    }

    // Data available on stdin
    input_buf: [8]byte
    n, err := os.read(os.stdin, input_buf[:])

    if err != nil || n == 0 {
        return nil
    }

    if key, ok := parse_key_event(input_buf[:], n); ok {
        return key
    }

    return nil
}
