#!/usr/bin/env python3
"""Debug script to understand what the TUI outputs on startup."""

import os, sys, pty, time, select, struct, fcntl, termios

WAYU_BIN = os.environ.get("WAYU_BIN", os.path.join(os.path.dirname(__file__), "..", "..", "bin", "wayu_debug"))

def main():
    cols, rows = 80, 24
    master_fd, slave_fd = pty.openpty()
    winsize = struct.pack("HHHH", rows, cols, 0, 0)
    fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, winsize)

    pid = os.fork()
    if pid == 0:
        os.close(master_fd)
        os.setsid()
        fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)
        os.dup2(slave_fd, 0)
        os.dup2(slave_fd, 1)
        os.dup2(slave_fd, 2)
        if slave_fd > 2:
            os.close(slave_fd)
        os.execvp(WAYU_BIN, [WAYU_BIN, "--tui"])

    os.close(slave_fd)

    # Read raw bytes
    all_data = b""
    deadline = time.time() + 5.0
    while time.time() < deadline:
        ready, _, _ = select.select([master_fd], [], [], 0.1)
        if ready:
            try:
                data = os.read(master_fd, 65536)
                if data:
                    all_data += data
                    print(f"--- Read {len(data)} bytes (total: {len(all_data)}) ---")
            except OSError:
                break

    # Kill TUI
    try:
        os.write(master_fd, b"q")
        time.sleep(0.1)
    except: pass
    try: os.close(master_fd)
    except: pass
    try: os.kill(pid, 9); os.waitpid(pid, os.WNOHANG)
    except: pass

    print(f"\n=== Total: {len(all_data)} bytes ===")
    
    ESC_BRACKET = b"\x1b["
    
    # Check for known sequences
    if b"\x1b[?1049h" in all_data:
        print("✓ Alt screen enter sequence found")
    if b"\x1b[?25l" in all_data:
        print("✓ Cursor hide sequence found")
    if ESC_BRACKET in all_data:
        esc_count = all_data.count(ESC_BRACKET)
        print(f"✓ ANSI escape sequences found ({esc_count} occurrences)")
    if b"WAYU" in all_data:
        idx = all_data.index(b"WAYU")
        print(f"✓ 'WAYU' found at byte offset {idx}")
        start = max(0, idx - 20)
        end = min(len(all_data), idx + 30)
        print(f"  Context: {all_data[start:end]!r}")
    else:
        print("✗ 'WAYU' NOT found in output!")
    
    # Check for box drawing characters
    box_top_left = b"\xe2\x95\xad"  # ╭ U+256D
    if box_top_left in all_data:
        print("✓ Box corner ╭ (U+256D) found")
    if b"PATH" in all_data:
        print("✓ 'PATH' found")

    # Show first 500 bytes as repr
    print(f"\n=== First 500 bytes ===")
    print(repr(all_data[:500]))
    print(f"\n=== Last 500 bytes ===")
    print(repr(all_data[-500:]))

if __name__ == "__main__":
    main()
