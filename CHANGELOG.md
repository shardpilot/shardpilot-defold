# Changelog

## v0.3.0 — unreleased — early alpha

- Dual-mode ingest auth. The SDK now supports BOTH:
  - Mode B (existing): an async `token_provider` that yields a per-tenant
    ingest JWT (refresh, expiry-lead, 401-retry, in-flight race guard).
  - Mode A (new): a non-secret publishable `api_key` (the `sp_ingest_...`
    key, safe to embed client-side) used directly as the `Bearer` credential
    with no token round-trip. Configure `api_key` instead of `token_provider`.
  Mode is selected by presence: a configured `token_provider` takes effect
  (Mode B); otherwise the `api_key` is the standing Bearer (Mode A). Exactly
  one auth source is required — configuring both is rejected with
  `auth_mode_conflict`, configuring neither with `auth_required`.
- `anonymous_id` is ALWAYS sent on the wire for every source (client and
  service) in both auth modes; the server requires it.
- `track()` now lazily opens a session (synthesizing `session_id`) for
  non-backend sources, so events tracked before `session_start()` carry the
  `session_id` the server requires instead of being whole-batch rejected.
- Adds `get_anonymous_id()` (instance + singleton) so the host can read the
  persisted anonymous ID and hand it to its own backend at JWT-mint time. The
  SDK guarantees consistency — it sends, on the wire, the same anonymous ID it
  returns — but does not itself verify the backend's `bind_anon`.
- This is an early alpha pre-release. The API is unstable and may change before v1.

## v0.2.0 — unreleased — early alpha

- BREAKING: built-in helpers emit canonical wire event names. `session_start()`
  emits `app.session_started` and `screen_view(...)` emits `app.screen_view`.
  Helper API names are unchanged.
- Generates a UUIDv7 anonymous ID on first init and persists it through
  `sys.get_save_file("shardpilot.<workspace_id>.<app_id>", "identity")`
  (segments sanitized) with `sys.save`/`sys.load`, degrading gracefully to
  in-memory state when the Defold `sys` API is unavailable. The record is
  namespaced per configured app so two games on the same device never share
  an anonymous ID or consent decision.
- Adds `set_consent(analytics_granted)` with tri-state consent
  {unknown, granted, denied} persisted next to the anonymous ID. Denied drops
  events at enqueue, clears the pending queue, and discards in-flight batches
  on completion instead of retrying them. Explicit decisions are reported
  fire-and-forget to `POST {ingest_url}/v1/consent` over the same
  authenticated transport as the events batch; a decision made before an auth
  token is available is retained and sent at the next dispatch point.
- Parses the per-event status array in a `202` events-batch response
  (`{ accepted, rejected, duplicates, events:[{event_id, status, code, message}] }`)
  instead of assuming a `202` means full per-event success. Aggregate counters
  are kept on the snapshot and each non-accepted outcome
  (`observed`, `duplicate`, `rejected`, `suppressed_no_consent`) is surfaced
  through the new optional `diagnostics` config hook and `snapshot()`
  (`observed`, `suppressed`, `last_event_issue`), so integrators learn when
  their events are unregistered, blocked, or consent-suppressed. A `duplicate`
  is terminal and is never re-sent.
- Honors `429` backpressure: reads the `Retry-After` response header (whole
  seconds) and defers the next publish attempt by at least that long
  (clamped to a sane upper bound), retaining the batch. When the header is
  absent on a transient failure, falls back to exponential backoff with full
  jitter; a successful publish resets the backoff. A `401` still refreshes the
  token and retries immediately.
- Parses the `{ error: { code, message, details:[{field, code, message}] } }`
  envelope on a non-2xx response and surfaces `error.code` plus the detail
  codes via the `diagnostics` hook and `last_error`, instead of reporting only
  the bare HTTP status. No token material is included in the surfaced issue.
- This is an early alpha pre-release. The API is unstable and may change before v1.

## v0.1.1 — 2026-05-23 — early alpha

- Documentation re-cut. CHANGELOG and README cleaned up; library surface unchanged from v0.1.0.
- Defold dependency URL updated to recommend the v0.1.1 archive.
- This is an early alpha pre-release. The API is unstable and may change before v1.

## v0.1.0 — 2026-05-23 — early alpha

- Provides a pure Lua Defold library source SDK under `shardpilot/`.
- Includes Defold `game.project` library metadata with `shardpilot` as the include directory.
- Supports singleton and instance APIs for identity, sessions, screen views, custom events, updates, flush, and shutdown.
- Sends app-first batched event payloads to `{ingest_url}/v1/events:batch` without legacy public SDK fields.
- Keeps token and queue state in memory only, with Lua tests and static library checks.
- This is an early alpha pre-release. The API is unstable and may change before v1.

## Unreleased

- See v0.2.0 above.
