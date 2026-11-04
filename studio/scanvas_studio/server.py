"""Wi-Fi receiver: the iPhone app finds this computer over Bonjour and sends raw captures straight into the inbox.

Protocol (plain HTTP on the local network, every request carries the pairing code in X-Scanvas-Code):
  GET  /hello                        -> {"app": "scanvas-studio", "version": 1, "name": ...}
  PUT  /upload/<transfer>/<path>     body = file bytes
  POST /done/<transfer>?name=..&files=N
"""
from __future__ import annotations

import json
import random
import re
import shutil
import socket
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Callable

PORT = 8765


def studio_home() -> Path:
    p = Path.home() / "Scanvas Studio"
    (p / "Inbox").mkdir(parents=True, exist_ok=True)
    (p / "Scans").mkdir(parents=True, exist_ok=True)
    return p


def pairing_code() -> str:
    f = studio_home() / "pairing-code.txt"
    if f.exists():
        code = f.read_text().strip()
        if code.isdigit() and len(code) == 4:
            return code
    code = f"{random.SystemRandom().randint(0, 9999):04d}"
    f.write_text(code)
    return code


def local_addresses() -> list[str]:
    found = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))     # no packet is sent; this just picks the outgoing interface
        found.append(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip not in found and not ip.startswith("127."):
                found.append(ip)
    except OSError:
        pass
    return found or ["127.0.0.1"]


_SAFE = re.compile(r"^[A-Za-z0-9._-]+$")


class Receiver:
    def __init__(self, on_received: Callable[[Path, str], None] | None = None, on_progress: Callable[[str], None] | None = None):
        self.home = studio_home()
        self.code = pairing_code()
        self.on_received = on_received
        self.on_progress = on_progress
        self.httpd: ThreadingHTTPServer | None = None
        self.zeroconf = None
        self.port = PORT

    def start(self):
        receiver = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def _reply(self, status=200, body=None):
                data = json.dumps(body or {"ok": status < 400}).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def _authorised(self):
                if self.headers.get("X-Scanvas-Code", "") != receiver.code:
                    # Drain the body so the connection stays usable, then refuse.
                    length = int(self.headers.get("Content-Length", "0") or 0)
                    while length > 0:
                        chunk = self.rfile.read(min(length, 1 << 20))
                        if not chunk:
                            break
                        length -= len(chunk)
                    self._reply(403, {"ok": False, "error": "wrong pairing code"})
                    return False
                return True

            def do_GET(self):
                if self.path.startswith("/hello"):
                    if not self._authorised():
                        return
                    self._reply(200, {"app": "scanvas-studio", "version": 1, "name": socket.gethostname()})
                else:
                    self._reply(404)

            def do_PUT(self):
                if not self._authorised():
                    return
                parts = urllib.parse.urlparse(self.path).path.split("/")
                # /upload/<transfer>/<path...>
                if len(parts) < 4 or parts[1] != "upload" or not _SAFE.match(parts[2]):
                    return self._reply(400)
                rel = [urllib.parse.unquote(p) for p in parts[3:]]
                if not rel or any(not _SAFE.match(p) or p in (".", "..") for p in rel):
                    return self._reply(400)
                target = receiver.home / "Inbox" / parts[2] / Path(*rel)
                target.parent.mkdir(parents=True, exist_ok=True)
                length = int(self.headers.get("Content-Length", "0") or 0)
                with open(target, "wb") as fh:
                    remaining = length
                    while remaining > 0:
                        chunk = self.rfile.read(min(remaining, 1 << 20))
                        if not chunk:
                            break
                        fh.write(chunk)
                        remaining -= len(chunk)
                if receiver.on_progress and rel[-1].endswith(".jpg"):
                    receiver.on_progress(f"Receiving {rel[-1]}")
                self._reply(200)

            def do_POST(self):
                if not self._authorised():
                    return
                url = urllib.parse.urlparse(self.path)
                parts = url.path.split("/")
                if len(parts) != 3 or parts[1] != "done" or not _SAFE.match(parts[2]):
                    return self._reply(400)
                q = urllib.parse.parse_qs(url.query)
                name = (q.get("name") or ["Scan"])[0]
                safe = re.sub(r"[^A-Za-z0-9 ._-]", "_", name).strip() or "Scan"
                src = receiver.home / "Inbox" / parts[2]
                if not (src / "capture.json").exists():
                    return self._reply(400, {"ok": False, "error": "capture.json missing"})
                dest = receiver.home / "Scans" / f"{safe} {time.strftime('%Y-%m-%d %H.%M')}"
                n = 2
                while dest.exists():
                    dest = dest.with_name(f"{dest.name} ({n})")
                    n += 1
                shutil.move(str(src), str(dest))
                self._reply(200)
                if receiver.on_received:
                    threading.Thread(target=receiver.on_received, args=(dest, name), daemon=True).start()

        for port in (PORT, PORT + 1, PORT + 2, 0):
            try:
                self.httpd = ThreadingHTTPServer(("0.0.0.0", port), Handler)
                break
            except OSError:
                continue
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self._advertise()

    def _advertise(self):
        try:
            from zeroconf import ServiceInfo, Zeroconf
        except ImportError:
            return
        try:
            addrs = local_addresses()
            name = socket.gethostname().split(".")[0][:40] or "Computer"
            info = ServiceInfo("_scanvas._tcp.local.", f"{name}._scanvas._tcp.local.",
                               addresses=[socket.inet_aton(a) for a in addrs], port=self.port,
                               properties={"addr": ",".join(addrs), "port": str(self.port), "name": name})
            self.zeroconf = Zeroconf()
            self.zeroconf.register_service(info, allow_name_change=True)
        except Exception:
            self.zeroconf = None

    def stop(self):
        if self.zeroconf:
            try:
                self.zeroconf.close()
            except Exception:
                pass
        if self.httpd:
            self.httpd.shutdown()

    @property
    def address(self) -> str:
        return f"{local_addresses()[0]}:{self.port}"


def run_forever():
    def received(folder: Path, name: str):
        print(f"Received {name} -> {folder}", flush=True)

    r = Receiver(on_received=received)
    r.start()
    print(f"Scanvas Studio is waiting for scans at {r.address} (pairing code {r.code}). Ctrl+C to stop.", flush=True)
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        r.stop()
