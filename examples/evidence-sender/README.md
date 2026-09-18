# Headless SDK evidence sender

Runs the checked-in Lua SDK through Lupa's Lua 5.1 runtime, with Python providing
JSON, HTTP and wall-clock time. It emits synthetic data to endpoints you supply.
It does not need the Defold editor. This tests SDK serialization and HTTP replies;
it does not prove Defold engine integration, disk durability, downstream analytics
visibility, crash symbolication, or object-storage access.

From the repository root, install the example's isolated dependency:

```sh
python3 -m venv .venv-evidence-sender
.venv-evidence-sender/bin/python -m pip install --only-binary=:all: -r examples/evidence-sender/requirements.txt
```

Requires Python 3.8 or later and the pinned [Lupa 2.8](https://pypi.org/project/lupa/2.8/)
wheel. This dependency belongs only to the example; the Defold library gains none.
No package-registry credentials are required. If your platform has no wheel,
installation fails instead of silently building an unmeasured runtime.

The operator must supply these **exported environment variables** before running:

| Variable | Value the operator supplies |
| --- | --- |
| `SP_INGEST_URL` | Ingest base URL, without a route, query or credential |
| `SP_INGEST_TOKEN` | **OWNER-SUPPLIED** short-lived Mode B ingest credential, authorized for the synthetic app and consent grant |
| `SP_USER_ID` | Synthetic verified user matching that credential's subject |
| `SP_ANONYMOUS_ID` | Synthetic anonymous identifier matching its signed `bind_anon` claim |
| `SP_WORKSPACE_ID` | Canonical workspace key matching that credential |
| `SP_APP_ID` | Canonical analytics app key |
| `SP_ENVIRONMENT_ID` | Analytics environment key |
| `SP_CRASH_URL` | Crash ingest base URL; this can differ from ingest and symbols-upload origins |
| `SP_CRASH_KEY` | Separate key with `crash:write` for the synthetic app |
| `SP_CRASH_APP_ID` | App identity expected by the crash key; verify its mapping explicitly |
| `SP_EVENT_NAME` | Optional registered tracking-plan name; defaults to `play_cta_click` |

These `SP_*` names are this repository's own convention and are unchanged. The
Go protocol witness (`shardpilot-go`, `examples/evidence`) reads the same facts
under `SHARDPILOT_*` names; an operator injecting both senders in one run maps
them as follows. `SP_USER_ID`, `SP_CRASH_APP_ID` and `SP_EVENT_NAME` have no Go
counterpart: the Go sender is anonymous-only, scopes crashes by `SHARDPILOT_APP_ID`
and sends `app.session_started`.

| This sender | Go witness |
| --- | --- |
| `SP_INGEST_URL` | `SHARDPILOT_INGEST_URL` |
| `SP_INGEST_TOKEN` | `SHARDPILOT_TOKEN` (the Go sender accepts a publishable ingest credential; this one requires a Mode B token because it also records consent) |
| `SP_ANONYMOUS_ID` | `SHARDPILOT_ANONYMOUS_ID` |
| `SP_WORKSPACE_ID` | `SHARDPILOT_WORKSPACE_ID` |
| `SP_APP_ID` | `SHARDPILOT_APP_ID` |
| `SP_ENVIRONMENT_ID` | `SHARDPILOT_ENVIRONMENT_ID` |
| `SP_CRASH_URL` | `SHARDPILOT_CRASH_INGEST_URL` |
| `SP_CRASH_KEY` | `SHARDPILOT_API_KEY` |

Do not paste credentials into commands, files, reports or shell history. The
sender reads them from its process environment. Both URLs require HTTPS except
on loopback; redirects and ambient HTTP proxies are disabled. No endpoint is
built in. Configure **both** planes first: missing configuration exits before HTTP.
Both explicit URL ports must be numeric and between 1 and 65535; an invalid port
is configuration error 2 before either plane sends. An explicit port delimiter
must have a value. User information, queries and fragments are forbidden even
when their delimiters have empty values; paths may only be empty or `/`.
Both hostnames are validated before constructing either client: ASCII registered
names (including IDNA names) or bracketed IPv6 literals. Percent escapes must be
well formed, decode as UTF-8, and yield a valid name after IDNA conversion; that
decoded name is used for requests. Whitespace, control characters, malformed
escapes, decoded delimiters and malformed IP literals exit 2 with zero HTTP.
Scoped IPv6 and IPvFuture literals are unsupported. This is syntax validation,
not a DNS, TLS or service-availability check.

The owner obtains the trusted credential through the authorized backend path.
This example never mints, installs, refreshes or prints one. `SP_INGEST_KEY` cannot
substitute for `SP_INGEST_TOKEN`: publishable-key grants are rejected by the
[consent contract](../../docs/privacy.md). Missing Mode B configuration exits 2
and sends nothing. Consent and analytics use the same SDK `token_provider`;
the SDK identifies the configured user before granting consent, and each event
carries that user and the configured anonymous binding. The owner must verify
the signed subject, binding, tenant/app/environment scope and sufficient remaining
lifetime for this run. The example supplies the same credential if the SDK asks
again; it cannot renew an expired credential. Local fixtures do not validate a
signature or prove live grant authority.

Exact run command, without a pipe:

```sh
.venv-evidence-sender/bin/python examples/evidence-sender/send.py
```

The run is **thirteen exchanges, one HTTP attempt each**, named with the Go
protocol witness's case names so one aggregate checker reads either sender's
log. Three of them carry only session lifecycle events: a counted case must
carry exactly the events a reader expects verdicts for, so the housekeeping
cannot ride with them.

| Case | What the SDK does | Go witness case |
| --- | --- | --- |
| `consent` | `set_consent(true)` for the configured verified user | none (the Go sender grants nothing) |
| `session-open` | `session_start` — every fact below rides a session this sender opened | none |
| `single` | one `track` of `SP_EVENT_NAME` | `single` |
| `session-close` | `session_end` — ended, not replaced | none |
| `realistic-batch` | two `session_start`/`session_end` pairs in ONE batch: four events, two sessions, each carrying sequence 1 for its start and 2 for its end, with an entry point and an end reason (finished, then backgrounded) | `realistic-batch` |
| `session-resume` | `session_start` — realistic-batch left its second session ended | none |
| `mixed-size` | one small `track` beside one with 2,500 padding characters, in ONE batch | `mixed-size` |
| `lua-nonfatal` | `emit` | none (Go has no nonfatal form) |
| `lua-fatal` | `emit_fatal`, pre-symbolicated Lua frame | `go-panic` |
| `native-json` | `emit_fatal`, synthetic SIGSEGV address plus module/debug identity | `native-json` |
| `raw-text` | `emit_fatal` with `raw_text` and no frames | `raw-text` |
| `unauthenticated` | a FRESH `track` whose Authorization the host removes at the transport seam; `flush`'s own result is recorded as evidence | `unauthenticated` |
| `duplicate` | the `single` event's captured bytes replayed once, authenticated | none |

**Every analytics fact rides a session this sender opened, and nothing follows
that session's end.** Both halves are checked on the wire log, and both were
real defects: with no explicit start the first `track` opens a session *lazily*
(a fresh id whose `app.session_started` never reaches the wire), so the facts
carried a session id that no start in the log explained; and `session_end` keeps
the id while clearing the active flag, so the cases after `realistic-batch`
landed their events on an **already ended** session with its sequence running
on. The receipt now reports `sessions_ok` and the session count, and requires:
every session id has a start as its first fact with sequence 1, at most one end
with no fact after it, and a per-session sequence with no gaps. The `duplicate`
case is exempt — it replays the single event's captured bytes, built and sent
before that session was closed, so its place in the log is a replay and not a
new fact. The resumed session is deliberately left **open**: ending it would
need a flush after the admission probe, and that flush would re-attempt the
batch the SDK retains for its Mode B retry. A game process that exits without a
shutdown leaves its session open the same way.

Analytics events other than the session events use `SP_EVENT_NAME`; every event
uses source `client`. The target must register that name, the two
`app.session_*` names and the synthetic properties. An unregistered name can
reject the whole batch with 400, unlike an oversize element's rejection within
202. The `unauthenticated` case is a fresh SDK event, never a replay of an
accepted one: reusing an accepted event ID would make the "no stored facts from
this ID" readback unjudgeable. Only `duplicate` replays captured bytes; it
demonstrates the idempotency contract, not the SDK's retry scheduler.
Compression is disabled so the byte counts describe sent elements. No automatic
retry loop, polling or shutdown event is added.

Output is newline-delimited JSON, and **every line carries a `case` key** —
including the runtime banner, the not-exercised list, SDK diagnostics and the
final summary — so a reader that keys on it never faults on a line it should
skip. Each attempted exchange is **one** line carrying `case`, `method`, `route`,
`status`, `response_body` and `request_id`, plus this sender's own detail: the
full synthetic request body, element sizes, `url`, `authorization_present`,
`latency_ms`, parsed counters with per-event status/code/message, and
`contract_match`. `request_id` prints `MISSING` where the Go witness prints an
empty string. `stage` rides beside `case` carrying this sender's earlier name
(`minimal`, `batch`, `mixed_size`, `native_frame`) so an older evidence log
stays comparable. Authorization values are never printed; configured keys are
scrubbed from echoed response/error text.

The size check expects **202 with one accepted/observed small event and one
`event_too_large` rejection**, matched by event ID. It requires per-element size
enforcement at **2,048 bytes** in the target; a different policy is a failed
measurement to explain, not an automatic flag change. Other batches require
matching per-event rows and aggregate counts, zero duplicates/suppressions, and
no `validation_only` result. **Every event in a normal admission case must carry
exactly one verdict, and that verdict is `accepted`**: observed-only, duplicate,
suppressed, unknown and missing verdicts fail the case. `observed` is not a
softer pass — it appears in none of the four aggregate counters, so admitting it
would let a run exit 0 while the counters an aggregate check reads say nothing
was accepted. The `duplicate` case is the one place a duplicate verdict is the
expectation. **All four aggregate counters must be present non-negative
integers** (`accepted`, `rejected`, `duplicates`, `suppressed`), and together
they must account for every verdict row and nothing else; `suppressed` must be
zero. A missing counter fails like a malformed one: a reader that indexes all
four raises on such a body, so defaulting one here would let the run exit 0 over
a log that cannot be read. Per-event `suppressed_no_consent` remains visible in
the evidence and fails the case after a verified grant. Unauthenticated must
return 401 or 403. The authenticated replay requires one `duplicate` with
`duplicate_event_id` and zero accepted/rejected/suppressed. Consent must report
`recorded: true`. Crashes require 202, the exact submitted crash ID, a
**fingerprint with non-whitespace content** and no suppression: an
acknowledgement without one leaves the report ungrouped, so a blank or absent
fingerprint fails the case. None of this proves symbolication, and a successful
ingest reply alone does not prove downstream storage.

The mixed outcome is also measured **as the calling game sees it**, which is the
row a transport-only witness cannot close. The sender installs the SDK's
documented `diagnostics` hook and reads `client:get_rejections()` after the
flush, so the rejected event ID and its `event_too_large` reason are recorded
from the SDK's own surfaces rather than inferred from the HTTP body the host
already holds; the accepted sibling must be acknowledged in the same reply. A
second flush then follows with nothing to publish, which is how the evidence
shows the rejected event was not re-queued: the rejected ID appears in exactly
one request body for the whole run, and every case has exactly one attempt.
Installing the hook replaces the SDK's default `print` warnings, so those
warnings no longer appear in a healthy run.

The admission probe is measured the same way. `flush` returns **false** for it —
that is what a refused batch must report, and a `true` would be the SDK claiming
delivery of a batch the door turned away — so the result is recorded in a
`probe-settlement` line together with `snapshot()`'s counters, and a `true`
fails the run.

**The two passing refusals settle differently inside the SDK, so the receipt
states which one happened rather than asserting one of them.** A `401` reaches
the client as unauthorized *and* retryable, and with a `token_provider`
configured the SDK **retains** that batch for a re-minted retry; a `403` falls
through as a terminal `http_403` — neither unauthorized nor retryable — so the
batch is **dropped** and nothing is owed. Measured on the loopback fixture:
`dropped` stays `0` for the 401 and becomes `1` for the 403, and both leave one
attempt and a failed batch. `probe_terminal` is true only when the SDK did not
claim delivery, the recorded status is one of those two, the printed settlement
matches that status, the SDK's own counters agree with it, the case had exactly
one attempt, and no other exchange carries the probe's event ID.

For the 401 settlement the retry itself is **not taken**: a further `flush`
re-attempts the batch, and `shutdown()` re-attempts it and then refuses
teardown, so no public surface drops it. A witness that allows one attempt per
case therefore reports the owed retry — it is on the printed not-exercised list
— and the run ends there; `spool_enabled` is false, so nothing durable survives
the process and the obligation cannot reach a later run.

Every counted case is judged against the cardinality this run **planned**, not
one derived from the batch it happens to have sent: `single` exactly one
accepted event, `realistic-batch` exactly four accepted forming exactly two
start/end pairs with distinct session ids, `mixed-size` exactly one accepted
beside one `event_too_large` rejection, and the run exactly four sessions. A
batch that lost an event would otherwise be measured against its own smaller
self and pass; the receipt reports `plan_ok`.

| Crash case | What runs |
| --- | --- |
| Lua nonfatal | SDK `emit`, with sampling set to send every report |
| Lua fatal | SDK `emit_fatal`, pre-symbolicated Lua frame |
| Native frame | SDK `emit_fatal`, synthetic SIGSEGV address plus module/debug identity, `load_address` and `size` |
| Frameless raw text | SDK `emit_fatal` with `raw_text` and no frames — the wire shape a script-error traceback ships in |
| Previous-session engine dump / script-error hook | SDK supports these, but this sender does not crash an engine, load a real dump or exercise `sys.set_error_handler` |
| ANR/hang watchdog, minidump upload, Android tombstone upload, UE crash-context upload | No dedicated producer in this pure-Lua SDK; not emulated or claimed |

The deliberate oversize rejection is a **passing** rejection — it is the
measurement the `mixed-size` case exists to take — so a complete demonstration
exits **0** with `contract_match: true`, `rejected_events: 1`, `exit_code: 0`,
`caller_view_ok: true`, `probe_terminal: true`, `sessions_ok: true`,
`sessions: 4`, `plan_ok: true` and the probe's settlement. A rejection in any other case fails that case's
contract and exits **1**. Unexpected responses, a missing case, a second attempt
at one, transport/SDK failures or incomplete caller-visible evidence also exit
**1**, with a false contract match or a `sender_error`. Exit **2** means
invalid/missing environment configuration. The exit code is therefore usable
directly as a receipt; earlier revisions of this example exited 1 on a fully
successful run, and a runner that still expects that will misread a good run.

An unavailable Python/Lupa installation fails before the sender starts. Each run
creates fresh event/crash IDs under the configured synthetic identity and sends
real mutations when given live endpoints.
Only an authorized operator runs it against production. The live ingest/crash
contract observations supplied by the coordinator on 2026-09-11 are inputs to
these fixtures, not production results reproduced by this example's author.

Local verification (synthetic loopback only, no production credentials):

```sh
.venv-evidence-sender/bin/python examples/evidence-sender/test_sender.py
```

The fixtures exercise the real Lua SDK and Python HTTP transport. They do not run
the ingest services or a database and do not certify their behavior.
