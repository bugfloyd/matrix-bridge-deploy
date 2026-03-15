#!/usr/bin/env python3
"""Minimal HTTP forward proxy for tunneling apt/docker traffic over SSH.

Run this on the machine with internet access. Use SSH reverse port forwarding
(-R 8080:127.0.0.1:8080) to make it available on the remote server.
"""

import http.client
import select
import socket
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.parse import urlparse


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class ProxyHandler(BaseHTTPRequestHandler):
    timeout = 600

    def do_CONNECT(self):
        """Handle HTTPS via CONNECT tunnel."""
        remote = None
        try:
            host, port = self.path.rsplit(":", 1)
            port = int(port)
            remote = socket.create_connection((host, port), timeout=60)
            self.send_response(200, "Connection Established")
            self.end_headers()

            conns = [self.connection, remote]
            while True:
                readable, _, errors = select.select(conns, [], conns, 300)
                if errors:
                    break
                for s in readable:
                    data = s.recv(65536)
                    if not data:
                        return
                    target = remote if s is self.connection else self.connection
                    target.sendall(data)
        except Exception as e:
            try:
                self.send_error(502, f"Proxy Error: {e}")
            except Exception:
                pass
        finally:
            if remote:
                try:
                    remote.close()
                except Exception:
                    pass

    def _proxy_request(self):
        """Forward HTTP request using http.client (handles all status codes)."""
        conn = None
        try:
            parsed = urlparse(self.path)
            host = parsed.hostname
            port = parsed.port or 80

            headers = {
                k: v
                for k, v in self.headers.items()
                if k.lower() not in ("proxy-connection", "proxy-authorization")
            }

            body = None
            content_length = self.headers.get("Content-Length")
            if content_length:
                body = self.rfile.read(int(content_length))

            path = parsed.path
            if parsed.query:
                path += "?" + parsed.query

            conn = http.client.HTTPConnection(host, port, timeout=300)
            conn.request(self.command, path, body=body, headers=headers)
            resp = conn.getresponse()

            self.send_response(resp.status)
            for key, val in resp.getheaders():
                if key.lower() not in ("transfer-encoding",):
                    self.send_header(key, val)
            self.end_headers()

            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
        except Exception as e:
            try:
                self.send_error(502, f"Proxy Error: {e}")
            except Exception:
                pass
        finally:
            if conn:
                conn.close()

    do_GET = _proxy_request
    do_POST = _proxy_request
    do_PUT = _proxy_request
    do_DELETE = _proxy_request
    do_HEAD = _proxy_request

    def log_message(self, format, *args):
        sys.stderr.write(f"[proxy] {self.address_string()} {format % args}\n")


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    server = ThreadingHTTPServer(("127.0.0.1", port), ProxyHandler)
    print(f"HTTP proxy listening on 127.0.0.1:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()
