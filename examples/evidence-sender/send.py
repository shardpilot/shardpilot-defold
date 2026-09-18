#!/usr/bin/env python3
"""Headless Lua SDK sender. Network use happens only in main()/run()."""
import json
import ipaddress
import os
from pathlib import Path
import platform
import re
import sys
import time
from urllib import error, parse, request

from lupa.lua51 import LuaRuntime, lua_type
import lupa

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
FIELDS = ("ingest_url", "ingest_token", "user_id", "anonymous_id",
          "workspace_id", "app_id", "environment_id", "crash_url", "crash_key", "crash_app_id")
# The case names are the Go protocol witness's, because an aggregate checker
# reads them: keep `single`, `realistic-batch` and `mixed-size` spelled exactly
# so a log from this sender is readable by the same script. `stage` rides beside
# `case` carrying this sender's earlier name for older evidence logs.
LEGACY_STAGES = {"single": "minimal", "realistic-batch": "batch", "mixed-size": "mixed_size",
                 "lua-nonfatal": "lua_nonfatal", "lua-fatal": "lua_fatal", "native-json": "native_frame"}
CRASH_CASES = ("lua-nonfatal", "lua-fatal", "native-json", "raw-text")
# The session lifecycle rides its own exchanges so the counted cases carry
# exactly the events a reader expects to see verdicts for.
CASES = ("consent", "session-open", "single", "session-close", "realistic-batch",
         "session-resume", "mixed-size") + CRASH_CASES + ("unauthenticated", "duplicate")
SESSION_START, SESSION_END = "app.session_started", "app.session_ended"
# The PLANNED shape of each counted case and of the run's session lifecycle,
# stated here instead of derived from whatever the sender happened to send. A
# batch that lost an event would otherwise be judged against its own smaller
# self and pass.
PLANNED = {"single": {"accepted": 1, "rejected": 0},
           "realistic-batch": {"accepted": 4, "rejected": 0, "sessions": 2},
           "mixed-size": {"accepted": 1, "rejected": 1},
           "session-open": {"accepted": 1, "rejected": 0, "carries": SESSION_START},
           "session-close": {"accepted": 1, "rejected": 0, "carries": SESSION_END},
           "session-resume": {"accepted": 1, "rejected": 0, "carries": SESSION_START}}
PLANNED_SESSIONS = 4
# Three of those sessions are ENDED in the run — the one around `single` and
# realistic-batch's two — and only the resumed one is left open.
PLANNED_ENDED_SESSIONS = 3
# How the SDK settles a refused admission probe, per status. 401 reaches the
# client as unauthorized+retryable (transport.lua), and Mode B keeps such a
# batch for a re-minted retry; 403 falls through as a terminal http_403 —
# neither unauthorized nor retryable — so the batch is dropped and nothing is
# owed. Measured on the loopback fixture: dropped stays 0 for 401 and becomes 1
# for 403.
PROBE_SETTLEMENT = {
    401: ("retained", "401 is unauthorized and retryable, and a token_provider is configured, so the "
                      "SDK RETAINS this batch for a re-minted retry. No public surface drops it: a "
                      "further flush re-attempts it and shutdown() re-attempts it and then refuses "
                      "teardown. This witness allows one attempt per case, so that retry is NOT "
                      "EXERCISED; spool_enabled is false, so the obligation does not survive the "
                      "process."),
    403: ("dropped", "403 is neither unauthorized nor retryable to the SDK (a terminal http_403), so "
                     "the batch is DROPPED at the failure and nothing is owed: the SDK's own counters "
                     "show it dropped and no retry is pending."),
}
# Captures this pure-Lua SDK cannot produce headlessly. Printed as absent
# rather than simulated: a fabricated platform capture would read exactly like
# a real one in the evidence.
NOT_EXERCISED = (
    "previous-session engine dump (crash.capture_previous needs the Defold crash module)",
    "sys.set_error_handler installation and the script-error hook it feeds",
    "ANR/hang watchdog", "minidump upload", "Android tombstone upload",
    "Unreal crash-context upload", "symbolication of the native fixture",
    "session_ended duration_ms property (session_end carries only a reason)",
    "the SDK's own retry of a 401-refused admission probe: the status is retryable when a "
    "token_provider is configured, so the batch stays retained and this witness reports that "
    "settlement instead of taking a second attempt (a 403 refusal is dropped by the SDK and "
    "leaves nothing owed)",
)


class RefuseRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def checked_hostname(url):
    host = url.hostname or ""
    if url.netloc.startswith("["):
        if "%" in host or not re.fullmatch(r"\[[^\]]+\](?::[0-9]+)?", url.netloc):
            raise ValueError("invalid or unsupported IP literal")
        return "[" + str(ipaddress.IPv6Address(host)) + "]"
    # RFC 3986 reg-name spelling, then the decoded name used by the resolver.
    chars = r"[A-Za-z0-9._~!$&'()*+,;=-]"
    if not re.fullmatch(r"(?:" + chars + r"|%[0-9A-Fa-f]{2})+", host):
        raise ValueError("invalid registered name")
    host = parse.unquote(host, errors="strict").encode("idna").decode("ascii")
    if not re.fullmatch(chars + "+", host):
        raise ValueError("invalid decoded registered name")
    return host


def configuration():
    values = {name: os.environ.get("SP_" + name.upper(), "") for name in FIELDS}
    missing = ["SP_" + name.upper() for name, value in values.items() if not value.strip()]
    if "SP_INGEST_TOKEN" in missing:
        raise ValueError("SP_INGEST_TOKEN is required: an OWNER-SUPPLIED Mode B credential must record the grant; a publishable key cannot grant consent")
    if missing:
        raise ValueError("missing environment variables: " + ", ".join(missing))
    for name in ("ingest_url", "crash_url"):
        try:
            if any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in values[name]):
                raise ValueError("URL contains whitespace or control characters")
            u = parse.urlsplit(values[name])
            if u.netloc.endswith(":"):
                raise ValueError("empty explicit port")
            port = u.port
            host = checked_hostname(u)
        except ValueError:
            raise ValueError("SP_" + name.upper() + " has an invalid base URL, hostname or port") from None
        if port is not None and port < 1:
            raise ValueError("SP_" + name.upper() + " port must be between 1 and 65535")
        if (u.scheme not in ("http", "https") or not u.hostname
                or u.username is not None or u.password is not None
                or "?" in values[name] or "#" in values[name] or u.path not in ("", "/")
                or (u.scheme == "http" and u.hostname not in ("localhost", "127.0.0.1", "::1"))):
            raise ValueError("SP_" + name.upper() + " must be an HTTPS base URL (HTTP only on loopback)")
        authority = host + (":" + str(port) if port is not None else "")
        values[name] = parse.urlunsplit((u.scheme, authority, "", "", ""))
    values["event_name"] = os.environ.get("SP_EVENT_NAME", "play_cta_click").strip()
    if not values["event_name"]:
        raise ValueError("SP_EVENT_NAME must name a registered event")
    return values


