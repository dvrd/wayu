package wayu_tui

import "core:os"

// Poll for events (non-blocking)
poll_event :: proc() -> Event {
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
