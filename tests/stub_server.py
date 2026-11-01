#!/usr/bin/env python3
"""Minimaler Stub für die Messages-API, nur für tests/smoke.sh (kein Netzwerk nach außen).

Aufruf: stub_server.py PORTDATEI PROTOKOLLDATEI RESET_EPOCHE [MODUSDATEI]
Lauscht auf 127.0.0.1 mit freiem Port, schreibt den Port in PORTDATEI und jede Anfrage als JSON-Zeile
in PROTOKOLLDATEI. Auf POST /v1/messages antwortet er je nach Inhalt von MODUSDATEI (bei jeder Anfrage neu
gelesen; fehlt sie, gilt "ok"):
  ok     das Wort "ok" als Stream, im Header das Ende des 5-Stunden-Fensters (RESET_EPOCHE)
  five   429, 5-Stunden-Fenster abgelehnt (Reset RESET_EPOCHE)
  week   429, Wochenlimit abgelehnt (Reset RESET_EPOCHE + 3 Tage)
  auth   401, Anmeldung abgelehnt
Alles andere beantwortet er mit {}.
"""
import http.server
import json
import sys

PORT_FILE, LOG_FILE, RESET = sys.argv[1], sys.argv[2], sys.argv[3]
MODE_FILE = sys.argv[4] if len(sys.argv) > 4 else None
WEEK_RESET = str(int(RESET) + 3 * 86400)

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
    "anthropic-ratelimit-unified-7d-reset": WEEK_RESET,
    "anthropic-ratelimit-unified-7d-utilization": "0.01",
}

# Fehlerantworten: Status, Fehlertyp, Header (zusätzlich zu bzw. statt RATE_LIMIT_HEADERS)
ERRORS = {
    "five": (429, "rate_limit_error", dict(RATE_LIMIT_HEADERS, **{
        "anthropic-ratelimit-unified-status": "rejected",
        "anthropic-ratelimit-unified-5h-status": "rejected",
        "anthropic-ratelimit-unified-5h-utilization": "1.0"})),
    "week": (429, "rate_limit_error", dict(RATE_LIMIT_HEADERS, **{
        "anthropic-ratelimit-unified-status": "rejected",
        "anthropic-ratelimit-unified-reset": WEEK_RESET,
        "anthropic-ratelimit-unified-representative-claim": "seven_day",
        "anthropic-ratelimit-unified-7d-status": "rejected",
        "anthropic-ratelimit-unified-7d-utilization": "1.0"})),
    "auth": (401, "authentication_error", {}),
}


def mode():
    try:
        with open(MODE_FILE, encoding="utf-8") as f:
            return f.read().strip() or "ok"
    except (OSError, TypeError):
        return "ok"


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
        current = mode()
        if self.path.startswith("/v1/messages") and "count_tokens" not in self.path and current in ERRORS:
            status, kind, headers = ERRORS[current]
            payload = json.dumps({"type": "error", "error": {"type": kind, "message": "stub: " + kind}})
            self._send(status, "application/json", payload.encode(), headers)
        elif self.path.startswith("/v1/messages") and "count_tokens" not in self.path:
            out = "".join("event: %s\ndata: %s\n\n" % (name, json.dumps(data)) for name, data in EVENTS)
            self._send(200, "text/event-stream", out.encode(), RATE_LIMIT_HEADERS)
        else:
            self._send(200, "application/json", b"{}")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w", encoding="utf-8") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
