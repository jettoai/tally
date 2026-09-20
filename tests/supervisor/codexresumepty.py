"""Exercise the resumed-Codex initializer through two isolated production supervisors.

This is a native-contract fixture: its child is a local terminal endpoint, not Codex's service.
It proves the wrapper creates a current binding/lifecycle before a human bootstrap, and that the
production queue, private PTY, receipt and audit paths deliver to one exact supervisor only.
"""
import json
import os
import pty
import select
import signal
import shutil
import subprocess
import sys
import tempfile
import time


binary = sys.argv[1]
children = []
reaped = set()
terminal_output = {}


def spawn(session_id, home):
    env = os.environ.copy()
    env["HOME"] = home
    env["CFFIXED_USER_HOME"] = home
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(binary, [binary, "--codex-resume-pty-fixture", session_id], env)
    children.append((pid, fd))
    terminal_output[pid] = bytearray()
    return pid, fd


def read_json(path):
    try:
        with open(path, encoding="utf-8") as source:
            return json.load(source)
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def wait_for(label, predicate, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        drain()
        time.sleep(.05)
    raise AssertionError("timed out waiting for " + label)


def drain():
    for _, fd in children:
        while select.select([fd], [], [], 0)[0]:
            try:
                chunk = os.read(fd, 4096)
                if not chunk:
                    break
                terminal_output[_] += chunk
            except OSError:
                break


def write_request(path, epoch, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temporary = path + ".fixture-tmp"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(descriptor, json.dumps({"epoch": epoch, "text": text}).encode())
    finally:
        os.close(descriptor)
    os.replace(temporary, path)


def user_receipts(path, text):
    hits = 0
    with open(path, encoding="utf-8") as source:
        for raw in source:
            row = json.loads(raw)
            payload = row.get("payload", {})
            item = payload.get("item", {})
            content = item.get("content", [])
            if (row.get("type") == "event_msg" and payload.get("type") == "item_completed"
                    and item.get("type") == "UserMessage" and len(content) == 1
                    and content[0].get("text") == text):
                hits += 1
    return hits


root = tempfile.mkdtemp(prefix="tally-codex-resume-pty-")
succeeded = False
try:
    home = os.path.join(root, "home")
    os.makedirs(home)
    target_id = "11111111-1111-4111-8111-111111111111"
    sibling_id = "22222222-2222-4222-8222-222222222222"
    target, _ = spawn(target_id, home)
    sibling, _ = spawn(sibling_id, home)
    state = os.path.join(home, ".tally", "supervisor-state")

    def ready(pid, session_id):
        monitor = read_json(os.path.join(state, str(pid) + ".monitoring"))
        reading = read_json(os.path.join(state, str(pid) + ".state"))
        binding = read_json(os.path.join(state, str(pid) + ".codex-binding"))
        return (monitor is not None and bool(monitor.get("inputTTY"))
                and reading is not None and reading.get("state") == "idle"
                and binding is not None and binding.get("sessionID") == session_id)

    def actions(pid):
        env = os.environ.copy()
        env["HOME"] = home
        env["CFFIXED_USER_HOME"] = home
        return json.loads(subprocess.check_output(
            [binary, "--codex-resume-actions", str(pid)], env=env, text=True))

    wait_for("both historical resumes to become send-capable without keyboard input",
             lambda: (ready(target, target_id) and ready(sibling, sibling_id)
                      and actions(target) == ["send"] and actions(sibling) == ["send"]))

    # This request names only the target supervisor. The sibling receives no request at all.
    text = "TALLY_RESUME_DIRECT_TARGET"
    epoch = int(time.time() * 1000)
    request_dir = os.path.join(home, ".tally", "input")
    write_request(os.path.join(request_dir, str(target)), epoch, text)
    result_path = os.path.join(request_dir, str(target) + ".result")
    wait_for("the target's native receipt", lambda: read_json(result_path) is not None)
    result = read_json(result_path)
    assert result.get("epoch") == epoch and result.get("outcome") == "submitted", result
    target_rollout = os.path.join(home, "codex-resume-fixture", "sessions",
                                  "rollout-" + target_id + ".jsonl")
    sibling_rollout = os.path.join(home, "codex-resume-fixture", "sessions",
                                   "rollout-" + sibling_id + ".jsonl")
    assert user_receipts(target_rollout, text) == 1, "target receipt was not exactly once"
    assert user_receipts(sibling_rollout, text) == 0, "sibling received target input"
    with open(os.path.join(home, ".tally", "logs", "input.log"), encoding="utf-8") as audit:
        lines = audit.read()
    assert len(lines.splitlines()) == 1, lines
    assert f" pid={target} input=submitted bytes={len(text.encode())} text={text}" in lines, lines
    assert not os.path.exists(os.path.join(request_dir, str(sibling) + ".result"))

    print("PASS: historical resumed Codex sessions initialize without a human bootstrap, expose an exact private-PTY target, and preserve sibling isolation with a native receipt and audit")
    succeeded = True
finally:
    for pid, fd in children:
        try:
            if pid not in reaped:
                os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    for pid, fd in children:
        try:
            if pid not in reaped:
                os.waitpid(pid, 0)
                reaped.add(pid)
        except ChildProcessError:
            pass
        os.close(fd)
    if succeeded:
        shutil.rmtree(root)
    else:
        state = os.path.join(root, "home", ".tally", "supervisor-state")
        print("resume fixture retained for diagnosis:", root, file=sys.stderr)
        for pid, _ in children:
            print("fixture", pid, "monitor", read_json(os.path.join(state, str(pid) + ".monitoring")),
                  "binding", read_json(os.path.join(state, str(pid) + ".codex-binding")),
                  "terminal", terminal_output[pid].decode(errors="replace"), file=sys.stderr)
