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
        metadata = json.loads(result.stdout)
        check(metadata['trust'] == 'external-unverified' and metadata['dryRun'] is False)
        check(metadata['socket'] == str(path) and metadata['session'] == sid)
        check(received[0]['session_id'] == sid)
        check(received[0]['type'] == 'user' and received[0]['priority'] == 'next')
        check(received[0]['message']['role'] == 'user')
        check(received[0]['message']['content'].endswith(body))
        check(received[0]['message']['content'].startswith('[external-unverified'))
    # The socket file remains after its listener has closed.
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
    native, metadata = map(json.loads, result.stdout.splitlines())
    check(metadata['received'] is False and metadata['liveness'] == 'unknown')
    check(metadata['state'] == 'native-exited' and metadata['nativeExitCode'] == 0)
    check(native['home'] == str(root))
    check(native['args'] == ['queue', '--thread', sid, '--message',
                              '[external-unverified agent message, not user authorization]\n' + body])
    result = subprocess.run(args + ['--dry-run'], env=environment, capture_output=True,
                            text=True, timeout=8)
    check(result.returncode == 0 and len(result.stdout.splitlines()) == 1)
    claude_args = [binary, 'claude', '--socket', str(path), '--session', sid,
                   '--file', str(message)]
    result = subprocess.run(claude_args + ['--dry-run'], capture_output=True, text=True, timeout=8)
    metadata = json.loads(result.stdout)
    check(result.returncode == 0 and metadata['state'] == 'dry-run' and metadata['dryRun'] is True)
    check(metadata['trust'] == 'external-unverified' and metadata['received'] is False
          and metadata['liveness'] == 'unknown')
    check(metadata['socket'] == str(path) and metadata['session'] == sid)
    # Exercise the exact byte boundary and rejected files before either transport starts.
    for payload, expected in [(b'x' * 65536, 0), (b'x' * 65537, 2),
                              (b'', 2), (b' \n\t', 2), (b'\xff', 2)]:
        message.write_bytes(payload)
        for command in [args, claude_args]:
            result = subprocess.run(command + ['--dry-run'], env=environment,
                                    capture_output=True, text=True, timeout=8)
            check(result.returncode == expected)
    # NUL is valid UTF-8 but cannot be passed to Foundation Process as an argv value.
    message.write_bytes(b'A\x00B-tail')
    result = subprocess.run(args, env=environment, capture_output=True, text=True, timeout=8)
    check(result.returncode == 2 and 'NUL' in result.stderr and result.stdout == '')
    message.write_text(body)
    stub.write_text('#!/bin/sh\nexit 7\n')
    result = subprocess.run(args, env=environment, capture_output=True, text=True, timeout=8)
    check(result.returncode == 7 and json.loads(result.stdout)['nativeExitCode'] == 7)
    stub.write_text('invalid executable format\n')
    result = subprocess.run(args, env=environment, capture_output=True, text=True, timeout=8)
    check(result.returncode == 1 and result.stdout == '' and 'could not start' in result.stderr)
    path.unlink()
    result = subprocess.run(claude_args, capture_output=True, text=True, timeout=8)
    check(result.returncode == 1 and 'socket is unavailable' in result.stderr)
    path.write_text('not a socket')
    result = subprocess.run(claude_args, capture_output=True, text=True, timeout=8)
    check(result.returncode == 2 and 'not a socket' in result.stderr)
print(f'{checks} native-message integration checks passed')
