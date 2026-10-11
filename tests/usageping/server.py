# Runs the compiled tests/usageping binary against a local stand-in for the ping endpoint that answers
# every POST with 204, then checks the requests the stand-in saw.
# usage: server.py <test binary> <expected product>
import http.server, json, re, subprocess, sys, threading

binary, product = sys.argv[1:3]
seen = []

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0))).decode()
        seen.append({'method': self.command, 'path': self.path,
                     'headers': dict(self.headers.items()), 'body': body})
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass

server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = 'http://127.0.0.1:%d/api/v1/ping' % server.server_address[1]
run = subprocess.run([binary, url, product], capture_output=True, text=True, timeout=60)
sys.stdout.write(run.stdout + run.stderr)
ok = run.returncode == 0
device = next((l.split(' ', 1)[1] for l in run.stdout.splitlines() if l.startswith('DEVICE ')), '')

def check(cond, name):
    global ok
    print(('PASS ' if cond else 'FAIL ') + name)
    ok = ok and cond

check(len(seen) == 1, 'server saw exactly one request (%d)' % len(seen))
if seen:
    r = seen[0]
    print('REQUEST ' + json.dumps(r))
    h = {k.lower(): v for k, v in r['headers'].items()}
    body = json.loads(r['body'])
    check(r['method'] == 'POST', 'method POST')
    check(r['path'] == '/api/v1/ping', 'path /api/v1/ping')
    check(h.get('content-type') == 'application/json', 'Content-Type application/json')
    check('authorization' not in h, 'no Authorization header')
    check(sorted(body) == ['device', 'product', 'version'], 'body has exactly three keys')
    check(body.get('product') == product, 'product ' + product)
    check(body.get('version') == '9.9.9', 'version passed through')
    check(re.fullmatch(r'[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}',
                       body.get('device', '')) is not None, 'device is a lowercase UUID v4')
    check(body.get('device') == device, 'device matches the stored id')
sys.exit(0 if ok else 1)
