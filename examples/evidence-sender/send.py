#!/usr/bin/env python3
"""Headless Lua SDK sender. Network use happens only in main()/run()."""
import json
import os
from pathlib import Path
import platform
import sys
import time
from urllib import error, parse, request

from lupa.lua51 import LuaRuntime, lua_type
import lupa

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
FIELDS = ("ingest_url", "ingest_key", "workspace_id", "app_id", "environment_id",
          "crash_url", "crash_key", "crash_app_id")


class RefuseRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def configuration():
    values = {name: os.environ.get("SP_" + name.upper(), "") for name in FIELDS}
    missing = ["SP_" + name.upper() for name, value in values.items() if not value.strip()]
    if missing:
        raise ValueError("missing environment variables: " + ", ".join(missing))
    for name in ("ingest_url", "crash_url"):
        u = parse.urlsplit(values[name])
        if (u.scheme not in ("http", "https") or not u.hostname or u.username or u.password
                or u.query or u.fragment or u.path not in ("", "/")
                or (u.scheme == "http" and u.hostname not in ("localhost", "127.0.0.1", "::1"))):
            raise ValueError("SP_" + name.upper() + " must be an HTTPS base URL (HTTP only on loopback)")
        values[name] = values[name].rstrip("/")
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


def check_reply(stage, sent, status, body):
    if stage == "unauthenticated":
        return status in (401, 403)
    if status != 202 and stage != "consent":
        return False
    try:
        reply = json.loads(body)
        if not isinstance(reply, dict):
            return False
        if stage == "consent":
            return 200 <= status < 300 and reply.get("recorded") is True
        if stage in ("lua_nonfatal", "lua_fatal", "native_frame"):
            return isinstance(reply.get("crash_id"), str) and bool(reply["crash_id"].strip()) and reply.get("suppressed") is not True
        events = sent["events"]
        rows = reply["events"]
        if (reply.get("validation_only") or not isinstance(rows, list) or len(rows) != len(events)
                or not all(type(reply.get(k)) is int for k in ("accepted", "rejected", "duplicates", "suppressed"))):
            return False
        by_id = {row["event_id"]: row for row in rows}
        if len(by_id) != len(events) or set(by_id) != {e["event_id"] for e in events}:
            return False
        for event in events:
            row = by_id[event["event_id"]]
            oversized = stage == "mixed_size" and len(encode(event).encode()) > 2048
            if stage == "duplicate":
                if row.get("status") != "duplicate" or row.get("code") != "duplicate_event_id":
                    return False
            elif oversized:
                if row.get("status") != "rejected" or row.get("code") != "event_too_large":
                    return False
            elif row.get("status") not in ("accepted", "observed"):
                return False
        rejected = 1 if stage == "mixed_size" else 0
        duplicates = len(events) if stage == "duplicate" else 0
        return (reply.get("accepted") == len(events) - rejected - duplicates
                and reply.get("rejected") == rejected and reply.get("duplicates") == duplicates
                and reply.get("suppressed") == 0)
    except (ValueError, KeyError, TypeError):
        return False


class Sender:
    def __init__(self, config):
        self.config = config
        self.stage = "setup"
        self.records = []
        self.rejected_events = 0
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.opener = request.build_opener(request.ProxyHandler({}), RefuseRedirect())

    def log(self, value):
        line = encode(value)
        for name in ("ingest_key", "crash_key"):
            # Also scrub JSON-escaped echoes in a server body or an exception.
            for secret in (self.config[name], encode(self.config[name])[1:-1]):
                line = line.replace(secret, "[REDACTED]")
        print(line, flush=True)

    def exchange(self, url, method, headers, body):
        sent = json.loads(body)
        if self.stage == "mixed_size":
            sizes = [len(encode(e).encode()) for e in sent["events"]]
            if len(sizes) != 2 or not (sizes[0] <= 2048 < sizes[1]):
                raise ValueError("mixed_size did not contain one small and one oversize SDK event")
        else:
            sizes = [len(encode(e).encode()) for e in sent.get("events", [])]
        self.log({"stage": self.stage, "method": method, "url": url,
                  "sent": sent, "event_bytes": sizes, "authorization_present": "Authorization" in headers})
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
        passed = check_reply(self.stage, sent, status, received)
        event_result = None
        try:
            reply = json.loads(received)
            if isinstance(reply, dict) and "events" in sent:
                event_result = {k: reply.get(k) for k in ("accepted", "rejected", "duplicates", "suppressed", "events")}
                if type(reply.get("rejected")) is int and reply["rejected"] > 0:
                    self.rejected_events += reply["rejected"]
        except ValueError:
            pass
        self.log({"stage": self.stage, "status": status, "body": received,
                  "request_id": response_headers.get("x-request-id", "MISSING"),
                  "latency_ms": round((time.perf_counter() - started) * 1000, 3),
                  "event_result": event_result, "contract_match": passed})
        self.records.append((self.stage, passed, url, method, headers, body))
        return {"status": status, "response": received, "headers": response_headers}

    def http(self, url, method, callback, headers, body, options):
        response = self.exchange(url, method, from_lua(headers), body)
        callback(None, None, self.lua.table_from(response, recursive=True))

    def run(self):
        g = self.lua.globals()
        g.bridge_encode = lambda v: encode(from_lua(v))
        g.bridge_decode = lambda v: self.lua.table_from(json.loads(v), recursive=True)
        g.bridge_http = self.http
        g.bridge_time = time.time
        g.bridge_stage = lambda value: setattr(self, "stage", value)
        g.package.path = str(ROOT / "?.lua") + ";" + str(ROOT / "?" / "init.lua")
        self.lua.execute("""
            json = { encode = function(v) return bridge_encode(v) end,
                     decode = function(v) return bridge_decode(v) end }
            http = { request = function(...) return bridge_http(...) end }
            socket = { gettime = function() return bridge_time() end }
            stage = function(v) bridge_stage(v) end
        """)
        self.log({"python": platform.python_version(), "lupa": lupa.__version__,
                  "lua": self.lua.lua_implementation, "sdk": str(ROOT / "shardpilot"),
                  "coverage": "headless SDK + HTTP; no Defold engine, persistence or real native crash"})
        self.lua.execute((HERE / "send.lua").read_text())(self.lua.table_from(self.config))
        # Replay the actual SDK wire bytes, first authenticated to measure
        # idempotency, then without Authorization to measure admission.
        minimal = next(r for r in self.records if r[0] == "minimal")
        self.stage = "duplicate"
        self.exchange(minimal[2], minimal[3], minimal[4], minimal[5])
        self.stage = "unauthenticated"
        self.exchange(minimal[2], minimal[3], {k: v for k, v in minimal[4].items()
                                             if k.lower() != "authorization"}, minimal[5])
        expected = {"consent", "minimal", "batch", "mixed_size", "lua_nonfatal",
                    "lua_fatal", "native_frame", "duplicate", "unauthenticated"}
        passed = len(self.records) == 9 and {r[0] for r in self.records} == expected and all(r[1] for r in self.records)
        exit_code = 1 if not passed or self.rejected_events else 0
        self.log({"requests": len(self.records), "contract_match": passed,
                  "rejected_events": self.rejected_events, "exit_code": exit_code})
        return exit_code


def main():
    try:
        config = configuration()
    except ValueError as exc:
        print(encode({"configuration_error": str(exc), "exit_code": 2}))
        return 2
    sender = Sender(config)
    try:
        return sender.run()
    except Exception as exc:
        sender.log({"sender_error": str(exc), "exit_code": 1})
        return 1


if __name__ == "__main__":
    sys.exit(main())
