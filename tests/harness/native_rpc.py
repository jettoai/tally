"""A bounded test client for a real local Codex app-server, not a product runtime."""
import json
import os
import queue
import signal
import subprocess
import threading
import time


class NativeRPC:
    def __init__(self, binary, home, user_home, output):
        self.output = output
        self.counter = 0
        self.events = queue.Queue()
        environment = dict(os.environ, CODEX_HOME=str(home), HOME=str(user_home), CLAUDE_NO_AUTO_DEV='1')
        self.stderr = (output / 'app-server.stderr').open('w')
        self.process = subprocess.Popen([str(binary), 'app-server', '--stdio'], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=self.stderr, text=True,
                                        bufsize=1, start_new_session=True, env=environment)
        self.notifications = []
        threading.Thread(target=self.read, daemon=True).start()
        self.call('initialize', {'clientInfo': {'name': 'tally_harness_acceptance', 'version': '1'},
                                 'capabilities': {'experimentalApi': True}})
        self.send({'method': 'initialized'})

    def read(self):
        for line in self.process.stdout:
            self.events.put(json.loads(line))
        self.events.put(None)

    def send(self, value):
        self.process.stdin.write(json.dumps(value) + '\n')
        self.process.stdin.flush()

    def receive(self, timeout):
        value = self.events.get(timeout=timeout)
        if value is None:
            raise RuntimeError('Native app-server exited')
        if 'method' in value and 'id' in value:
            self.send({'id': value['id'], 'error': {'code': -32601, 'message': 'No additional approval or tools in this fixture'}})
        if value.get('method', '').startswith(('hook/', 'item/started', 'item/completed', 'turn/completed')):
            # Exclude model reasoning items. Retain public hook/tool/final events for the oracle.
            item = value.get('params', {}).get('item', {})
            if item.get('type') not in ('reasoning', 'reasoningSummary'):
                self.notifications.append(value)
        return value

    def call(self, method, params):
        self.counter += 1
        id = self.counter
        self.send({'id': id, 'method': method, 'params': params})
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            value = self.receive(max(.1, deadline - time.monotonic()))
            if value.get('id') == id:
                if 'error' in value:
                    raise RuntimeError(str(value['error']))
                return value['result']
        raise TimeoutError(method)

    def turn(self, thread, prompt, root):
        start = time.monotonic()
        result = self.call('turn/start', {'threadId': thread, 'input': [{'type': 'text', 'text': prompt}],
                                         'effort': 'low', 'sandboxPolicy': {'type': 'workspaceWrite',
                                         'writableRoots': [str(root)], 'networkAccess': False}})
        id = result['turn']['id']
        deadline = time.monotonic() + 240
        while time.monotonic() < deadline:
            value = self.receive(max(.1, deadline - time.monotonic()))
            if value.get('method') == 'turn/completed' and value['params']['turn']['id'] == id:
                status = value['params']['turn']['status']
                if status != 'completed':
                    raise RuntimeError('Native turn did not complete: ' + status)
                return {'id': id, 'status': status, 'durationMs': round((time.monotonic() - start) * 1000)}
        raise TimeoutError('Native turn')

    def close(self):
        (self.output / 'native-events.json').write_text(json.dumps(self.notifications, indent=2) + '\n')
        self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=3)
        self.stderr.close()
