import hashlib
import http.server
import json
import pathlib
import secrets
import ssl
import sys
import threading
import time

root = pathlib.Path(sys.argv[1])
lock = threading.Lock()
leases = {}
token = secrets.token_urlsafe(32)
total_bytes = 0
cancelled = 0


def event(value):
    with lock:
        with (root / 'requests.jsonl').open('a') as output:
            output.write(json.dumps(value) + '\n')


class StreamingFixture(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, format, *args):
        return

    def respond(self, status, value=None):
        data = json.dumps(value).encode() if value is not None else b''
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Connection', 'close')
        self.end_headers()
        if data:
            self.wfile.write(data)

    def authorized(self):
        if self.headers.get('Authorization') != 'Bearer ' + token:
            self.respond(401)
            return False
        return True

    def do_POST(self):
        if not self.authorized():
            return
        name = self.path.split('/')[-2]
        if not (root / (name + '.mov')).is_file():
            self.respond(404)
            return
        identifier = secrets.token_urlsafe(24)
        with lock:
            leases[identifier] = name
        event({'method': 'POST', 'path': self.path})
        self.respond(200, {'id': identifier, 'expiresIn': 45})

    def do_PUT(self):
        if not self.authorized():
            return
        self.respond(204)

    def do_DELETE(self):
        if not self.authorized():
            return
        with lock:
            leases.pop(self.path.split('/')[-1], None)
        event({'method': 'DELETE', 'path': self.path})
        self.respond(204)

    def do_HEAD(self):
        self.movie(True)

    def do_GET(self):
        if self.path == '/stats':
            with lock:
                value = {'bytes': total_bytes, 'leases': len(leases), 'cancelled': cancelled}
            self.respond(200, value)
            return
        self.movie(False)

    def movie(self, head):
        global total_bytes, cancelled
        if not self.authorized():
            return
        name = self.path.split('/')[-2]
        movie = root / (name + '.mov')
        if not movie.is_file():
            self.respond(404)
            return
        lease = self.headers.get('X-WireCamera-Playback')
        with lock:
            valid = leases.get(lease) == name
        if not valid:
            self.respond(410)
            return
        total = movie.stat().st_size
        first, last = 0, total - 1
        value = self.headers.get('Range')
        if not head:
            if not value or not value.startswith('bytes='):
                self.respond(400)
                return
            first_text, last_text = value[6:].split('-')
            first = int(first_text)
            last = min(total - 1, int(last_text)) if last_text else total - 1
            if first > last:
                self.respond(416)
                return
        self.send_response(200 if head else 206)
        self.send_header('Content-Type', 'video/quicktime')
        self.send_header('Content-Length', str(last - first + 1))
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Connection', 'close')
        if not head:
            self.send_header('Content-Range', f'bytes {first}-{last}/{total}')
        self.end_headers()
        event({'method': 'HEAD' if head else 'GET', 'path': self.path, 'range': value, 'start': first, 'end': last})
        if head:
            return
        with movie.open('rb') as source:
            source.seek(first)
            remaining = last - first + 1
            try:
                while remaining:
                    data = source.read(min(8192, remaining))
                    if not data:
                        break
                    self.wfile.write(data)
                    self.wfile.flush()
                    with lock:
                        total_bytes += len(data)
                    remaining -= len(data)
                    time.sleep(len(data) / (256 * 1024))
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                with lock:
                    cancelled += 1


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), StreamingFixture)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(root / 'cert.pem', root / 'key.pem')
server.socket = context.wrap_socket(server.socket, server_side=True)
certificate = ssl.PEM_cert_to_DER_cert((root / 'cert.pem').read_text())
(root / 'ready.json').write_text(json.dumps({'port': server.server_port, 'token': token, 'fingerprint': hashlib.sha256(certificate).hexdigest(), 'firstBytes': (root / 'first.mov').stat().st_size}))
server.serve_forever()
