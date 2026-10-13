"""P1/P2: a skip-update request reaches only its own PTY child, and only for the menu it named."""
import base64
import os
import pty
import re
import select
import signal
import sys
import time

children = []


def spawn(mode):
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(sys.argv[1], [sys.argv[1], '--codex-startup-pty-fixture', mode])
    children.append((pid, fd))
    return pid, fd


def drain(fds):
    """All at once: a fixture whose output nobody reads for a second drops it (the relay's write deadline)."""
    data = {fd: b'' for fd in fds}
    open_fds = set(fds)
    deadline = time.monotonic() + 15
    while open_fds and time.monotonic() < deadline:
        for fd in select.select(list(open_fds), [], [], .1)[0]:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                chunk = b''
            if chunk:
                data[fd] += chunk
            else:
                open_fds.discard(fd)
    return data


def parse(data):
    result = re.search(rb'RESULT (\S+) receipt=(\S+) spawned=(\S+) leftover=(\S+)', data)
    sent = re.search(rb'BYTES ([A-Za-z0-9+/=]*)', data)
    assert result and sent, 'fixture output incomplete: %r' % data[-300:]
    return [g.decode() for g in result.groups()], base64.b64decode(sent.group(1))


try:
    target, sibling, stale = spawn('match'), spawn('none'), spawn('stale')
    read = drain([target[1], sibling[1], stale[1]])
    outputs = {'target': read[target[1]], 'sibling': read[sibling[1]], 'stale': read[stale[1]]}
    for pid, _ in children:
        assert os.waitpid(pid, 0)[1] == 0, 'fixture exited non-zero'
    (result, receipt, spawned, leftover), typed = parse(outputs['target'])
    assert (result, receipt, spawned, leftover) == ('sent', 'sent', 'true', 'false'), (result, receipt, spawned, leftover)
    assert typed == b'\x1b', typed
    print("PASS: P1 skip-update types Esc alone (codex's Skip, whichever row is selected) into its own PTY child, receipts sent, starts Tally's background update")
    (result, _, _, _), typed = parse(outputs['sibling'])
    assert result == 'none' and typed == b'', typed
    print('PASS: P1 the sibling PTY receives no byte')
    (result, receipt, spawned, leftover), typed = parse(outputs['stale'])
    assert (result, receipt, spawned, leftover) == ('stale-screen', 'stale-screen', 'false', 'false'), (result, receipt)
    assert typed == b'', typed
    print('PASS: P2 a request naming another drawing of the menu types nothing and receipts stale-screen')
finally:
    for pid, fd in children:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
        os.close(fd)
