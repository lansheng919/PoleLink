import base64
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid

spec = importlib.util.spec_from_file_location("server", Path(__file__).parents[1] / "mock-api/server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


def capture(value):
    return dict(id=str(uuid.uuid4()), value=value, originalValue=value, confidence=.98,
                verification="high", confidenceSource="demo", isDemo=True,
                capturedAt="2026-09-22T00:00:00Z", photo=base64.b64encode(b'\xff\xd8test\xff\xd9').decode())


class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.database = str(Path(self.directory.name) / "test.sqlite3")
        self.http = server.create_server("127.0.0.1", 0, self.database)
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.http.server_port}"
        self.body = dict(id=str(uuid.uuid4()), isDemo=True, createdAt="2026-09-22T00:00:00Z",
                         pole=capture("PL-10482"), lights=[capture("SL-100001"), capture("SL-100002")])

    def tearDown(self):
        self.http.shutdown()
        self.http.server_close()
        self.thread.join()
        self.directory.cleanup()

    def post(self, body, key=None):
        req = urllib.request.Request(self.url + "/api/v1/associations", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json", "Idempotency-Key": key or body["id"]})
        try:
            with urllib.request.urlopen(req) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as response:
            with response:
                return response.code, json.load(response)

    def test_roundtrip_and_retry_are_idempotent(self):
        self.assertEqual(self.post(self.body)[0], 201)
        status, receipt = self.post(self.body)
        self.assertEqual(status, 200)
        self.assertTrue(receipt["duplicate"])
        with urllib.request.urlopen(self.url + "/api/v1/associations") as response:
            items = json.load(response)["items"]
        self.assertEqual(items, [self.body])
        with urllib.request.urlopen(self.url + "/api/v1/associations/" + self.body["id"]) as response:
            self.assertEqual(json.load(response), self.body)

    def test_conflicting_retry_does_not_overwrite(self):
        self.post(self.body)
        changed = copy.deepcopy(self.body)
        changed["pole"]["value"] = "PL-99999"
        self.assertEqual(self.post(changed)[0], 409)

    def test_duplicate_serial_rejected(self):
        self.body["lights"][1]["value"] = self.body["lights"][0]["value"].lower()
        self.assertEqual(self.post(self.body)[0], 400)

    def test_missing_photo_rejected(self):
        self.body["pole"]["photo"] = ""
        self.assertEqual(self.post(self.body)[0], 400)

    def test_low_confidence_requires_verification(self):
        self.body["pole"]["confidence"] = .4
        self.assertEqual(self.post(self.body)[0], 400)
        self.body["pole"]["verification"] = "manual"
        self.assertEqual(self.post(self.body)[0], 201)

    def test_missing_lights_and_wrong_idempotency_key(self):
        self.assertEqual(self.post(self.body, "wrong")[0], 400)
        self.body["lights"] = []
        self.assertEqual(self.post(self.body)[0], 400)

    def test_persists_across_server_restart(self):
        self.post(self.body)
        second = server.create_server("127.0.0.1", 0, self.database)
        try:
            with server.sqlite3.connect(self.database) as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM associations").fetchone()[0], 1)
        finally:
            second.server_close()


if __name__ == "__main__":
    unittest.main()
