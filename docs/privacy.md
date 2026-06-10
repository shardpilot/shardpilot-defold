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
envelope; a decision made before an auth token is available is retained and
sent at the next dispatch point.

- No durable local event queue.
- No file writes outside the single identity record.
- No browser storage or local storage equivalent.
- No token logging.
- No full event payload logging.
- No anonymous stitching by default.
- No pre-auth publishing by default.
- No provider, model, GitHub, billing, or control-plane write calls.
- No automatic actions.

Do not send raw customer/player payloads, raw provider payloads, tokens,
secrets, diffs, patches, code/file/archive content, prompts, completions, or
unsanitized stack/backtrace payloads.

Use HTTPS for non-local production-like URLs. Public production readiness is not
claimed by this source SDK wave.