def from_lua(value):
    if lua_type(value) != "table":
        return value
    keys = list(value.keys())
    if keys and set(keys) == set(range(1, len(keys) + 1)):
        return [from_lua(value[i]) for i in range(1, len(keys) + 1)]
    return {key: from_lua(value[key]) for key in keys}


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def check_reply(case, sent, status, body):
    if case == "unauthenticated":
        return status in (401, 403)
    if status != 202 and case != "consent":
        return False
    try:
        reply = json.loads(body)
        if not isinstance(reply, dict):
            return False
        if case == "consent":
            return 200 <= status < 300 and reply.get("recorded") is True
        if case in CRASH_CASES:
            # A fingerprint is what makes the acknowledgement a GROUPED crash
            # rather than an accepted byte count; an absent or blank one leaves
            # the report unattributable, so it fails the case here as it does
            # for the Go witness.
            return (isinstance(reply.get("crash_id"), str) and bool(reply["crash_id"].strip())
                    and reply["crash_id"] == sent["crash_id"]
                    and isinstance(reply.get("fingerprint"), str) and bool(reply["fingerprint"].strip())
                    and reply.get("suppressed") is not True)
        events = sent["events"]
        rows = reply["events"]
        # ALL FOUR counters, present and non-negative. A defaulted `suppressed`
        # let a run exit 0 over a body that an aggregate reader indexing all
        # four raises on — the receipt would contradict the log it points at.
        if (reply.get("validation_only") or not isinstance(rows, list) or len(rows) != len(events)
                or not all(type(reply.get(k)) is int and reply[k] >= 0
                           for k in ("accepted", "rejected", "duplicates", "suppressed"))):
            return False
        suppressed = reply["suppressed"]
        by_id = {row["event_id"]: row for row in rows}
        if len(by_id) != len(events) or set(by_id) != {e["event_id"] for e in events}:
            return False
        for event in events:
            row = by_id[event["event_id"]]
            oversized = case == "mixed-size" and len(encode(event).encode()) > 2048
            if case == "duplicate":
                if row.get("status") != "duplicate" or row.get("code") != "duplicate_event_id":
                    return False
            elif oversized:
                if row.get("status") != "rejected" or row.get("code") != "event_too_large":
                    return False
            elif row.get("status") != "accepted":
                # EXACTLY ONE verdict, and it is `accepted`. `observed` is in
                # none of the four aggregate counters, so admitting it here let
                # a run exit 0 while the counters the run plan checks read
                # 0/0/0/0 — a receipt that disagreed with itself. Observed-only,
                # duplicate, suppressed, unknown and missing verdicts all fail a
                # normal admission case; `duplicate` is the one case where a
                # duplicate verdict is the expectation.
                return False
        rejected = 1 if case == "mixed-size" else 0
        duplicates = len(events) if case == "duplicate" else 0
        accepted = sum(row.get("status") == "accepted" for row in rows)
        plan = PLANNED.get(case)
        if plan is not None and (len(events) != plan["accepted"] + plan["rejected"]
                                 or reply["accepted"] != plan["accepted"]
                                 or reply["rejected"] != plan["rejected"]):
            # The PLANNED cardinality, not one derived from this batch.
            return False
        counters = (reply["accepted"], rejected, duplicates, 0)
        return (reply["accepted"] == accepted
                and reply["rejected"] == rejected and reply["duplicates"] == duplicates
                and suppressed == 0
                # The invariant an aggregate reader checks: the four disjoint
                # counters account for every row and nothing else.
                and sum(counters) == len(rows))
    except (ValueError, KeyError, TypeError):
        return False


