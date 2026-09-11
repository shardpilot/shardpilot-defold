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

Do not paste credentials into commands, files, reports or shell history. The
sender reads them from its process environment. Both URLs require HTTPS except
on loopback; redirects and ambient HTTP proxies are disabled. No endpoint is
built in. Configure **both** planes first: missing configuration exits before HTTP.

Exact run command, without a pipe:

```sh
.venv-evidence-sender/bin/python examples/evidence-sender/send.py
```

The sequence is: grant analytics consent for the new synthetic anonymous actor;
send one `app.screen_view`; send a four-event session/screen/level-start/level-complete
batch; send a small screen-view beside one with 2,500 padding characters; send
three crash reports; replay the minimal SDK body with Authorization removed.
That last probe uses the captured SDK bytes directly because SDK initialization
requires a credential. Compression is disabled so the printed byte counts describe
the sent event elements. No automatic polling, retry loop or shutdown event is added.

Each request prints its URL, method, complete synthetic body and element sizes;
each response prints HTTP status, body, request ID (`MISSING` when absent), latency
and the measured outcome. Authorization values are never printed; configured keys
are scrubbed from echoed response/error text. Output is newline-delimited JSON.

The size check expects **202 with one accepted/observed small event and one
`event_too_large` rejection**, matched by event ID. It requires per-element size
enforcement at **2,048 bytes** in the target; a different policy is a failed
measurement to explain, not an automatic flag change. Other batches require
matching per-event rows and aggregate counts, zero duplicates/suppressions, and
no `validation_only` result. `observed` is admitted under the tracking-plan
observation posture and remains visible in the evidence. Unauthenticated must
return 401 or 403. Consent must report `recorded: true`. Crashes require 202,
a returned crash ID and no suppression; warnings remain printed, and do not prove
symbolication. A successful ingest reply alone does not prove downstream storage.

| Crash case | What runs |
| --- | --- |
| Lua nonfatal | SDK `emit`, with sampling set to send every report |
| Lua fatal | SDK `emit_fatal`, pre-symbolicated Lua frame |
| Native frame | SDK `emit_fatal`, synthetic SIGSEGV address plus module/debug identity |
| Previous-session engine dump / script-error hook | SDK supports these, but this sender does not crash an engine, load a real dump or exercise `sys.set_error_handler` |
| ANR/hang watchdog, minidump upload, Android tombstone upload, UE crash-context upload | No dedicated producer in this pure-Lua SDK; not emulated or claimed |

Exit **0** means all eight expected HTTP measurements matched; **1** means an
unexpected response, transport/SDK failure, incomplete evidence or missing request;
**2** means missing/invalid environment configuration. An unavailable Python/Lupa
installation fails before the sender starts. Read every result, not only the exit
code. Each run creates fresh synthetic IDs and sends real mutations when given
live endpoints. Only an authorized operator runs it against production.

Local verification (synthetic loopback only, no production credentials):

```sh
.venv-evidence-sender/bin/python examples/evidence-sender/test_sender.py
```

The fixtures exercise the real Lua SDK and Python HTTP transport. They do not run
the ingest services or a database and do not certify their behavior.
