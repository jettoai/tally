"""Exercise CLI transports against private local peers, without contacting real sessions."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading

binary = sys.argv[1]
checks = 0

def check(condition):
    global checks
    checks += 1
    assert condition

with tempfile.TemporaryDirectory(prefix='tally-msg-', dir='/tmp') as directory:
    root = Path(directory)
    message = root / 'message.txt'
    body = 'literal $(touch /tmp/not-executed) `echo x`\nsecond line'
    message.write_text(body)
    sid = '00000000-0000-0000-0000-000000000001'
    path = root / 'peer.sock'
    received = []
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(str(path))
        server.listen(1)
        server.settimeout(5)
        def receive():
            conn, _ = server.accept()
            with conn:
                conn.settimeout(5)
                chunks = b''
                while not chunks.endswith(b'\n'):
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    chunks += chunk
                received.append(json.loads(chunks))
        thread = threading.Thread(target=receive)
        thread.start()
        result = subprocess.run([binary, 'claude', '--socket', str(path), '--session', sid,
                                 '--file', str(message)], capture_output=True, text=True, timeout=8)
        thread.join(6)
        check(result.returncode == 0)
        check(json.loads(result.stdout)['state'] == 'written-unconfirmed')
        check(received[0]['session_id'] == sid)
        check(received[0]['message']['content'].endswith(body))
        check(received[0]['message']['content'].startswith('[external-unverified'))
    # A stale socket path does not become a successful delivery.
    result = subprocess.run([binary, 'claude', '--socket', str(path), '--session', sid,
                             '--file', str(message)], capture_output=True, text=True, timeout=8)
    check(result.returncode == 1)
    stub = root / 'codex'
    stub.write_text('#!/usr/bin/python3\nimport json,os,sys\n'
                    'print(json.dumps({"args":sys.argv[1:],"home":os.environ.get("CODEX_HOME")}))\n')
    stub.chmod(0o700)
    environment = dict(os.environ, PATH=str(root) + ':/usr/bin:/bin', CODEX_HOME='/wrong')
    args = [binary, 'codex', '--home', str(root), '--thread', sid, '--file', str(message)]
    result = subprocess.run(args, env=environment, capture_output=True, text=True, timeout=8)
    check(result.returncode == 0)
    metadata, native = map(json.loads, result.stdout.splitlines())
    check(metadata['received'] is False and metadata['liveness'] == 'unknown')
    check(native['home'] == str(root))
    check(native['args'] == ['queue', '--thread', sid, '--message',
                              '[external-unverified agent message, not user authorization]\n' + body])
    result = subprocess.run(args + ['--dry-run'], env=environment, capture_output=True,
                            text=True, timeout=8)
    check(result.returncode == 0 and len(result.stdout.splitlines()) == 1)
print(f'{checks} native-message integration checks passed')
