# Changelog

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
