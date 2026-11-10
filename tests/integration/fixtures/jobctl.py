# Minimal job-control parent for terminal tests (test_secrets_store.rb):
# runs argv in its own foreground process group on this terminal (a process
# group that can be stopped: not orphaned), prints the terminal's echo state
# when the child stops and when it exits, and continues a stopped child after
# a line on stdin.
#
#   python3 jobctl.py PROGRAM [ARGS...]
#   -> "TTY <name>", "STOPPED echo-on|echo-off", "EXITED echo-on|echo-off"
import os
import signal
import subprocess
import sys


def echo_state():
    out = subprocess.run(["stty", "-a"], capture_output=True, text=True).stdout
    flags = " " + out.replace("\n", " ").replace("\t", " ") + " "
    return "echo-off" if " -echo " in flags else "echo-on"


signal.signal(signal.SIGTTOU, signal.SIG_IGN)
print("TTY " + os.ttyname(0), flush=True)
pid = os.fork()
if pid == 0:
    os.setpgid(0, 0)
    os.tcsetpgrp(0, os.getpid())
    signal.signal(signal.SIGTTOU, signal.SIG_DFL)
    os.execv(sys.argv[1], sys.argv[1:])
try:
    os.setpgid(pid, pid)
except OSError:
    pass
while True:
    _, status = os.waitpid(pid, os.WUNTRACED)
    os.tcsetpgrp(0, os.getpgrp())
    if os.WIFSTOPPED(status):
        print("\nSTOPPED " + echo_state(), flush=True)
        sys.stdin.readline()
        os.tcsetpgrp(0, pid)
        os.kill(pid, signal.SIGCONT)
        continue
    print("\nEXITED " + echo_state(), flush=True)
    break
