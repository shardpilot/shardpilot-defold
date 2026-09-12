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

    def test_url_grammar_preflight(self):
        # One grammar table for both planes; None means a configuration refusal.
        cases = [
            ("https", "https://example.test", "https://example.test/"),
            ("case", "HTTPS://EXAMPLE.TEST", "https://example.test/"),
            ("root_path", "https://example.test/", "https://example.test/"),
            ("trailing_dot", "https://one-two.example.test.", "https://one-two.example.test./"),
            ("underscore", "https://under_score.test", "https://under_score.test/"),
            ("ipv4", "https://127.0.0.1", "https://127.0.0.1/"),
            ("ipv6", "https://[2001:DB8::1]", "https://[2001:db8::1]/"),
            ("loopback_name", "http://localhost", "http://localhost/"),
            ("loopback_ipv4", "http://127.0.0.1", "http://127.0.0.1/"),
            ("loopback_ipv6", "http://[::1]", "http://[::1]/"),
            ("port_min", "https://example.test:1", "https://example.test:1/"),
            ("port_max", "https://example.test:65535", "https://example.test:65535/"),
            ("port_leading_zero", "https://example.test:00443", "https://example.test:443/"),
            ("encoded_ascii", "https://%65xample.test:443", "https://example.test:443/"),
            ("encoded_utf8", "https://%c3%a9xample.test", "https://xn--xample-9ua.test/"),
            ("idna", "https://xn--xample-9ua.test", "https://xn--xample-9ua.test/"),
            ("scheme_missing", "//example.test", None),
            ("scheme_other", "ftp://example.test", None),
            ("http_remote", "http://example.test", None),
            ("host_missing", "https://", None),
            ("host_extra_slash", "https:///example.test", None),
            ("route_path", "https://example.test/api", None),
            ("double_path", "https://example.test//", None),
            ("query", "https://example.test?view=1", None),
            ("empty_query", "https://example.test?", None),
            ("fragment", "https://example.test#part", None),
            ("empty_fragment", "https://example.test#", None),
            ("userinfo", "https://user@example.test", None),
            ("empty_userinfo", "https://@example.test", None),
            ("empty_password", "https://:@example.test", None),
            ("leading_space", " https://example.test", None),
            ("raw_control", "https://bad\x01host", None),
            ("raw_del", "https://bad\x7fhost", None),
        ]
        for port in ("", "nope", "-1", "0", "65536"):
            for host in ("example.test", "[::1]"):
                cases.append(("port_" + host + "_" + port, "https://" + host + ":" + port, None))
        for host in ("bad%zz", "bad%", "bad%2", "bad%25zz", "bad%20host",
                     "bad%2fhost", "bad%40host", "bad%3ahost", "bad%00host",
                     "bad%ff", "bad host", "bad\\host", "bad\thost", "bad\nhost",
                     "[not-an-ip]", "[::1]junk", "[::1]:", "[fe80::1%25en0]", "[v1.future]"):
            cases.append(("host_" + host, "https://" + host, None))
        for field in ("SP_INGEST_URL", "SP_CRASH_URL"):
            for name, url, canonical in cases:
                with self.subTest(field=field, case=name):
                    result, calls, output = self.run_without_network(field, url)
                    if canonical is None:
                        self.assertEqual(len(calls), 0)
                        self.assertEqual(result, 2)
                        self.assertIn(field, output)
                    else:
                        self.assertEqual(result, 1)
                        self.assertEqual(len(calls), 9)
                        self.assertTrue(any(call.startswith(canonical) for call in calls))
                        self.assertIn('"lua":', output)

    def test_optional_suppression_aggregate_and_row_controls(self):
        for mode in ("good", "missing_suppressed", "missing_suppressed_observed"):
            with self.subTest(mode=mode):
                result, requests = self.run_sender(mode)
                self.assertEqual(len(requests), 9)
                self.assertEqual(result.returncode, 1)
                self.assertTrue(json.loads(result.stdout.splitlines()[-1])["contract_match"])
        for mode in ("counter_null", "counter_string", "counter_bool", "counter_negative",
                     "counter_positive", "suppressed_row"):
            with self.subTest(mode=mode):
                result, requests = self.run_sender(mode)
                self.assertEqual(len(requests), 9)
                self.assertEqual(result.returncode, 1)
                self.assertFalse(json.loads(result.stdout.splitlines()[-1])["contract_match"])
                if mode == "suppressed_row":
                    self.assertIn("suppressed_no_consent", result.stdout)

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
                        observed = mode in ("observed", "observed_wrong_count", "missing_suppressed_observed") or (mode == "mixed_observed" and index % 2 == 0)
                        rows.append({"event_id": event["event_id"],
                                     "status": "rejected" if oversized else "duplicate" if duplicate else "observed" if observed else "accepted",
                                     "code": ("wrong_reason" if mode == "wrong_reason" else "event_too_large") if oversized else "duplicate_event_id" if duplicate else "",
                                     "message": "synthetic fixture result"})
                        if not oversized:
                            seen.add(event["event_id"])
                    if mode == "suppressed_row" and rows:
                        rows[0].update(status="suppressed_no_consent", code="suppressed_no_consent")
                    rejected = sum(r["status"] in ("rejected", "suppressed_no_consent") for r in rows)
                    duplicates = sum(r["status"] == "duplicate" for r in rows)
                    accepted = sum(r["status"] == "accepted" for r in rows)
                    if mode == "observed_wrong_count":
                        accepted = len(rows) - rejected - duplicates
                    reply = {"accepted": accepted, "rejected": rejected,
                             "duplicates": duplicates, "suppressed": 0, "events": rows}
                    if mode in ("missing_suppressed", "missing_suppressed_observed", "suppressed_row"):
                        del reply["suppressed"]
                    if mode.startswith("counter_"):
                        reply["suppressed"] = {"counter_null": None, "counter_string": "0",
                                               "counter_bool": False, "counter_negative": -1,
                                               "counter_positive": 1}[mode]
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
        warnings = [json.loads(line)["sdk_warning"] for line in result.stdout.splitlines()
                    if "sdk_warning" in json.loads(line)]
        self.assertEqual(len(warnings), 1)
        self.assertIn(mixed["event_result"]["events"][1]["event_id"], warnings[0])
        self.assertIn("event_too_large", warnings[0])

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
