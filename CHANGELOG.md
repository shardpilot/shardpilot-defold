# Changelog

## v0.4.0 — unreleased — early alpha

- Adds **crash reporting** as a separate `require "shardpilot.crash"`
  module. Crash reports
  are sent — one per crash — to a **dedicated** crash ingest endpoint
  `POST {crash_ingest_url}/api/v1/crashes/ingest` with a `crash:write` API key as
  the `Bearer`, carrying the crash report JSON body. A crash is
  **never** wrapped as a `mobile_crash` analytics event on `/v1/events:batch`. The
  crash client has its own config (`crash_ingest_url`, `crash_api_key`, `app_id`,
  `crash_source`, `sample_every`, …), independent of the analytics client.
- Stamps the component-slug **`source`** on every crash report,
  configured via `crash_source` (mirroring how the analytics `source` is
  configured), defaulting to empty/bare-app, and validated as the slug
  `^[a-z0-9][a-z0-9-]{0,62}$` (≤63 chars) before the wire. A per-report `source`
  overrides the configured default.
- **Fatal crashes are never sampled.** `emit_fatal` (and the dump-forward path)
  bypass the sampler entirely; only non-fatal `emit` is subject to `sample_every`
  / a custom `sampler`.
- **PII scrubbing:** every caller-populated
  string is stripped of emails, `player_`/`user_`/`customer_`/`device_`
  raw-identifier prefixes (both a bare id like `user_4242` and one embedded in
  free-form text like `failed for user_4242`, while ordinary prose such as
  `user_id is null` is preserved), IPv4/IPv6 literals, and JWT-shaped dotted
  tokens. A
  frame `function` from the trusted native-dump path is scrubbed as a code symbol
  (a package-qualified name survives; an embedded email/IP still blanks it); a
  manual caller's frame `function` gets the full content scrub. The native crash
  **trace text** (`raw_text`) is scrubbed as code (it is full of scoped/dotted
  symbols like `Player::Update` and `java.lang.RuntimeException`), so a frame-less
  fatal reported only as a trace is not blanked over a code symbol and dropped — a
  real email/IP/token inside it is still removed. The app
  version/build are scrubbed with a version-aware rule so a dotted version such as
  `1.2.3.4` is kept rather than mistaken for an IP, and the operator-set `app_id`
  is treated as product scope (a slug like `user_app`/`customer_portal` is kept,
  not mistaken for a raw actor id). A
  `context.session_id` carrying disallowed identifier material rejects the whole
  report. Free-text fields also have the username segment of a user-home path
  (`/Users/<name>/`, `/home/<name>/`, `C:\Users\<name>\`) replaced with
  `<redacted>`, preserving the rest of the path. Crash state is held **in memory**,
  except a small bounded per-app sidecar that retains a previous-session dump
  report when its send fails for a temporary (retryable) reason, so it can be
  resent on a later launch; that entry is cleared on success or terminal rejection.
- **Auto-capture** of a previous-session **native** crash via Defold's built-in
  `crash` module: `crash.capture_previous()` reads `crash.load_previous()` on next
  launch and forwards a native crash event (`instruction_addr` frames + a module
  map, signal-derived exception type, OS sys-fields) as a fatal report. Because a
  native engine crash is unrecoverable in Lua, the model is
  **load-on-next-launch**; limits (no per-frame module attribution, no debug IDs,
  no breadcrumbs from the dead session, platform dependence) are documented in
  [`docs/crash.md`](docs/crash.md). Because the native dump is one-shot
  (consumed when it is read), a previous-session report whose send fails for a
  **temporary** reason (offline, rate-limited, or a server error) is persisted to a
  small per-app sidecar and resent on the next `capture_previous()` rather than
  being lost; the queue is bounded (count + size) and a terminal rejection is not
  retried. The sidecar uses the same guarded persistence as the identity record,
  so a host without durable storage falls back to in-memory for the process.
- Adds a manual emit API (`emit`, `emit_fatal`), a breadcrumb ring
  (`record_breadcrumb`, bounded to 50), a `diagnostics` hook + `snapshot()` for
  per-report outcomes, and both singleton and instance (`crash.new`) APIs.
- **Config is validated up front** at `crash.init` / `crash.new`: an `app_id` that
  carries PII/secret content, or a `platform` that is neither configured nor
  auto-detectable on the current runtime, fails initialization with a clear error
  (`invalid_app_id`, `platform_required`) instead of returning a client whose every
  later report would be dropped.
- This is an early alpha pre-release. The API is unstable and may change before v1.

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
