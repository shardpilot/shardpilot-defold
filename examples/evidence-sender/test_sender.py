"""Synthetic loopback contract fixtures; no production service or database."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import unittest
from unittest import mock

import send

HERE = Path(__file__).resolve().parent


class SenderTest(unittest.TestCase):
    def run_without_network(self, field, url):
        calls = []
        output = io.StringIO()
        env = {"SP_" + name.upper(): "synthetic-fixture" for name in send.FIELDS}
        env.update(SP_INGEST_URL="https://ingest.example.test",
                   SP_CRASH_URL="https://crash.example.test",
                   SP_INGEST_TOKEN=os.urandom(32).hex())
        env[field] = url

        def fake_transport(req, **kwargs):
            calls.append(req.full_url)
            response = io.BytesIO(b'{"recorded":true}')
            response.code, response.headers = 202, {"X-Request-ID": "synthetic-fixture"}
            return response

        with mock.patch.dict(os.environ, env, clear=True), contextlib.redirect_stdout(output):
            with mock.patch.object(send.request.OpenerDirector, "open", side_effect=fake_transport):
                result = send.main()
        self.assertFalse(env["SP_INGEST_TOKEN"] in output.getvalue(), "transport marker leaked")
        return result, calls, output.getvalue()

    def test_invalid_hostnames_fail_before_transport(self):
        for field in ("SP_INGEST_URL", "SP_CRASH_URL"):
            for host in ("bad%zz", "bad%", "bad%2", "bad%25zz", "bad%20host",
                         "bad%2fhost", "bad%40host", "bad%3ahost", "bad%00host",
                         "bad%ff", "bad host", "bad\\host", "bad\thost", "bad\nhost",
                         "[not-an-ip]", "[::1]junk", "[::1]:", "[fe80::1%25en0]"):
                with self.subTest(field=field, host=host):
                    result, calls, output = self.run_without_network(field, "https://" + host)
                    self.assertEqual(len(calls), 0)
                    self.assertEqual(result, 2)
                    self.assertIn(field, output)

    def test_valid_hostname_controls_reach_actual_sdk_transport(self):
        for field in ("SP_INGEST_URL", "SP_CRASH_URL"):
            for host in ("example.test", "one-two.example.test.", "under_score.test",
                         "127.0.0.1", "[2001:db8::1]", "%65xample.test"):
                with self.subTest(field=field, host=host):
                    result, calls, output = self.run_without_network(field, "https://" + host)
                    self.assertEqual(result, 1)
                    self.assertGreater(len(calls), 0)
                    self.assertIn('"lua":', output)

    def test_encoded_hostname_is_validated_and_used_decoded(self):
        for field in ("SP_INGEST_URL", "SP_CRASH_URL"):
            for encoded, decoded in (("%65xample.test", "example.test"),
                                     ("%c3%a9xample.test", "xn--xample-9ua.test")):
                with self.subTest(field=field, encoded=encoded):
                    result, calls, output = self.run_without_network(field, "https://" + encoded + ":443")
                    self.assertEqual(result, 1)
                    self.assertTrue(any(url.startswith("https://" + decoded + ":443/") for url in calls))
                    self.assertFalse(any("%" in url for url in calls))

    def run_sender(self, mode="good", omit=None, event_name="play_cta_click", overrides=None):
        requests = []
        seen = set()
        # Opaque per-run transport marker; never a signed or usable credential.
        verified_marker = os.urandom(32).hex()

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
                    verified = (self.headers.get("Authorization") == "Bearer " + verified_marker
                                and body.get("kind") == "user_verified"
                                and body.get("actor_identifier") == "sender-user")
                    if mode == "verified_grant" and not verified:
                        status, reply = 403, {"code": "consent_grant_requires_verified_credential"}
                    else:
                        reply = {"recorded": True, "replayed": False}
                elif self.path == "/api/v1/crashes/ingest":
                    reply = {"crash_id": "stale-crash-id" if mode == "stale_crash" else body["crash_id"],
                             "suppressed": mode == "crash_suppressed"}
                    if mode != "legacy" and any(not m.get("load_address") or not m.get("size") for m in body.get("modules", [])):
                        status, reply = 400, {"code": "invalid_request", "message": "module bounds required"}
                else:
                    rows = []
                    for index, event in enumerate(body["events"]):
                        oversized = len(json.dumps(event, separators=(",", ":")).encode()) > 2048
                        duplicate = event["event_id"] in seen and mode != "duplicate_accepted"
                        observed = mode in ("observed", "observed_wrong_count") or (mode == "mixed_observed" and index % 2 == 0)
                        rows.append({"event_id": event["event_id"],
                                     "status": "rejected" if oversized else "duplicate" if duplicate else "observed" if observed else "accepted",
                                     "code": ("wrong_reason" if mode == "wrong_reason" else "event_too_large") if oversized else "duplicate_event_id" if duplicate else "",
                                     "message": "synthetic fixture result"})
                        if not oversized:
                            seen.add(event["event_id"])
                    rejected = sum(r["status"] == "rejected" for r in rows)
                    duplicates = sum(r["status"] == "duplicate" for r in rows)
                    accepted = sum(r["status"] == "accepted" for r in rows)
                    if mode == "observed_wrong_count":
                        accepted = len(rows) - rejected - duplicates
                    reply = {"accepted": accepted, "rejected": rejected,
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
                   "SP_EVENT_NAME": event_name, "SP_INGEST_TOKEN": verified_marker,
                   "SP_USER_ID": "sender-user", "SP_ANONYMOUS_ID": "sender-anonymous"}
            if overrides:
                env.update(overrides)
            if omit:
                del env[omit]
            result = subprocess.run([sys.executable, str(HERE / "send.py")], env=env,
                                    text=True, capture_output=True, timeout=30)
            server.shutdown()
            thread.join()
        self.assertNotIn("synthetic-ingest-key", result.stdout + result.stderr)
        self.assertNotIn("synthetic-crash-key", result.stdout + result.stderr)
        self.assertFalse(verified_marker in result.stdout + result.stderr, "transport marker leaked")
        return result, requests

    def test_observed_counts_match_actual_accepted_rows(self):
        for mode in ("observed", "mixed_observed"):
            with self.subTest(mode=mode):
                result, requests = self.run_sender(mode)
                self.assertEqual(len(requests), 9)
                self.assertEqual(result.returncode, 1)
                self.assertTrue(json.loads(result.stdout.splitlines()[-1])["contract_match"])
        result, requests = self.run_sender("observed_wrong_count")
        self.assertFalse(json.loads(result.stdout.splitlines()[-1])["contract_match"])

    def test_stale_crash_ids_fail_each_crash_stage(self):
        result, requests = self.run_sender("stale_crash")
        replies = [json.loads(line) for line in result.stdout.splitlines() if '"latency_ms"' in line]
        crashes = [r for r in replies if r["stage"] in ("lua_nonfatal", "lua_fatal", "native_frame")]
        self.assertEqual(len(crashes), 3)
        for reply in crashes:
            with self.subTest(stage=reply["stage"]):
                self.assertFalse(reply["contract_match"])
        self.assertEqual(result.returncode, 1)

    def test_invalid_ports_fail_before_http(self):
        for field in ("SP_INGEST_URL", "SP_CRASH_URL"):
            for port in ("nope", "65536", "-1", "0"):
                with self.subTest(field=field, port=port):
                    result, requests = self.run_sender(overrides={field: "http://127.0.0.1:" + port})
                    self.assertEqual(result.returncode, 2)
                    self.assertEqual(requests, [])
                    self.assertIn(field, result.stdout)

    def test_missing_verified_configuration_never_uses_publishable_fallback(self):
        for field in ("SP_INGEST_TOKEN", "SP_USER_ID", "SP_ANONYMOUS_ID"):
            with self.subTest(field=field):
                result, requests = self.run_sender(omit=field)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(requests, [])
                self.assertIn(field, result.stdout)
        self.assertIn("Mode B", self.run_sender(omit="SP_INGEST_TOKEN")[0].stdout)

    def test_grant_and_events_share_verified_identity(self):
        result, requests = self.run_sender("verified_grant")
        self.assertEqual(len(requests), 9)
        self.assertTrue(json.loads(result.stdout.splitlines()[-1])["contract_match"])
        self.assertEqual(requests[0][1]["actor_identifier"], "sender-user")
        self.assertEqual(requests[0][1]["kind"], "user_verified")
        for path, body, authorization in requests:
            if "events" in body and authorization:
                self.assertTrue(authorization == requests[0][2], "grant/event authority differs")
                for event in body["events"]:
                    self.assertEqual(event["user_id"], "sender-user")
                    self.assertEqual(event["anonymous_id"], "sender-anonymous")

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
