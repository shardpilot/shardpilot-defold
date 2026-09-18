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
                        self.assertEqual(len(calls), 13)
                        self.assertTrue(any(call.startswith(canonical) for call in calls))
                        self.assertIn('"lua":', output)

    def test_all_four_counters_must_be_present_integers(self):
        for mode in ("good",):
            with self.subTest(mode=mode):
                result, requests = self.run_sender(mode)
                self.assertEqual(len(requests), 13)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(json.loads(result.stdout.splitlines()[-1])["contract_match"])
        # A MISSING counter fails like a malformed one: an aggregate reader
        # indexes all four, so a defaulted `suppressed` would have let this
        # sender exit 0 over a body that raises on the reader.
        for mode in ("counter_null", "counter_string", "counter_bool", "counter_negative",
                     "counter_positive", "suppressed_row", "missing_suppressed",
                     "missing_suppressed_observed"):
            with self.subTest(mode=mode):
                result, requests = self.run_sender(mode)
                self.assertEqual(len(requests), 13)
                self.assertEqual(result.returncode, 1)
                self.assertFalse(json.loads(result.stdout.splitlines()[-1])["contract_match"])
                if mode == "suppressed_row":
                    self.assertIn("suppressed_no_consent", result.stdout)

    def run_sender(self, mode="good", omit=None, event_name="play_cta_click", overrides=None):
        requests = []
        batches = []
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
                    # 401 and 403 are both a passing refusal for the probe, and
                    # the SDK classifies them differently (transport.lua): 401
                    # is unauthorized+retryable, 403 falls through as a terminal
                    # http_403. Both statuses get a scene.
                    status = {"unauth_allowed": 202, "unauth_403": 403}.get(mode, 401)
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
                    # A grouped acknowledgement carries a fingerprint; the two
                    # mutants below answer with a blank one and with none.
                    if mode != "crash_missing_fingerprint":
                        reply["fingerprint"] = "   " if mode == "crash_blank_fingerprint" else "fixture-fingerprint"
                    if mode != "legacy" and any(not m.get("load_address") or not m.get("size") for m in body.get("modules", [])):
                        status, reply = 400, {"code": "invalid_request", "message": "module bounds required"}
                else:
                    batches.append(self.path)
                    rows = []
                    for index, event in enumerate(body["events"]):
                        oversized = len(json.dumps(event, separators=(",", ":")).encode()) > 2048
                        if mode == "oversize_accepted":
                            oversized = False
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
                    # A rejection OUTSIDE mixed-size: only the deliberate
                    # oversize one is a passing rejection.
                    # Batch 1 is the session-open exchange; batch 2 is `single`.
                    if mode == "reject_in_single" and len(batches) == 2:
                        rows[0].update(status="rejected", code="event_too_large")
                    # A verdict the sender cannot match to anything it sent.
                    if mode == "renamed_row" and len(batches) == 2:
                        rows[0]["event_id"] = rows[0]["event_id"] + "-renamed"
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
                    # The SDK's own session lifecycle names are registered like
                    # any other plan entry; only the operator-supplied name is
                    # under test for registration.
                    registered = ("play_cta_click", "fixture_registered_click",
                                  "app.session_started", "app.session_ended")
                    if mode != "legacy" and any(e["event_name"] not in registered for e in body["events"]):
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

    def test_an_observed_verdict_is_not_an_accepted_one(self):
        """`observed` is in none of the four aggregate counters the run plan
        checks, so a run that treated it as success would exit 0 carrying a log
        that says nothing was accepted."""
        for mode in ("observed", "mixed_observed", "observed_wrong_count"):
            with self.subTest(mode=mode):
                result, requests = self.run_sender(mode)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertFalse(json.loads(result.stdout.splitlines()[-1])["contract_match"])
                replies = [json.loads(line) for line in result.stdout.splitlines()
                           if '"latency_ms"' in line]
                self.assertFalse(next(r for r in replies if r["case"] == "single")["contract_match"])
        # And the aggregate check the run plan runs agrees with that verdict on
        # a healthy run: every accepted id is counted.
        result, requests = self.run_sender()
        single = next(json.loads(line) for line in result.stdout.splitlines()
                      if line.startswith("{") and json.loads(line).get("case") == "single")
        body = json.loads(single["response_body"])
        self.assertEqual([row["status"] for row in body["events"]], ["accepted"])
        self.assertEqual(body["accepted"], 1)

    def test_stale_crash_ids_fail_each_crash_stage(self):
        result, requests = self.run_sender("stale_crash")
        replies = [json.loads(line) for line in result.stdout.splitlines() if '"latency_ms"' in line]
        crashes = [r for r in replies if r["case"] in send.CRASH_CASES]
        self.assertEqual(len(crashes), 4)
        for reply in crashes:
            with self.subTest(case=reply["case"]):
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
        self.assertEqual(len(requests), 13)
        self.assertTrue(json.loads(result.stdout.splitlines()[-1])["contract_match"])
        self.assertEqual(requests[0][1]["actor_identifier"], "sender-user")
        self.assertEqual(requests[0][1]["kind"], "user_verified")
        for path, body, authorization in requests:
            if "events" in body and authorization:
                self.assertTrue(authorization == requests[0][2], "grant/event authority differs")
                for event in body["events"]:
                    self.assertEqual(event["user_id"], "sender-user")
                    self.assertEqual(event["anonymous_id"], "sender-anonymous")

    def test_actual_sdk_and_all_ten_exchanges(self):
        result, requests = self.run_sender()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(requests), 13)
        self.assertTrue(all(e["source"] == "client" for r in requests for e in r[1].get("events", [])))
        replies = [json.loads(line) for line in result.stdout.splitlines() if '"latency_ms"' in line]
        self.assertEqual(len(replies), 13)
        # ONE line per exchange, each carrying the fields a reader keys on.
        self.assertEqual([r["case"] for r in replies], list(send.CASES))
        for reply in replies:
            with self.subTest(case=reply["case"]):
                for field in ("case", "method", "route", "status", "response_body", "request_id"):
                    self.assertIn(field, reply)
                self.assertTrue(reply["route"].startswith("/"))
        self.assertTrue(all(r["request_id"].startswith("fixture-") for r in replies))
        self.assertEqual(json.loads(result.stdout.splitlines()[-1]),
                         {"case": "summary", "requests": 13, "contract_match": True,
                          "cases": sorted(send.CASES), "one_attempt_per_case": True,
                          "caller_view_ok": True, "probe_terminal": True, "sessions_ok": True,
                          "sessions": 4, "plan_ok": True, "probe_settlement": "retained",
                          "rejected_events": 1, "exit_code": 0})
        self.assertEqual(next(r for r in replies if r["case"] == "single")["request_body"]["events"][0]["event_name"],
                         "play_cta_click")
        self.assertEqual(len(next(r for r in replies if r["case"] == "realistic-batch")["request_body"]["events"]), 4)
        # Two synthetic sessions, each a start and an end, in one batch.
        batch = next(r for r in replies if r["case"] == "realistic-batch")["request_body"]["events"]
        self.assertEqual([e["event_name"] for e in batch],
                         ["app.session_started", "app.session_ended"] * 2)
        self.assertEqual([e["session_sequence"] for e in batch], [1, 2, 1, 2])
        self.assertEqual(len({e["session_id"] for e in batch}), 2)
        self.assertEqual(len({e["event_id"] for e in batch}), 4)
        self.assertEqual(batch[0]["props"]["entry_point"], "synthetic_sender_first")
        self.assertEqual([batch[1]["props"]["reason"], batch[3]["props"]["reason"]],
                         ["completed", "backgrounded"])
        mixed = next(r for r in replies if r["case"] == "mixed-size")
        self.assertEqual(mixed["stage"], "mixed_size")
        self.assertEqual(mixed["event_result"]["rejected"], 1)
        self.assertEqual(mixed["event_result"]["events"][1]["code"], "event_too_large")
        # The frameless crash form travels on raw_text alone.
        raw = next(r for r in replies if r["case"] == "raw-text")["request_body"]
        self.assertNotIn("threads", raw)
        self.assertIn("stack traceback:", raw["raw_text"])
        # The admission probe is a FRESH event, never an accepted id, and its
        # credential is gone at the seam.
        unauth = next(r for r in replies if r["case"] == "unauthenticated")
        self.assertFalse(unauth["authorization_present"])
        probe = unauth["request_body"]["events"][0]["event_id"]
        self.assertEqual(sum(probe in json.dumps(r[1]) for r in requests), 1)
        # The authenticated replay is the single event's bytes, unchanged.
        single = next(r for r in replies if r["case"] == "single")
        self.assertEqual(requests[-1][1], single["request_body"])
        self.assertEqual(next(r for r in replies if r["case"] == "duplicate")["request_body"],
                         single["request_body"])
        # The sender names what it cannot capture instead of leaving the gap
        # to be inferred from a short log.
        absent = next(json.loads(line) for line in result.stdout.splitlines()
                      if json.loads(line).get("case") == "not-exercised")["captures"]
        self.assertIn("ANR/hang watchdog", absent)
        self.assertTrue(any("capture_previous" in item for item in absent))

    def test_registered_event_override(self):
        result, requests = self.run_sender(event_name="fixture_registered_click")
        names = {e["event_name"] for r in requests for e in r[1].get("events", [])}
        self.assertEqual(names, {"fixture_registered_click", "app.session_started", "app.session_ended"})
        self.assertTrue(json.loads(result.stdout.splitlines()[-1])["contract_match"])

    def test_only_the_mixed_size_rejection_is_a_passing_rejection(self):
        # The deliberate oversize rejection is the measurement the case exists
        # to take, so a complete run exits 0 while still recording it.
        result, requests = self.run_sender("legacy")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        summary = json.loads(result.stdout.splitlines()[-1])
        self.assertEqual((summary["rejected_events"], summary["exit_code"]), (1, 0))
        # A rejection anywhere else is not.
        result, requests = self.run_sender("reject_in_single")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        replies = [json.loads(line) for line in result.stdout.splitlines() if '"latency_ms"' in line]
        self.assertFalse(next(r for r in replies if r["case"] == "single")["contract_match"])

    def test_duplicate_replays_identical_sdk_body(self):
        result, requests = self.run_sender("legacy")
        original = requests[2]  # consent, session-open, single
        self.assertEqual([e["event_name"] for e in original[1]["events"]], ["play_cta_click"])
        self.assertEqual(sum(r == original for r in requests), 2)

    def test_native_module_has_bounds(self):
        result, requests = self.run_sender("legacy")
        modules = [m for r in requests for m in r[1].get("modules", [])]
        self.assertEqual(len(modules), 1)
        self.assertEqual(modules[0].get("load_address"), "0x1000")
        self.assertEqual(modules[0].get("size"), "0x2000")

    def test_failure_responses_are_nonzero(self):
        for mode in ("unauth_allowed", "wrong_reason", "empty_202", "crash_suppressed", "redirect",
                     "duplicate_accepted", "oversize_accepted", "renamed_row",
                     "crash_blank_fingerprint", "crash_missing_fingerprint", "reject_in_single"):
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
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(requests), 13)
        self.assertTrue(json.loads(result.stdout.splitlines()[-1])["contract_match"])
        self.assertIn("[REDACTED]", result.stdout)

    def test_run_plan_aggregate_checker_reads_the_log(self):
        """The production run plan checks the four disjoint counters from this
        log with its own script. That script keys on `case`, one line per
        exchange, with the Go witness's case names — so it is reproduced here
        verbatim against a real run instead of being trusted to still fit."""
        result, requests = self.run_sender()
        expected = {'single': (1, 0, 0, 0), 'realistic-batch': (4, 0, 0, 0),
                    'mixed-size': (1, 1, 0, 0)}
        seen = set()
        for line in result.stdout.splitlines():
            if not line.startswith('{'):
                continue
            exchange = json.loads(line)
            case = exchange['case']
            if case not in expected:
                continue
            self.assertNotIn(case, seen, 'duplicate exchange')
            seen.add(case)
            self.assertEqual(exchange['status'], 202, case)
            body = json.loads(exchange['response_body'])
            got = tuple(body[k] for k in ('accepted', 'rejected', 'duplicates', 'suppressed'))
            self.assertTrue(all(type(n) is int and n >= 0 for n in got), case)
            self.assertEqual(got, expected[case], case)
            self.assertEqual(sum(got), len(body['events']), case)
        self.assertEqual(seen, set(expected))

    def test_caller_sees_the_mixed_outcome_through_the_sdk(self):
        result, requests = self.run_sender()
        lines = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
        mixed = next(r for r in lines if r.get("case") == "mixed-size")
        rejected_id = mixed["event_result"]["events"][1]["event_id"]
        # The retained queue, read through the public API.
        view = next(r for r in lines if r.get("case") == "caller-view")
        self.assertEqual(view["source"], "client:get_rejections()")
        self.assertEqual([(row["event_id"], row["code"]) for row in view["sdk_rejections"]],
                         [(rejected_id, "event_too_large")])
        # The documented hook, which is how an integrator learns it inside a 202.
        told = [r["issue"] for r in lines if r.get("case") == "sdk-issue"
                and r["issue"].get("event_id") == rejected_id]
        self.assertEqual([issue["code"] for issue in told], ["event_too_large"])
        # Installing the hook replaces the SDK's default print warnings.
        self.assertNotIn('"sdk-warning"', result.stdout)
        # The accepted sibling is acknowledged, and the rejected event is not
        # resent although a second flush followed it.
        self.assertEqual(mixed["event_result"]["events"][0]["status"], "accepted")
        self.assertEqual(sum(r.get("case") == "mixed-size" for r in lines), 1)
        self.assertEqual(sum(rejected_id in json.dumps(r[1]) for r in requests), 1)
        self.assertTrue(json.loads(result.stdout.splitlines()[-1])["caller_view_ok"])

    def test_the_admission_probe_leaves_nothing_owed(self):
        """Both refusals pass the case, and the receipt states which settlement
        the SDK actually performed: 401 is retryable so the batch is kept, 403
        is terminal so it is dropped."""
        for mode, status, settlement, dropped in (("good", 401, "retained", 0),
                                                  ("unauth_403", 403, "dropped", 1)):
            with self.subTest(status=status):
                result, requests = self.run_sender(mode)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                lines = [json.loads(line) for line in result.stdout.splitlines()
                         if line.startswith("{")]
                probe = next(r for r in lines if r.get("case") == "probe-settlement")
                attempt = next(r for r in lines if r.get("case") == "unauthenticated"
                               and r.get("latency_ms") is not None)
                self.assertEqual(attempt["status"], status)
                self.assertEqual((probe["status"], probe["settlement"]), (status, settlement))
                self.assertEqual(probe["snapshot"]["dropped"], dropped)
                self.assertFalse(probe["flush_ok"])
                self.assertEqual(probe["snapshot"]["failed_batches"], 1)
                self.assertEqual(probe["snapshot"]["spooled"], 0)
                self.assertEqual(json.loads(result.stdout.splitlines()[-1])["probe_settlement"],
                                 settlement)
        result, requests = self.run_sender()
        lines = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
        probe = next(r for r in lines if r.get("case") == "probe-settlement")
        self.assertIn("NOT EXERCISED", probe["sdk_classification"])
        # One attempt, and the probe id is nowhere else in the run.
        attempts = [r for r in lines if r.get("case") == "unauthenticated"]
        self.assertEqual(len(attempts), 1)
        self.assertEqual(attempts[0]["status"], 401)
        probe_id = attempts[0]["request_body"]["events"][0]["event_id"]
        self.assertEqual(sum(probe_id in json.dumps(r[1]) for r in requests), 1)
        self.assertTrue(json.loads(result.stdout.splitlines()[-1])["probe_terminal"])
        # The owed Mode B retry is named on the printed list, not left to be
        # inferred from a short log.
        absent = next(r for r in lines if r.get("case") == "not-exercised")["captures"]
        self.assertTrue(any("401-refused admission probe" in item for item in absent))

    def test_every_fact_rides_a_session_this_sender_opened(self):
        result, requests = self.run_sender()
        lines = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
        replies = [r for r in lines if r.get("latency_ms") is not None]
        wire = [(r["case"], event["session_id"], event["event_name"], event["session_sequence"])
                for r in replies for event in (r["request_body"].get("events") or [])]
        sessions, order = {}, []
        for case, session, name, sequence in wire:
            if session not in sessions:
                sessions[session] = []
                order.append(session)
            sessions[session].append((case, name, sequence))
        # Four sessions: one around `single`, two paired inside
        # realistic-batch, one for the cases after them.
        self.assertEqual(len(order), 4)
        self.assertEqual(json.loads(result.stdout.splitlines()[-1])["sessions"], 4)
        first, second, third, fourth = (sessions[key] for key in order)
        self.assertEqual(first, [("session-open", send.SESSION_START, 1),
                                 ("single", "play_cta_click", 2),
                                 ("session-close", send.SESSION_END, 3),
                                 # The replay of the single event's captured
                                 # bytes, sent before that end and exempt.
                                 ("duplicate", "play_cta_click", 2)])
        for pair in (second, third):
            self.assertEqual([(name, sequence) for _, name, sequence in pair],
                             [(send.SESSION_START, 1), (send.SESSION_END, 2)])
            self.assertEqual({case for case, _, _ in pair}, {"realistic-batch"})
        self.assertEqual(fourth, [("session-resume", send.SESSION_START, 1),
                                  ("mixed-size", "play_cta_click", 2),
                                  ("mixed-size", "play_cta_click", 3),
                                  ("unauthenticated", "play_cta_click", 4)])
        # No fact carries a session id after that id's end, and no session is
        # opened lazily: every id has a start on the wire.
        for key, facts in sessions.items():
            names = [name for _, name, _ in facts]
            self.assertEqual(names[0], send.SESSION_START, key)
            self.assertLessEqual(names.count(send.SESSION_END), 1)
        self.assertTrue(json.loads(result.stdout.splitlines()[-1])["sessions_ok"])

    def planned_state(self, single=1, pairs=2, shared=False):
        """An in-memory sender whose counted cases carry the given shapes."""
        sender = send.Sender({name: "synthetic-" + name for name in send.FIELDS})
        batch = []
        for index in range(pairs):
            session = "s" if shared else "s%d" % index
            batch.append({"session_id": session, "event_name": send.SESSION_START,
                          "session_sequence": 1})
            batch.append({"session_id": session, "event_name": send.SESSION_END,
                          "session_sequence": 2})
        sender.records = [
            {"case": "single", "request_body": {"events": [{"event_id": "e%d" % i}
                                                           for i in range(single)]}},
            {"case": "realistic-batch", "request_body": {"events": batch}},
            {"case": "mixed-size", "request_body": {"events": [{"event_id": "small"},
                                                               {"event_id": "big"}]}},
        ]
        return sender

    def test_planned_cardinality_is_not_derived_from_what_was_sent(self):
        self.assertTrue(self.planned_state().planned_shape_holds())
        # Two events in `single`: a len(rows)-derived expectation would judge
        # this batch against itself and pass it.
        self.assertFalse(self.planned_state(single=2).planned_shape_holds())
        self.assertFalse(self.planned_state(single=0).planned_shape_holds())
        # One pair in realistic-batch instead of two, and two pairs sharing one
        # session id instead of two distinct ones.
        self.assertFalse(self.planned_state(pairs=1).planned_shape_holds())
        self.assertFalse(self.planned_state(pairs=3).planned_shape_holds())
        self.assertFalse(self.planned_state(shared=True).planned_shape_holds())
        # A counted case missing from the run, or attempted twice.
        missing = self.planned_state()
        missing.records = missing.records[1:]
        self.assertFalse(missing.planned_shape_holds())
        twice = self.planned_state()
        twice.records.append(dict(twice.records[0]))
        self.assertFalse(twice.planned_shape_holds())

    def session_state(self, *facts):
        """An in-memory sender whose wire log is the given (case, name,
        session, sequence) facts, one exchange each."""
        sender = send.Sender({name: "synthetic-" + name for name in send.FIELDS})
        sender.records = [{"case": case,
                           "request_body": {"events": [{"session_id": session, "event_name": name,
                                                        "session_sequence": sequence}]}}
                          for case, name, session, sequence in facts]
        return sender

    def four_sessions(self, *facts):
        """The three lifecycle pairs a healthy run carries beside `facts`, so a
        scene exercises one rule at a time against the planned session count."""
        filler = []
        for index in ("b", "c", "d"):
            filler.append(("realistic-batch", send.SESSION_START, index, 1))
            filler.append(("realistic-batch", send.SESSION_END, index, 2))
        return self.session_state(*(list(facts) + filler))

    def test_session_check_fails_on_an_orphan_or_a_fact_after_an_end(self):
        opened = ("session-open", send.SESSION_START, "a", 1)
        self.assertTrue(self.four_sessions(opened, ("single", "play_cta_click", "a", 2),
                                           ("session-close", send.SESSION_END, "a", 3)).session_lifecycle_holds())
        # Exactly the planned number of sessions: a lost lifecycle exchange
        # must not pass against its own shorter log.
        self.assertFalse(self.session_state(opened, ("single", "play_cta_click", "a", 2),
                                            ("session-close", send.SESSION_END, "a", 3)).session_lifecycle_holds())
        # The defect this replaces: a fact on a session that was already ended.
        self.assertFalse(self.four_sessions(
            opened, ("session-close", send.SESSION_END, "a", 2),
            ("mixed-size", "play_cta_click", "a", 3)).session_lifecycle_holds())
        # A lazily opened session — a fact whose session has no start on the
        # wire, which is what dropping the session_start produces.
        self.assertFalse(self.four_sessions(
            ("single", "play_cta_click", "lazy", 1)).session_lifecycle_holds())
        self.assertFalse(self.four_sessions(
            opened, ("single", "play_cta_click", "a", 2),
            ("mixed-size", "play_cta_click", "lazy", 1)).session_lifecycle_holds())
        # Two starts for one id, a start that is not the session's first fact,
        # and a gap in the per-session sequence.
        self.assertFalse(self.four_sessions(opened, ("session-resume", send.SESSION_START, "a", 2)).session_lifecycle_holds())
        self.assertFalse(self.four_sessions(("session-open", send.SESSION_START, "a", 2)).session_lifecycle_holds())
        self.assertFalse(self.four_sessions(opened, ("single", "play_cta_click", "a", 3)).session_lifecycle_holds())

    def probe_state(self, status=401, settlement="retained", dropped=0):
        """An in-memory sender whose probe settled cleanly."""
        sender = send.Sender({name: "synthetic-" + name for name in send.FIELDS})
        sender.records = [{"case": "unauthenticated", "status": status,
                           "request_body": {"events": [{"event_id": "probe"}]},
                           "event_result": None}]
        sender.probe = {"flush_ok": False, "flush_error": None, "status": status,
                        "settlement": settlement, "snapshot": {"dropped": dropped}}
        return sender

    def test_probe_check_fails_when_delivery_is_claimed_or_the_id_returns(self):
        self.assertTrue(self.probe_state().probe_is_terminal())
        self.assertTrue(self.probe_state(403, "dropped", 1).probe_is_terminal())
        # An UNCONDITIONAL settlement sentence: "retained" over a 403 the SDK
        # dropped, and "dropped" over a 401 it kept.
        self.assertFalse(self.probe_state(403, "retained", 1).probe_is_terminal())
        self.assertFalse(self.probe_state(401, "dropped", 0).probe_is_terminal())
        # The statement right but the SDK's own counters disagreeing with it.
        self.assertFalse(self.probe_state(401, "retained", 1).probe_is_terminal())
        self.assertFalse(self.probe_state(403, "dropped", 0).probe_is_terminal())
        # A status that takes no admission measurement at all.
        self.assertFalse(self.probe_state(500, "unknown", 0).probe_is_terminal())
        # flush() reporting success for a batch the door refused.
        claimed = self.probe_state()
        claimed.probe["flush_ok"] = True
        self.assertFalse(claimed.probe_is_terminal())
        # flush()'s result never read at all.
        ignored = self.probe_state()
        ignored.probe = None
        self.assertFalse(ignored.probe_is_terminal())
        # The retained batch resent under any case.
        resent = self.probe_state()
        resent.records.append({"case": "single", "request_body": {"events": [{"event_id": "probe"}]},
                               "event_result": None})
        self.assertFalse(resent.probe_is_terminal())
        # A second attempt at the case itself.
        twice = self.probe_state()
        twice.records.append(dict(twice.records[0]))
        self.assertFalse(twice.probe_is_terminal())

    def caller_view_state(self):
        """An in-memory sender whose row-4.5 evidence is complete. No network,
        no Lua run: the point is what the CHECK does, one field at a time."""
        sender = send.Sender({name: "synthetic-" + name for name in send.FIELDS})
        sender.oversize_event_id = "big"
        sender.records = [{"case": "mixed-size",
                           "request_body": {"events": [{"event_id": "small"}, {"event_id": "big"}]},
                           "event_result": {"events": [{"event_id": "small", "status": "accepted"},
                                                       {"event_id": "big", "status": "rejected"}]}}]
        sender.rejections = [{"event_id": "big", "code": "event_too_large"}]
        sender.issues = [{"event_id": "big", "code": "event_too_large"}]
        return sender

    def test_caller_view_check_fails_on_a_resend_or_an_unread_queue(self):
        self.assertTrue(self.caller_view_state().caller_view_holds())
        # A resend of the rejected event: the same id in a second request body.
        resent = self.caller_view_state()
        resent.records.append({"case": "single", "request_body": {"events": [{"event_id": "big"}]},
                               "event_result": None})
        self.assertFalse(resent.caller_view_holds())
        # The queue never read, or the hook never called: the evidence that the
        # caller was told is missing, so the row does not hold.
        unread = self.caller_view_state()
        unread.rejections = []
        self.assertFalse(unread.caller_view_holds())
        untold = self.caller_view_state()
        untold.issues = []
        self.assertFalse(untold.caller_view_holds())
        # A queue that names an event this run never sent.
        foreign = self.caller_view_state()
        foreign.rejections = [{"event_id": "other", "code": "event_too_large"}]
        self.assertFalse(foreign.caller_view_holds())
        # The accepted sibling unacknowledged.
        silent = self.caller_view_state()
        silent.records[0]["event_result"]["events"][0]["status"] = "rejected"
        self.assertFalse(silent.caller_view_holds())
        # A second attempt at the case at all.
        twice = self.caller_view_state()
        twice.records.append(dict(twice.records[0]))
        self.assertFalse(twice.caller_view_holds())


if __name__ == "__main__":
    unittest.main()
