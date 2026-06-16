# Changelog

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

- Fix client-JWT ingest trust-tier conformance:
  - For `source = "client"`, `anonymous_id` is no longer sent on the wire. The
    authenticated client ingest tier rejects any non-empty `anonymous_id` with
    `400 anonymous_id_not_allowed` and drops the whole batch; the server derives
    the actor from the token subject instead. `set_anonymous_id` still records
    the identity in client state for the host's `token_provider`. Non-client
    sources are unchanged and keep sending `anonymous_id`.
  - `track()` now lazily opens a session (synthesizing `session_id`) for
    non-backend sources, so events tracked before `session_start()` carry the
    `session_id` the server requires instead of being whole-batch rejected.
