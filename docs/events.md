# Events

All events use app-first ShardPilot ingest fields:

- `event_id`
- `schema_version`
- `event_name`
- `source`
- `event_ts`
- `workspace_id`
- `app_id`
- `environment_id`
- `session_id`
- `session_sequence`
- `platform`
- `app_version`
- `app_build`
- `props`
- `context`

Do not use legacy public SDK fields: `project_id`, `game_id`, `env`,
`event_ts_server`, `event_seq_session`, or top-level `build_version`.

Built-in helpers enqueue (wire `event_name`, with the helper in parentheses
where it differs):

- `app.session_started` (from the `session_start()` helper)
- `session_end`
- `app.screen_view` (from the `screen_view()` helper)
- `tutorial_start`
- `tutorial_step_complete`
- `tutorial_complete`
- `perf_summary`
- `network_summary`

`perf_summary` aggregates frame samples from `update(dt)` and uses
`avg_fps`, `p50_frame_time_ms`, `p95_frame_time_ms`, `max_frame_time_ms`,
`frames_sampled`, and `duration_ms`.

`network_summary` aggregates `observe_ping_ms(ms)` and
`observe_disconnect(reason)` using `avg_ping_ms`, `p50_ping_ms`,
`p95_ping_ms`, `max_ping_ms`, `ping_sample_count`, `disconnect_count`, and
`transport`.

Project Tower-specific event names should be sent through generic `track()`
from the game integration later; they are not hardcoded SDK core behavior.

All of the above is **consent-first**: no event — helper-emitted or
`track()`-ed — is enqueued, spooled, or sent until an explicit
`set_consent(true)`. While the decision is still `unknown` the call returns
`false, "consent_unknown"` and the event is dropped, not held; after a denial
it returns `false, "consent_denied"`.

## Offline durability

Every event carries a stable `event_id` stamped at `track()` time. When a
batch cannot be delivered for a transient reason (network unreachable,
timeout, `429`, `5xx`), or undelivered events remain at `shutdown()`, or the
host calls `persist()`, the already-built envelopes are written to a durable
per-app spool and re-sent — verbatim, never re-stamped — on a later launch,
before fresh events. Because the `event_id` survives the round trip, the
ingest service de-duplicates a re-send that raced an original delivery, so a
spooled event is counted once even if both copies arrive.

Spooled entries are removed only after the server acknowledges their batch
(2xx), keyed by `event_id`; a permanent `4xx` also removes them (they would
fail forever) and surfaces through the `diagnostics` hook. A failed removal
rewrite keeps the entries marked settled and retries on the flush cadence
until storage recovers. Permanent rejects
are never spooled in the first place. The spool is bounded
(`spool_max_events` / `spool_max_bytes`, oldest evicted first — the caps are
re-applied to an old record at load), honors the
consent decision (a denial clears it; a failed purge leaves the spool
fail-closed and is retried), and is disabled with
`spool_enabled = false` (which also deletes a previously persisted record at
init). A `429` `Retry-After` received while a batch is spooled is stored with
the record: a relaunch inside the window waits out the remainder before
re-sending. Durable capture is strict: when the runtime has no save-file API,
or
the caps evicted part of the remnant being captured, `shutdown()`/`persist()`
report failure instead of claiming durability. Under Mode B auth, an
init-time `anonymous_id` override drops spooled envelopes carrying the
previous identity at load (diagnostics code `identity_changed`); Mode A
re-sends historic identities unchanged. See the README's "Offline
durability" section for the window-listener recipe and
[`docs/configuration.md`](configuration.md) for the knobs.