class Sender:
    def __init__(self, config):
        self.config = config
        self.case = "setup"
        self.records = []
        self.raw = {}
        self.rejected_events = 0
        # What the SDK told the CALLER, through the two documented surfaces:
        # the diagnostics hook and the retained rejection queue.
        self.issues = []
        self.rejections = []
        self.oversize_event_id = ""
        # What the SDK reported about the refused admission probe.
        self.probe = None
        self.sessions = []
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.opener = request.build_opener(request.ProxyHandler({}), RefuseRedirect())

    def log(self, value):
        line = encode(value)
        for name in ("ingest_token", "crash_key"):
            # Also scrub JSON-escaped echoes in a server body or an exception.
            for secret in (self.config[name], encode(self.config[name])[1:-1]):
                line = line.replace(secret, "[REDACTED]")
        print(line, flush=True)

    def record_issue(self, issue):
        self.issues.append(issue)
        self.log({"case": "sdk-issue", "issue": issue})

    def record_probe(self, published, error, snapshot):
        # The settlement STATEMENT is derived from the status the door actually
        # returned, because the SDK settles the two refusals differently. An
        # unconditional sentence would misdescribe one of them.
        attempts = [r for r in self.records if r["case"] == "unauthenticated"]
        status = attempts[-1]["status"] if attempts else 0
        settlement, reason = PROBE_SETTLEMENT.get(status, ("unknown",
            "the door answered neither 401 nor 403, so this case took no admission measurement"))
        self.probe = {"flush_ok": published is True, "flush_error": error, "status": status,
                      "settlement": settlement,
                      "snapshot": snapshot if isinstance(snapshot, dict) else {}}
        self.log({"case": "probe-settlement", "status": status, "settlement": settlement,
                  "flush_ok": self.probe["flush_ok"], "flush_error": self.probe["flush_error"],
                  "snapshot": self.probe["snapshot"], "sdk_classification": reason})

    def record_rejections(self, rows):
        self.rejections = rows if isinstance(rows, list) else []
        self.log({"case": "caller-view", "sdk_rejections": self.rejections,
                  "source": "client:get_rejections()"})

    def exchange(self, url, method, headers, body):
        sent = json.loads(body)
        if self.case == "mixed-size":
            sizes = [len(encode(e).encode()) for e in sent["events"]]
            if len(sizes) != 2 or not (sizes[0] <= 2048 < sizes[1]):
                raise ValueError("mixed-size did not contain one small and one oversize SDK event")
            self.oversize_event_id = sent["events"][1]["event_id"]
        else:
            sizes = [len(encode(e).encode()) for e in sent.get("events", [])]
        if self.case == "unauthenticated":
            # The credential is removed at the transport boundary rather than
            # withheld from the SDK, so the envelope is the one the SDK built.
            headers = {k: v for k, v in headers.items() if k.lower() != "authorization"}
        started = time.perf_counter()
        status, received, response_headers = 0, "", {}
        try:
            req = request.Request(url, data=body.encode(), headers=headers, method=method)
            try:
                response = self.opener.open(req, timeout=15)
            except error.HTTPError as exc:
                response = exc
            with response:
                status = response.code
                response_headers = {k.lower(): v for k, v in response.headers.items()}
                raw = response.read(1024 * 1024 + 1)
                if len(raw) > 1024 * 1024:
                    raise ValueError("response exceeds 1 MiB; evidence incomplete")
                received = raw.decode("utf-8")
        except (OSError, ValueError) as exc:
            status, received = 0, str(exc)
        passed = check_reply(self.case, sent, status, received)
        event_result = None
        try:
            reply = json.loads(received)
            if isinstance(reply, dict) and "events" in sent:
                event_result = {k: reply.get(k) for k in ("accepted", "rejected", "duplicates", "suppressed", "events")}
                if type(reply.get("rejected")) is int and reply["rejected"] > 0:
                    self.rejected_events += reply["rejected"]
        except ValueError:
            pass
        # ONE line per attempted exchange, carrying the request detail beside
        # the reply: an aggregate checker reads `case`, `status` and
        # `response_body` from a single record. `request_id` prints MISSING
        # where the Go witness prints an empty string.
        record = {"case": self.case, "stage": LEGACY_STAGES.get(self.case, self.case),
                  "method": method, "route": parse.urlsplit(url).path or "/", "url": url,
                  "status": status, "response_body": received,
                  "request_id": response_headers.get("x-request-id", "MISSING"),
                  "request_body": sent, "event_bytes": sizes,
                  "authorization_present": any(k.lower() == "authorization" for k in headers),
                  "latency_ms": round((time.perf_counter() - started) * 1000, 3),
                  "event_result": event_result, "contract_match": passed}
        self.log(record)
        self.records.append(record)
        self.raw.setdefault(self.case, (url, method, headers, body))
        return {"status": status, "response": received, "headers": response_headers}

    def http(self, url, method, callback, headers, body, options):
        response = self.exchange(url, method, from_lua(headers), body)
        callback(None, None, self.lua.table_from(response, recursive=True))

    def caller_view_holds(self):
        """The mixed outcome as the CALLER sees it: the accepted sibling
        acknowledged, the rejected id and its reason retained and handed to the
        diagnostics hook, and the rejected event never sent again."""
        mixed = [r for r in self.records if r["case"] == "mixed-size"]
        if len(mixed) != 1 or not self.oversize_event_id:
            return False
        rows = (mixed[0].get("event_result") or {}).get("events") or []
        sibling = [row for row in rows if row.get("event_id") != self.oversize_event_id]
        if len(sibling) != 1 or sibling[0].get("status") != "accepted":
            return False
        retained = [r for r in self.rejections if r.get("event_id") == self.oversize_event_id]
        told = [i for i in self.issues if i.get("event_id") == self.oversize_event_id]
        carried = sum(self.oversize_event_id in encode(r["request_body"]) for r in self.records)
        if len(self.rejections) != 1 or len(retained) != 1 or len(told) != 1 or carried != 1:
            return False
        # WHAT the caller was told, not merely that it was told something: the
        # retained record and the hook issue must both name a per-EVENT
        # REJECTION. An id and a code alone would also match an issue the SDK
        # raised about something else.
        return (retained[0].get("code") == "event_too_large"
                and retained[0].get("status") == "rejected"
                and told[0].get("code") == "event_too_large"
                and told[0].get("status") == "rejected"
                and told[0].get("scope") == "event")

    def session_lifecycle_holds(self):
        """Every analytics fact rides a session this sender OPENED, and nothing
        follows that session's end. `duplicate` is exempt: it replays the single
        event's captured bytes, which were built and sent before that session
        was closed, so its position in the log is a replay and not a new fact."""
        opened, ended, sequences = {}, {}, {}
        for record in self.records:
            if record["case"] == "duplicate":
                continue
            for event in record["request_body"].get("events") or []:
                session, name = event.get("session_id"), event.get("event_name")
                sequence = event.get("session_sequence")
                if not isinstance(session, str) or not session or type(sequence) is not int:
                    return False
                if session in ended:
                    return False
                sequences.setdefault(session, []).append(sequence)
                if name == SESSION_START:
                    if session in opened:
                        return False
                    opened[session] = sequence
                elif name == SESSION_END:
                    ended[session] = sequence
                elif session not in opened:
                    return False
        # Exactly the planned number of sessions: a run that lost one of the
        # lifecycle exchanges must not pass against its own shorter log.
        if (len(opened) != PLANNED_SESSIONS or set(ended) - set(opened)
                or len(ended) != PLANNED_ENDED_SESSIONS):
            return False
        for session, seen in sequences.items():
            # A start is always the session's first fact, and the sequence is a
            # per-session counter with no gaps; an end is its last.
            if opened.get(session) != 1 or seen != list(range(1, len(seen) + 1)):
                return False
            if session in ended and ended[session] != seen[-1]:
                return False
        self.sessions = sorted(opened)
        return True

    def probe_is_terminal(self):
        """The admission probe leaves nothing behind, and the receipt says which
        of the two settlements happened: the SDK did not claim delivery of a
        batch the door refused, the SDK's own counters match the classification
        for that status, the witness took exactly one attempt, and no other
        exchange carries the probe's event id."""
        attempts = [r for r in self.records if r["case"] == "unauthenticated"]
        if len(attempts) != 1 or self.probe is None or self.probe["flush_ok"]:
            return False
        status = attempts[0]["status"]
        expected = PROBE_SETTLEMENT.get(status)
        if expected is None or self.probe["status"] != status or self.probe["settlement"] != expected[0]:
            return False
        # 401: the batch is kept, so nothing is dropped. 403: it is dropped
        # exactly once, and nothing stays pending.
        snapshot = self.probe["snapshot"]
        if snapshot.get("dropped") != (0 if status == 401 else 1):
            return False
        # One failed batch, and NOTHING durable: a spooled envelope would
        # outlive the process and make the refusal an obligation for the next
        # run, which is the opposite of what this case reports.
        if snapshot.get("failed_batches") != 1 or snapshot.get("spooled") != 0:
            return False
        # The credential really was gone from the request. A 401 or 403 over a
        # request that still carried Authorization measures something else
        # entirely, and would pass as an admission refusal.
        if attempts[0].get("authorization_present") is not False:
            return False
        events = attempts[0]["request_body"].get("events") or []
        if len(events) != 1:
            return False
        probe_id = events[0]["event_id"]
        return sum(probe_id in encode(record["request_body"]) for record in self.records) == 1

    def planned_shape_holds(self):
        """Each counted case carries the cardinality this run PLANNED, and
        realistic-batch's four events are two start/end pairs with distinct
        session ids."""
        for case, plan in PLANNED.items():
            records = [r for r in self.records if r["case"] == case]
            if len(records) != 1:
                return False
            events = records[0]["request_body"].get("events") or []
            if len(events) != plan["accepted"] + plan["rejected"]:
                return False
            if plan.get("carries"):
                # The lifecycle exchange carries the event it exists for, for
                # the session the neighbouring case used: a `session-close`
                # that shipped a start would leave the run with an unended
                # session and the same exchange count.
                if [e.get("event_name") for e in events] != [plan["carries"]]:
                    return False
                if plan["carries"] == SESSION_END:
                    single = [r for r in self.records if r["case"] == "single"]
                    if len(single) != 1:
                        return False
                    facts = single[0]["request_body"].get("events") or []
                    if len(facts) != 1 or facts[0].get("session_id") != events[0].get("session_id"):
                        return False
            if not plan.get("sessions"):
                continue
            sessions = {}
            for event in events:
                sessions.setdefault(event.get("session_id"), []).append(event)
            if len(sessions) != plan["sessions"]:
                return False
            for facts in sessions.values():
                if [f.get("event_name") for f in facts] != [SESSION_START, SESSION_END]:
                    return False
                if [f.get("session_sequence") for f in facts] != [1, 2]:
                    return False
        return True

    def run(self):
        g = self.lua.globals()
        # Keep embedded Lua warnings inside the redacted JSON evidence stream.
        g.print = lambda *values: self.log({"case": "sdk-warning",
                                            "sdk_warning": "\t".join(str(v) for v in values)})
        g.bridge_encode = lambda v: encode(from_lua(v))
        g.bridge_decode = lambda v: self.lua.table_from(json.loads(v), recursive=True)
        g.bridge_http = self.http
        g.bridge_time = time.time
        g.bridge_stage = lambda value: setattr(self, "case", value)
        g.bridge_issue = lambda value: self.record_issue(from_lua(value))
        g.bridge_rejections = lambda value: self.record_rejections(from_lua(value))
        g.bridge_probe = lambda published, error, snapshot: self.record_probe(
            published, from_lua(error), from_lua(snapshot))
        g.package.path = str(ROOT / "?.lua") + ";" + str(ROOT / "?" / "init.lua")
        self.lua.execute("""
            json = { encode = function(v) return bridge_encode(v) end,
                     decode = function(v) return bridge_decode(v) end }
            http = { request = function(...) return bridge_http(...) end }
            socket = { gettime = function() return bridge_time() end }
            stage = function(v) bridge_stage(v) end
            report_issue = function(v) bridge_issue(v) end
            report_rejections = function(v) bridge_rejections(v) end
            report_probe = function(ok, err, snap) bridge_probe(ok, err, snap) end
        """)
        self.log({"case": "runtime", "python": platform.python_version(), "lupa": lupa.__version__,
                  "lua": self.lua.lua_implementation, "sdk": str(ROOT / "shardpilot"),
                  "coverage": "headless SDK + HTTP; no Defold engine, persistence or real native crash"})
        self.log({"case": "not-exercised", "captures": list(NOT_EXERCISED)})
        self.lua.execute((HERE / "send.lua").read_text())(self.lua.table_from(self.config))
        # Replay the actual SDK wire bytes of the single event, authenticated,
        # to measure idempotency. The unauthenticated case is its own fresh SDK
        # event (send.lua), never this id.
        url, method, headers, body = self.raw["single"]
        self.case = "duplicate"
        self.exchange(url, method, headers, body)
        by_case = {}
        for record in self.records:
            by_case.setdefault(record["case"], []).append(record)
        one_attempt = all(len(attempts) == 1 for attempts in by_case.values())
        caller_view = self.caller_view_holds()
        probe_terminal = self.probe_is_terminal()
        sessions_ok = self.session_lifecycle_holds()
        plan_ok = self.planned_shape_holds()
        passed = (set(by_case) == set(CASES) and one_attempt and caller_view and probe_terminal
                  and sessions_ok and plan_ok
                  and all(record["contract_match"] for record in self.records))
        # The deliberate oversize rejection is a PASSING rejection: it is the
        # measurement the mixed-size case exists to take. A rejection in any
        # other case fails that case's contract above, so it still exits 1.
        exit_code = 0 if passed else 1
        self.log({"case": "summary", "requests": len(self.records), "contract_match": passed,
                  "cases": sorted(by_case), "one_attempt_per_case": one_attempt,
                  "caller_view_ok": caller_view, "probe_terminal": probe_terminal,
                  "sessions_ok": sessions_ok, "sessions": len(self.sessions),
                  "plan_ok": plan_ok, "probe_settlement": self.probe["settlement"] if self.probe else "none",
                  "rejected_events": self.rejected_events, "exit_code": exit_code})
        return exit_code


def main():
    try:
        config = configuration()
    except ValueError as exc:
        # Every JSON line carries `case`, including this one: a reader that
        # keys on it must not fault on a configuration-failure log.
        print(encode({"case": "configuration", "configuration_error": str(exc), "exit_code": 2}))
        return 2
    sender = Sender(config)
    try:
        return sender.run()
    except Exception as exc:
        sender.log({"case": "sender-error", "sender_error": str(exc), "exit_code": 1})
        return 1


if __name__ == "__main__":
    sys.exit(main())
