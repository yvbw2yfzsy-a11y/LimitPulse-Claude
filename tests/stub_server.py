#!/usr/bin/env python3
"""Minimaler Stub für die Messages-API, nur für tests/smoke.sh (kein Netzwerk nach außen).

Aufruf: stub_server.py PORTDATEI PROTOKOLLDATEI RESET_EPOCHE
Lauscht auf 127.0.0.1 mit freiem Port, schreibt den Port in PORTDATEI und jede Anfrage als JSON-Zeile
in PROTOKOLLDATEI. Auf POST /v1/messages antwortet er mit dem Wort "ok" als Stream und meldet im Header
das Ende des 5-Stunden-Fensters; alles andere beantwortet er mit {}.
"""
import http.server
import json
import sys

PORT_FILE, LOG_FILE, RESET = sys.argv[1], sys.argv[2], sys.argv[3]

EVENTS = [
    ("message_start", {"type": "message_start", "message": {
        "id": "msg_stub", "type": "message", "role": "assistant", "model": "claude-haiku-5-5",
        "content": [], "stop_reason": None, "usage": {"input_tokens": 10, "output_tokens": 1}}}),
    ("content_block_start", {"type": "content_block_start", "index": 0,
                             "content_block": {"type": "text", "text": ""}}),
    ("content_block_delta", {"type": "content_block_delta", "index": 0,
                             "delta": {"type": "text_delta", "text": "ok"}}),
    ("content_block_stop", {"type": "content_block_stop", "index": 0}),
    ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"},
                       "usage": {"output_tokens": 2}}),
    ("message_stop", {"type": "message_stop"}),
]

RATE_LIMIT_HEADERS = {
    "anthropic-ratelimit-unified-status": "allowed",
    "anthropic-ratelimit-unified-reset": RESET,
    "anthropic-ratelimit-unified-representative-claim": "five_hour",
    "anthropic-ratelimit-unified-5h-status": "allowed",
    "anthropic-ratelimit-unified-5h-reset": RESET,
    "anthropic-ratelimit-unified-5h-utilization": "0.01",
    "anthropic-ratelimit-unified-7d-status": "allowed",
    "anthropic-ratelimit-unified-7d-reset": str(int(RESET) + 3 * 86400),
    "anthropic-ratelimit-unified-7d-utilization": "0.01",
}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _record(self, body):
        entry = {"method": self.command, "path": self.path, "bytes": len(body)}
        if self.path.startswith("/v1/messages"):
            try:
                entry["body"] = json.loads(body)
            except ValueError:
                entry["body"] = None
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry) + "\n")

    def _send(self, status, ctype, payload, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self._record(b"")
        self._send(200, "application/json", b"{}")

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self._record(body)
        if self.path.startswith("/v1/messages") and "count_tokens" not in self.path:
            out = "".join("event: %s\ndata: %s\n\n" % (name, json.dumps(data)) for name, data in EVENTS)
            self._send(200, "text/event-stream", out.encode(), RATE_LIMIT_HEADERS)
        else:
            self._send(200, "application/json", b"{}")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w", encoding="utf-8") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
