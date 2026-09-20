"""Exercise the production injector on two isolated PTYs, never a user's terminal."""
import base64
import os
import pty
import select
import signal
import sys
import time


children = []
reaped = set()

def spawn(text):
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(sys.argv[1], [sys.argv[1], '--codex-input-pty-fixture', text])
    children.append((pid, fd))
    return pid, fd


def line(fd):
    data = b''
    deadline = time.monotonic() + 10
    while b'\n' not in data:
        assert time.monotonic() < deadline, 'PTY fixture timed out'
        if select.select([fd], [], [], .1)[0]:
            chunk = os.read(fd, 1)
            assert chunk, 'PTY fixture exited before its receipt'
            data += chunk
    return data.strip().replace(b"\x1b[?2004h", b"")


try:
    a, b = spawn('target A'), spawn('sibling B')
    assert line(a[1]) == b'READY' and line(b[1]) == b'READY'
    os.kill(a[0], signal.SIGUSR1)
    time.sleep(.1)
    os.write(a[1], b"HUMAN")
    assert base64.b64decode(line(a[1])) == b'\x1b[200~target A\x1b[201~\rHUMAN'
    assert not select.select([b[1]], [], [], .2)[0], 'Sibling PTY received target input'
    os.kill(b[0], signal.SIGUSR1)
    time.sleep(.1)
    os.write(b[1], b"HUMAN")
    assert base64.b64decode(line(b[1])) == b'\x1b[200~sibling B\x1b[201~\rHUMAN'
    c = spawn("cancel")
    assert line(c[1]) == b"READY"
    os.kill(c[0], signal.SIGUSR1)
    time.sleep(.1)
    os.write(c[1], b"HUMAN")
    assert base64.b64decode(line(c[1])) == b"\x1b[200~cancel\x1b[201~HUMAN", "Interrupted paste must never press Enter"
    for pid, _ in children:
        status = os.waitpid(pid, 0)[1]
        reaped.add(pid)
        assert status == 0
    print('PASS: Codex input uses exact isolated PTY, preserves sibling, serializes concurrent human input after Enter, and rejects stale generation')
finally:
    for pid, fd in children:
        try:
            if pid not in reaped:
                os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
        os.close(fd)
