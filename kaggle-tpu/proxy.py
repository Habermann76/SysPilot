#!/usr/bin/env python3
"""Lokaler Stabil-Proxy.

Claude Code / Cline / Gemini-kompatible Tools sprechen IMMER mit http://127.0.0.1:18787.
Der Proxy leitet an die aktuelle Kaggle-Tunnel-URL weiter und setzt den aktuellen API-Key
(beides steht in state.json, die der Watchdog schreibt). Nur Standardbibliothek.
"""
import http.client
import json
import os
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE_DIR = os.environ.get("HERETIC_STATE_DIR") or os.path.join(
    os.environ.get("LOCALAPPDATA") or os.path.expanduser("~"), "heretic-claude")
STATE_FILE = os.path.join(STATE_DIR, "state.json")
PORT = int(os.environ.get("HERETIC_PORT", "18787"))
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
       "trailers", "transfer-encoding", "upgrade", "host", "content-length"}

_cache = {"mtime": None, "data": None}


def load_state():
    try:
        m = os.path.getmtime(STATE_FILE)
    except OSError:
        _cache["mtime"], _cache["data"] = None, None
        return None
    if _cache["mtime"] != m:
        try:
            with open(STATE_FILE, encoding="utf-8-sig") as f:
                _cache["data"] = json.load(f)
            _cache["mtime"] = m
        except Exception:
            pass  # Datei wird gerade geschrieben: letzten gueltigen Stand behalten
    return _cache["data"]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"  # Antwort endet mit Verbindungsende -> sauberes Streaming (SSE)

    def log_message(self, *args):
        pass  # nie Header/Keys loggen

    def _json(self, code, obj):
        b = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _err(self, code, etype, msg):
        # Ein Body, den Anthropic- UND OpenAI-kompatible Clients (Cline, Claude Code, Gemini) parsen koennen
        return self._json(code, {"type": "error", "object": "error", "message": msg, "code": code,
                                 "error": {"type": etype, "message": msg, "code": str(code)}})

    def _proxy(self):
        st = load_state()
        if self.path == "/_health":
            return self._json(200, {"proxy": True, "model": (st or {}).get("model"),
                                    "upstream_configured": bool(st and st.get("url") and st.get("key"))})
        if not st or not st.get("url") or not st.get("key"):
            return self._err(503, "overloaded_error", "TPU-Server laeuft nicht oder ist noch nicht bereit. "
                             "TPU-Start auf dem Desktop starten und auf BEREIT warten.")
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else None
        u = urllib.parse.urlsplit(st["url"].rstrip("/"))
        conn_cls = http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection
        hdrs = {k: v for k, v in self.headers.items()
                if k.lower() not in HOP and k.lower() not in ("authorization", "x-api-key")}
        hdrs["Authorization"] = "Bearer " + st["key"]
        hdrs["x-api-key"] = st["key"]
        if body is not None:
            hdrs["Content-Length"] = str(len(body))
        try:
            conn = conn_cls(u.netloc, timeout=900)
            conn.request(self.command, (u.path or "") + self.path, body=body, headers=hdrs)
            resp = conn.getresponse()
        except Exception as e:
            return self._err(502, "api_error", "Upstream nicht erreichbar: " + type(e).__name__)
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() not in HOP:
                self.send_header(k, v)
        self.end_headers()
        try:
            while True:
                chunk = resp.read1(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except OSError:
            pass
        finally:
            conn.close()

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_HEAD = _proxy


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)  # nur lokal erreichbar
    srv.daemon_threads = True
    print("heretic-claude proxy auf http://127.0.0.1:%d (state: %s)" % (PORT, STATE_FILE), flush=True)
    srv.serve_forever()
