"""Synthetic loopback contract fixtures; no production service or database."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import unittest

HERE = Path(__file__).resolve().parent


class SenderTest(unittest.TestCase):
    def run_sender(self, mode="good", omit=None, event_name="play_cta_click"):
        requests = []
        seen = set()

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                requests.append((self.path, body, self.headers.get("Authorization")))
                status = 202
                if self.headers.get("Authorization") is None:
                    status = 202 if mode == "unauth_allowed" else 401
                    reply = {"error": {"code": "unauthorized"}}
                elif self.path == "/v1/consent":
                    reply = {"recorded": True, "replayed": False}
                elif self.path == "/api/v1/crashes/ingest":
                    reply = {"crash_id": body["crash_id"], "suppressed": mode == "crash_suppressed"}
                    if mode != "legacy" and any(not m.get("load_address") or not m.get("size") for m in body.get("modules", [])):
                        status, reply = 400, {"code": "invalid_request", "message": "module bounds required"}
                else:
                    rows = []
                    for event in body["events"]:
                        oversized = len(json.dumps(event, separators=(",", ":")).encode()) > 2048
                        duplicate = event["event_id"] in seen and mode != "duplicate_accepted"
                        rows.append({"event_id": event["event_id"],
                                     "status": "rejected" if oversized else "duplicate" if duplicate else "accepted",
                                     "code": ("wrong_reason" if mode == "wrong_reason" else "event_too_large") if oversized else "duplicate_event_id" if duplicate else "",
                                     "message": "synthetic fixture result"})
                        if not oversized:
                            seen.add(event["event_id"])
                    rejected = sum(r["status"] == "rejected" for r in rows)
                    duplicates = sum(r["status"] == "duplicate" for r in rows)
                    reply = {"accepted": len(rows) - rejected - duplicates, "rejected": rejected,
                             "duplicates": duplicates, "suppressed": 0, "events": rows}
                    if mode != "legacy" and any(e["event_name"] not in ("play_cta_click", "fixture_registered_click") for e in body["events"]):
                        status, reply = 400, {"code": "validation_error", "message": "schema_not_found"}
                    if mode == "empty_202":
                        reply = {}
                    if mode == "redirect":
                        status = 307
                if mode == "echo_key":
                    reply["echo"] = self.headers.get("Authorization", "")
                encoded = json.dumps(reply).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("X-Request-ID", "fixture-" + str(len(requests)))
                if status == 307:
                    self.send_header("Location", "/must-not-follow")
                self.end_headers()
                self.wfile.write(encoded)

        with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            endpoint = "http://127.0.0.1:" + str(server.server_port)
            env = {"PATH": os.environ.get("PATH", ""), "SP_INGEST_URL": endpoint,
                   "SP_CRASH_URL": endpoint, "SP_INGEST_KEY": "synthetic-ingest-key",
                   "SP_CRASH_KEY": "synthetic-crash-key", "SP_WORKSPACE_ID": "senderworkspace",
                   "SP_APP_ID": "senderapp", "SP_ENVIRONMENT_ID": "test", "SP_CRASH_APP_ID": "senderapp",
                   "SP_EVENT_NAME": event_name}
            if omit:
                del env[omit]
            result = subprocess.run([sys.executable, str(HERE / "send.py")], env=env,
                                    text=True, capture_output=True, timeout=30)
            server.shutdown()
            thread.join()
        self.assertNotIn("synthetic-ingest-key", result.stdout + result.stderr)
        self.assertNotIn("synthetic-crash-key", result.stdout + result.stderr)
        return result, requests

    def test_actual_sdk_and_all_nine_requests(self):
        result, requests = self.run_sender()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(len(requests), 9)
        self.assertEqual(requests[1][1]["events"][0]["event_name"], "play_cta_click")
        self.assertTrue(all(e["source"] == "client" for r in requests for e in r[1].get("events", [])))
        self.assertEqual(len(requests[2][1]["events"]), 4)
        self.assertIsNone(requests[-1][2])
        self.assertEqual(requests[-1][1], requests[1][1])
        replies = [json.loads(line) for line in result.stdout.splitlines() if '"latency_ms"' in line]
        self.assertEqual(len(replies), 9)
        self.assertTrue(all(r["request_id"].startswith("fixture-") for r in replies))
        self.assertEqual(json.loads(result.stdout.splitlines()[-1]), {"requests": 9, "contract_match": True, "rejected_events": 1, "exit_code": 1})
        mixed = next(r for r in replies if r["stage"] == "mixed_size")
        self.assertEqual(mixed["event_result"]["rejected"], 1)
        self.assertEqual(mixed["event_result"]["events"][1]["code"], "event_too_large")

    def test_registered_event_override(self):
        result, requests = self.run_sender(event_name="fixture_registered_click")
        names = {e["event_name"] for r in requests for e in r[1].get("events", [])}
        self.assertEqual(names, {"fixture_registered_click"})
        self.assertTrue(json.loads(result.stdout.splitlines()[-1])["contract_match"])

    def test_rejected_event_is_nonzero_even_when_contract_matches(self):
        result, requests = self.run_sender("legacy")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertGreater(len(requests), 0)

    def test_duplicate_replays_identical_sdk_body(self):
        result, requests = self.run_sender("legacy")
        original = requests[1]
        self.assertEqual(sum(r == original for r in requests), 2)

    def test_native_module_has_bounds(self):
        result, requests = self.run_sender("legacy")
        modules = [m for r in requests for m in r[1].get("modules", [])]
        self.assertEqual(len(modules), 1)
        self.assertEqual(modules[0].get("load_address"), "0x1000")
        self.assertEqual(modules[0].get("size"), "0x2000")

    def test_failure_responses_are_nonzero(self):
        for mode in ("unauth_allowed", "wrong_reason", "empty_202", "crash_suppressed", "redirect", "duplicate_accepted"):
            with self.subTest(mode=mode):
                result, requests = self.run_sender(mode)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertGreater(len(requests), 0)
                self.assertNotIn("/must-not-follow", [r[0] for r in requests])
                self.assertFalse(json.loads(result.stdout.splitlines()[-1]).get("contract_match", False))

    def test_unregistered_name_fails_whole_batch(self):
        result, requests = self.run_sender(event_name="fixture_unregistered")
        replies = [json.loads(line) for line in result.stdout.splitlines() if '"latency_ms"' in line]
        self.assertEqual(next(r for r in replies if r["stage"] == "minimal")["status"], 400)
        self.assertEqual(result.returncode, 1)

    def test_missing_configuration_sends_nothing(self):
        result, requests = self.run_sender(omit="SP_CRASH_KEY")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(requests, [])

    def test_server_echo_of_key_is_redacted(self):
        result, requests = self.run_sender("echo_key")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(len(requests), 9)
        self.assertTrue(json.loads(result.stdout.splitlines()[-1])["contract_match"])
        self.assertIn("[REDACTED]", result.stdout)


if __name__ == "__main__":
    unittest.main()
