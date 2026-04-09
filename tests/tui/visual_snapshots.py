#!/usr/bin/env python3
"""Visual snapshot of TUI at different terminal sizes."""
import os, pty, time, select, struct, fcntl, termios, pyte

WAYU_BIN = os.environ.get("WAYU_BIN", "bin/wayu_debug")

def capture(cols, rows, keys, label):
    master_fd, slave_fd = pty.openpty()
    fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    pid = os.fork()
    if pid == 0:
        os.close(master_fd); os.setsid()
        fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)
        os.dup2(slave_fd, 0); os.dup2(slave_fd, 1); os.dup2(slave_fd, 2)
        if slave_fd > 2: os.close(slave_fd)
        os.environ["COLUMNS"] = str(cols)
        os.environ["LINES"] = str(rows)
        os.execvp(WAYU_BIN, [WAYU_BIN, "--tui"])
    os.close(slave_fd)
    screen = pyte.Screen(cols, rows)
    stream = pyte.Stream(screen)

    def feed(timeout=1.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            ready, _, _ = select.select([master_fd], [], [], 0.05)
            if ready:
                data = os.read(master_fd, 65536)
                if b"\x1b[6n" in data:
                    os.write(master_fd, f"\x1b[{rows};{cols}R".encode())
                if data:
                    stream.feed(data.decode("utf-8", errors="replace"))

    # Wait for DSR query and respond, then wait for full render
    feed(timeout=0.5)   # capture DSR query
    feed(timeout=2.0)   # capture full render after DSR response

    for k in keys:
        os.write(master_fd, k)
        feed(timeout=0.5)
    sep = "=" * 60
    print(f"\n{sep}")
    print(f"  {label} ({cols}x{rows})")
    print(sep)
    for line in screen.display:
        s = line.rstrip()
        if s:
            print(s)
    os.write(master_fd, b"q")
    time.sleep(0.1)
    os.kill(pid, 9)
    os.waitpid(pid, 0)

# Main Menu
for c, r in [(80,24), (60,20), (50,18), (40,14)]:
    capture(c, r, [], "Main Menu")

# PATH View
for c, r in [(80,24), (60,20), (50,18), (40,14)]:
    capture(c, r, [b"l"], "PATH View")

# Alias View
for c, r in [(80,24), (60,20), (50,18)]:
    capture(c, r, [b"j", b"l"], "Alias View")

# Plugins View (Registry tab)
for c, r in [(80,24), (60,20)]:
    capture(c, r, [b"j", b"j", b"j", b"j", b"j", b"l", b"\t"], "Plugins Registry")

# Settings View
for c, r in [(80,24), (60,20), (50,18), (40,14)]:
    capture(c, r, [b"j"]*6 + [b"l"], "Settings View")

# Add Form overlay (from PATH view)
for c, r in [(80,24), (60,20), (50,18)]:
    capture(c, r, [b"l", b"a"], "Add Form (PATH)")
