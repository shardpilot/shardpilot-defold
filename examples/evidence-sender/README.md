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
| `SP_INGEST_KEY` | Publishable ingest key for the synthetic app |
| `SP_WORKSPACE_ID` | Canonical workspace key matching that key |
| `SP_APP_ID` | Canonical analytics app key |
| `SP_ENVIRONMENT_ID` | Analytics environment key |
| `SP_CRASH_URL` | Crash ingest base URL; this can differ from ingest and symbols-upload origins |
| `SP_CRASH_KEY` | Separate key with `crash:write` for the synthetic app |
| `SP_CRASH_APP_ID` | App identity expected by the crash key; verify its mapping explicitly |
| `SP_EVENT_NAME` | Optional registered tracking-plan name; defaults to `play_cta_click` |

Do not paste credentials into commands, files, reports or shell history. The
sender reads them from its process environment. Both URLs require HTTPS except
on loopback; redirects and ambient HTTP proxies are disabled. No endpoint is
built in. Configure **both** planes first: missing configuration exits before HTTP.

Exact run command, without a pipe:

```sh
.venv-evidence-sender/bin/python examples/evidence-sender/send.py
```

The sequence is: grant analytics consent for the new synthetic anonymous actor;
send one event through the SDK's `track` API; send a batch of four synthetic clicks;
send a small event beside one with 2,500 padding characters; send three crash
reports; replay the minimal SDK body with its original Authorization and event ID;
then replay it without Authorization. All events use `SP_EVENT_NAME` and source
`client`. The target must register that name and permit the synthetic properties.
An unregistered name can reject the whole batch with 400, unlike an oversize
element's rejection within 202. The two replays use captured SDK bytes directly;
they demonstrate the HTTP contracts, not the SDK's retry scheduler. Compression
is disabled so the byte counts describe sent elements. No automatic retry loop,
polling or shutdown event is added.

Each request prints its URL, method, complete synthetic body and element sizes;
each response prints HTTP status, body, request ID (`MISSING` when absent), latency
and `contract_match`, plus parsed counters and per-event status/code/message.
Authorization values are never printed; configured keys
are scrubbed from echoed response/error text. Output is newline-delimited JSON.

The size check expects **202 with one accepted/observed small event and one
`event_too_large` rejection**, matched by event ID. It requires per-element size
enforcement at **2,048 bytes** in the target; a different policy is a failed
measurement to explain, not an automatic flag change. Other batches require
matching per-event rows and aggregate counts, zero duplicates/suppressions, and
no `validation_only` result. `observed` is admitted under the tracking-plan
observation posture and remains visible in the evidence. Unauthenticated must
return 401 or 403. The authenticated replay requires one `duplicate` with
`duplicate_event_id` and zero accepted/rejected/suppressed. Consent must report
`recorded: true`. Crashes require 202,
a returned crash ID and no suppression; warnings remain printed, and do not prove
symbolication. A successful ingest reply alone does not prove downstream storage.

| Crash case | What runs |
| --- | --- |
| Lua nonfatal | SDK `emit`, with sampling set to send every report |
| Lua fatal | SDK `emit_fatal`, pre-symbolicated Lua frame |
| Native frame | SDK `emit_fatal`, synthetic SIGSEGV address plus module/debug identity, `load_address` and `size` |
| Previous-session engine dump / script-error hook | SDK supports these, but this sender does not crash an engine, load a real dump or exercise `sys.set_error_handler` |
| ANR/hang watchdog, minidump upload, Android tombstone upload, UE crash-context upload | No dedicated producer in this pure-Lua SDK; not emulated or claimed |

The full nine-request demonstration deliberately rejects one oversized event and
therefore exits **1**, even when every expected contract matches. Its final record
then has `contract_match: true`, `rejected_events: 1`, `exit_code: 1`. A 202 with
rejected events never produces a zero exit. Unexpected responses, transport/SDK
failures, incomplete evidence or missing requests also exit **1**, with a false
contract match or a `sender_error`. Exit **2** means invalid/missing environment
configuration. The runner permits exit **0** only with all contracts matching and
no rejected events; that is not the expected full-demo outcome. The test command
below exits zero when these positive and negative controls behave correctly.

An unavailable Python/Lupa installation fails before the sender starts. Each run
creates fresh synthetic IDs and sends real mutations when given live endpoints.
Only an authorized operator runs it against production. The live ingest/crash
contract observations supplied by the coordinator on 2026-09-11 are inputs to
these fixtures, not production results reproduced by this example's author.

Local verification (synthetic loopback only, no production credentials):

```sh
.venv-evidence-sender/bin/python examples/evidence-sender/test_sender.py
```

The fixtures exercise the real Lua SDK and Python HTTP transport. They do not run
the ingest services or a database and do not certify their behavior.
