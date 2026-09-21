"""Local SAP integration stand-in. Python standard library only."""
import argparse
import base64
import json
import re
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from uuid import UUID

MAX_BODY = 40 * 1024 * 1024
ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$")


def validate(body):
    if not isinstance(body, dict):
        raise ValueError("Expected an object")
    UUID(body["id"])
    if not isinstance(body.get("isDemo"), bool):
        raise ValueError("isDemo must be a boolean")
    if not isinstance(body.get("lights"), list) or not body["lights"]:
        raise ValueError("At least one street light is required")
    captures = [body["pole"]] + body["lights"]
    values = set()
    for index, capture in enumerate(captures):
        UUID(capture["id"])
        if not ID.fullmatch(capture["value"]):
            raise ValueError("Invalid identifier")
        score = capture["confidence"]
        if isinstance(score, bool) or not isinstance(score, (int, float)) or not 0 <= score <= 1:
            raise ValueError("Confidence must be between zero and one")
        if capture["verification"] not in ("manual", "high"):
            raise ValueError("Invalid verification status")
        if capture["verification"] == "high" and score < .9:
            raise ValueError("High confidence must meet the threshold")
        if capture["isDemo"] != body["isDemo"]:
            raise ValueError("Mixed demo and real evidence")
        if capture["confidenceSource"] not in ("demo", "visionOCR", "qrReadConsistency"):
            raise ValueError("Unknown confidence source")
        photo = base64.b64decode(capture["photo"], validate=True)
        if not photo.startswith(b'\xff\xd8') or not photo.endswith(b'\xff\xd9'):
            raise ValueError("A JPEG photo is required")
        if index:
            value = capture["value"].upper()
            if value in values:
                raise ValueError("Duplicate light serial")
            values.add(value)
    return json.dumps(body, sort_keys=True, separators=(",", ":"))


def create_server(host, port, database):
    with sqlite3.connect(database) as db:
        db.execute("CREATE TABLE IF NOT EXISTS associations (id TEXT PRIMARY KEY, payload TEXT NOT NULL, received_at TEXT DEFAULT CURRENT_TIMESTAMP)")

    class Handler(BaseHTTPRequestHandler):
        def respond(self, status, body):
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            path = self.path.split("?")[0]
            if path == "/health":
                return self.respond(200, {"status": "ok", "service": "PoleLink mock integration"})
            if path == "/api/v1/associations":
                with sqlite3.connect(database) as db:
                    rows = db.execute("SELECT payload FROM associations ORDER BY received_at DESC").fetchall()
                return self.respond(200, {"items": [json.loads(row[0]) for row in rows]})
            if path.startswith("/api/v1/associations/"):
                identifier = path.rsplit("/", 1)[1].upper()
                with sqlite3.connect(database) as db:
                    row = db.execute("SELECT payload FROM associations WHERE id = ?", (identifier,)).fetchone()
                return self.respond(200, json.loads(row[0])) if row else self.respond(404, {"error": "Not found"})
            self.respond(404, {"error": "Not found"})

        def do_POST(self):
            if self.path != "/api/v1/associations":
                return self.respond(404, {"error": "Not found"})
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= MAX_BODY:
                    return self.respond(413, {"error": "Body must be 1–40 MiB"})
                body = json.loads(self.rfile.read(length))
                payload = validate(body)
                identifier = str(UUID(body["id"])).upper()
                if self.headers.get("Idempotency-Key", "").upper() != identifier:
                    raise ValueError("Idempotency-Key must match the survey id")
                with sqlite3.connect(database) as db:
                    db.execute("BEGIN IMMEDIATE")
                    existing = db.execute("SELECT payload FROM associations WHERE id = ?", (identifier,)).fetchone()
                    if existing and existing[0] != payload:
                        return self.respond(409, {"error": "Survey id already exists with different content"})
                    if not existing:
                        db.execute("INSERT INTO associations (id, payload) VALUES (?, ?)", (identifier, payload))
                self.respond(200 if existing else 201, {"id": identifier, "accepted": True, "destination": "mock-sap", "duplicate": bool(existing)})
            except (ValueError, KeyError, TypeError, AttributeError) as error:
                self.respond(400, {"error": str(error)})
            except sqlite3.Error:
                self.respond(503, {"error": "Storage unavailable; retry later"})

    return ThreadingHTTPServer((host, port), Handler)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--database", default=str(Path(__file__).with_name("mock.sqlite3")))
    args = parser.parse_args()
    server = create_server(args.host, args.port, args.database)
    print(f"PoleLink mock API: http://{args.host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.server_close()
