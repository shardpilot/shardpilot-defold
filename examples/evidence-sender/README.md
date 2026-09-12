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

The sequence is: grant analytics consent for the configured synthetic verified user;
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
observation posture and remains visible in the evidence; only rows with status
`accepted` count toward the accepted aggregate. The aggregate `suppressed`
member may be absent; when supplied it must be the integer zero. Per-event
`suppressed_no_consent` remains visible and does not match this demonstration's
expected outcomes after its verified grant. Unauthenticated must
return 401 or 403. The authenticated replay requires one `duplicate` with
`duplicate_event_id` and zero accepted/rejected/suppressed. Consent must report
`recorded: true`. Crashes require 202,
the exact submitted crash ID and no suppression; warnings remain printed, and do not prove
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
