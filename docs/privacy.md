# Privacy And Tokens

ShardPilot Defold SDK v0 keeps tokens and queues in memory only. Client tokens
are memory-only.

Durable storage is limited to a single identity record per configured app —
the generated UUIDv7 anonymous ID and the analytics consent decision —
written through
`sys.get_save_file("shardpilot.<workspace_id>.<app_id>", "identity")`
(segments sanitized) with `sys.save`/`sys.load`. The per-app namespace keeps
two games on the same device from sharing an anonymous ID or consent record.
When the Defold `sys` API is unavailable, the record degrades to in-memory
state for the process lifetime.

`set_consent(analytics_granted)` records a tri-state consent decision
{unknown, granted, denied}. Unknown leaves tracking fully open. Denied drops
events at enqueue, clears the pending queue, and discards in-flight batches
on completion instead of retrying them. Explicit decisions are reported
fire-and-forget to `POST {ingest_url}/v1/consent` and never ride the event
envelope; a decision made before an auth token is available — or rejected as
unauthorized — is retained (latest decision wins) and retried at the next
dispatch point, and `shutdown` will not tear the client down while a decision
is still waiting on a token.

- No durable local event queue.
- Durable storage is limited to two small records, both written through Defold
  `sys.save`: the identity record described above, and a bounded crash-retry
  sidecar (see below). No cookies and no other browser or tracking storage.
- Identity/consent persistence goes through Defold `sys.save` only; on HTML5
  builds Defold backs `sys.save` with browser storage, still limited to those
  two records.

## Crash-retry sidecar

If a previous-session crash report cannot be sent on the next launch because the
network is temporarily unavailable (offline, rate-limited, or a server error),
the prepared report is written to a small, per-app sidecar so it can be resent on
a later launch. This sidecar:

- stores only an **already PII-scrubbed** crash report (the same scrub applied
  before any report leaves the device);
- is **bounded** (a small fixed number of entries, each size-capped) so a
  persistently failing send can never grow the file without limit;
- is **per-app** (namespaced like the identity record) so two games on one
  device never share a queue;
- is **TTL-bounded**: a pending report older than about seven days is discarded
  on read rather than resent;
- is **local to the device** and goes through Defold `sys.save` only (browser
  storage on HTML5); and
- is **cleared on success** — an entry is removed as soon as its report is
  accepted or terminally rejected, so it never accumulates.
- No token logging.
- No full event payload logging.
- No anonymous stitching by default.
- No pre-auth publishing by default.
- No provider, model, GitHub, billing, or account-management write calls.
- No automatic actions.

Do not send raw customer/player payloads, raw provider payloads, tokens,
secrets, diffs, patches, code/file/archive content, prompts, completions, or
unsanitized stack/backtrace payloads.

Use HTTPS for non-local production-like URLs. Public production readiness is not
claimed by this source SDK wave.
