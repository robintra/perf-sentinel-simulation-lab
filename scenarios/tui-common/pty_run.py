"""Drive a TUI headlessly and capture what it draws.

`script(1)` needs a tty on its own stdin, which a make log does not have, so it
hands the child a 0x0 window and the TUI renders nothing. openpty sets a real
window size, and this driver can also type into the pty, which the monitor
needs because it opens on the Advisor tab.

Usage: pty_run.py <secs> <cols> <rows> <keys_delay_secs> <keys> <cmd> [args...]
       <keys> is sent once after <keys_delay_secs>. Pass "" to send nothing.
"""

import fcntl, os, pty, select, signal, struct, subprocess, sys, termios, time

secs = float(sys.argv[1])
cols, rows = int(sys.argv[2]), int(sys.argv[3])
keys_delay, keys = float(sys.argv[4]), sys.argv[5]
argv = sys.argv[6:]

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
p = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave, close_fds=True)
os.close(slave)

out = bytearray()
start = time.time()
deadline = start + secs
keys_at = start + keys_delay if keys else None

while True:
    left = deadline - time.time()
    if left <= 0:
        break
    if keys_at is not None and time.time() >= keys_at:
        os.write(master, keys.encode())
        keys_at = None
    # select, not a bare read: a TUI that stops redrawing would block past
    # the deadline and hang the scenario.
    if not select.select([master], [], [], min(left, 0.5))[0]:
        continue
    try:
        chunk = os.read(master, 65536)
    except OSError:
        break
    if not chunk:
        break
    out += chunk

p.send_signal(signal.SIGTERM)
try:
    p.wait(timeout=5)
except subprocess.TimeoutExpired:
    p.kill()
os.write(1, bytes(out))
