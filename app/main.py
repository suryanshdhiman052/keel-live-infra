"""Shop process. /status is 503 when Postgres will not accept a TCP connect."""
from __future__ import annotations

import os
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def require(key: str) -> str:
    got = os.environ.get(key, "").strip()
    if not got:
        raise RuntimeError(f"{key} unset")
    return got


def postgres_up() -> bool:
    host = require("DB_HOST")
    port = int(os.environ.get("DB_PORT", "5432"))
    try:
        with socket.create_connection((host, port), timeout=2):
            return True
    except OSError:
        return False


class Shop(BaseHTTPRequestHandler):
    def log_message(self, *_args) -> None:
        return

    def write(self, code: int, text: str) -> None:
        raw = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:
        if self.path == "/status":
            ok = postgres_up()
            self.write(200 if ok else 503, "up\n" if ok else "pg down\n")
            return
        if self.path == "/ok":
            self.write(200, "ok\n")
            return
        self.write(404, "no\n")


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("PORT", "8088"))), Shop).serve_forever()
