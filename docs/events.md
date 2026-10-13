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
- `props` (omitted from new envelopes when empty or absent)
- `context`

Do not use legacy public SDK fields: `project_id`, `game_id`, `env`,
`event_ts_server`, `event_seq_session`, or top-level `build_version`.

Built-in helpers enqueue (wire `event_name`, with the helper in parentheses
where it differs):

- `level_start`, `level_complete`, `level_fail` (from the typed progression
  verbs `track_level_start()`, `track_level_complete()`, `track_level_fail()`)
- `ad_impression_revenue` (from `track_ad_impression_revenue()`)
- `app.session_started` (from the `session_start()` helper)
- `app.session_ended` (from the `session_end()` helper)
- `app.screen_view` (from the `screen_view()` helper)
- `perf_summary`
- `network_summary`

Every name on this list is registered in the platform's schema registry, as
measured on 2026-08-29. Ingest refuses an event name with no registered schema
**per event**: inside the `202` it is `rejected` with `schema_not_found`, and
the events batched alongside it are stored. Only a batch in which every event is
unregistered is a whole-batch `400`. Either way the event produces no fact, so
this list being accurate is not documentation hygiene.

## Reserved names

Public `track()` refuses SDK-owned and runtime-only names with
`false, "reserved_event_name"`: `experiment_exposure`, `experiment_outcome`,
`governed_action_result`, `app_runtime_ping`, `monitor_evaluation_recorded`,
`llm_usage`, `support_assistant_feedback`, `ad_impression_revenue`,
`session_started` and `session_ended`.

Matching trims ASCII whitespace, removes exactly one leading `app.`, then
compares case-sensitively. Empty or ASCII-whitespace-only names return
`false, "event_name_required"`. Each name refusal increments `dropped` once,
sets `last_error`, and reaches neither the queue, spool nor transport. Shutdown
and consent refusals take precedence. Admitted names use the same ASCII trim
on the wire; Unicode whitespace is preserved.

Use `session_start()` / `session_end()`, `track_ad_impression_revenue()` and
the experiment methods for their owned events. These typed producers retain
their existing behavior. Ordinary names, including `app.screen_view`,
`level_start`, `level_complete`, `level_fail`, `perf_summary`, `network_summary`,
`purchase` and `economy_tx`, remain available to `track()`. Local admission does
not guarantee acceptance by the server schema.

## Event schema version

`track(name, props, context, options)` takes an optional fourth argument, an
options table. Its one key, `schema_version`, selects the version of the
event's contract:

```lua
shardpilot.track("level_complete", { level_id = "1-1" }, nil, { schema_version = 2 })
```

- Without options, or with `schema_version` absent, the event uses version `1`.
- A present value must be an integer from `1` through `65535`. It is sent as
  the event's top-level `schema_version`, a JSON integer.
- Anything else is refused with `false, "schema_version_invalid"`: a value of
  another type or outside that range, a fraction, a non-finite number, an
  options value that is not a table, or a key other than `schema_version`.
  Nothing is coerced or replaced with the default. The refusal counts one drop
  and sets `last_error`. It comes after the shutdown, consent and name checks,
  and before any session or queue effect.
- Only the table's own entries count. A value inherited through `__index` is
  not an option, and `__pairs` does not hide a key.
- The selected version is copied when `track()` accepts the event. It stays
  with that event through retries and the offline spool.
- Events in one batch may carry different versions.
- The typed producers (`screen_view`, the level and ad-revenue verbs, session
  events, summaries) keep version `1`, and sealed experiment facts keep version
  `2`. None of them takes the option.

The service decides whether the version exists for that event. An unregistered
or inactive version comes back as that event's own verdict
(`schema_version_rejected` or `schema_inactive`). The SDK does not retry with
another version. Detect the option with
`shardpilot.supports("event_schema_version")`.

## Event size

Each newly admitted analytics event must fit in **2,048 bytes** of complete,
uncompressed JSON; exactly 2,048 is allowed. Envelope fields, context, UTF-8
bytes, escaped characters and sealed-fact bytes all count. Only whitespace
outside the JSON element is excluded; interior whitespace still counts.

An oversized event returns `false, "event_too_large"` before queueing, records
one local refusal, and leaves valid queued neighbours available for delivery.
This also applies to typed/session events, summaries and sealed experiment
facts. Missing or failed JSON encoding returns `json_unavailable` or
`json_encode_failed` locally. Automatic session transitions wait until the
triggering event passes this precheck. Refusal accounting follows the producer's
retention rule: lifecycle obligations and failed durable-copy attempts remain
owed; experiment facts retain failures except terminal oversize; summaries retain
only queue pressure. A retained attempt is not counted as dropped, including
validation and encoding failures. Retirement counts the loss once.
Previously persisted envelopes are not rewritten.

## Session end reasons

**New in `v0.11.0`:** `session_end([reason])`, on a client or the module singleton,
preserves a non-empty string reason. An absent, empty or non-string reason uses
`session_end`. With no session open, the call emits nothing and opens nothing;
a second end is also a no-op. `shutdown()` uses `app_final`, including a retry
after queue pressure, and takes no reason. Both methods resolve
an already-expired background pause first, emitting one `idle_timeout` end at
its deadline and opening no replacement. End events require no duration prop,
and are suppressed unless analytics consent is granted.

## Removed: `tutorial_start`, `tutorial_step_complete`, `tutorial_complete`

These three helpers were removed in 2026-08-29. They emitted event names with no
schema in the registry, so their events already produced no fact anywhere, and
ingest now refuses each of them per event (a whole-batch `400` only for a batch
of nothing but unregistered events).

They were not renamed, because no registered equivalent exists, and no schema was
minted for them: game-specific names and tracking helpers belong in a game's own
adapter rather than in a universal telemetry SDK, and the other four ShardPilot
SDKs already work that way — Defold was the only one shipping typed game verbs.

**That reasoning does not cover the progression verbs added in 2026-09-02**, and
the sentence above should be read with this paragraph. `level_start`,
`level_complete` and `level_fail` are REGISTERED canonical schemas
(analytics.level_start.v1 / level_complete.v1 / level_fail.v1) with facts behind
them, which is exactly what the tutorial names lacked; and every ShardPilot SDK
now ships the same three typed verbs, so the parity argument now points the
other way. A verb is worth having when it builds a registered event and
validates the schema's own bounds before anything is queued — not when it wraps
a name the platform never heard of.

**Migration:** call `track()` directly with whatever name your analytics contract
registers — `client:track("your_event", { … })`. The removed helpers did nothing
but wrap that call.

`perf_summary` aggregates frame samples from `update(dt)` and uses
`avg_fps`, `p50_frame_time_ms`, `p95_frame_time_ms`, `max_frame_time_ms`,
`frames_sampled`, and `duration_ms`.

`network_summary` aggregates `observe_ping_ms(ms)` and
`observe_disconnect(reason)` using `avg_ping_ms`, `p50_ping_ms`,
`p95_ping_ms`, `max_ping_ms`, `ping_sample_count`, `disconnect_count`, and
`transport`.

Game-specific event names should be sent through the generic `track()` call
from your own integration code; they are not hardcoded SDK core behavior.

All of the above is **consent-first**: no event — helper-emitted or
`track()`-ed — is enqueued, spooled, or sent until an explicit
`set_consent(true)`. While the decision is still `unknown` the call returns
`false, "consent_unknown"` and the event is dropped, not held; after a denial
— `set_consent(false)` or the band-forced
`set_consent("denied_forced_minor")`, which every analytics gate treats
identically — it returns `false, "consent_denied"`. Runtime samples feeding
`perf_summary` and `network_summary` follow the same rule: `observe_ping_ms`
/ `observe_disconnect` / frame sampling are dropped at the source while the
pipeline is closed, and a denial resets the samplers — a summary emitted
after a grant carries granted-period activity only. Consent receipts are not
events: they post to their own `/v1/consent` endpoint from a durable outbox
(see `docs/privacy.md`) and are the one permitted wire transmission while
the pipeline is closed by an explicit decision.

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
report `spool_persist_failed` instead of claiming durability. A config
`anonymous_id` override that replaces a different persisted identity boots a
fresh identity — consent `unknown`, spool purged at init (see
[`docs/privacy.md`](privacy.md)). Within a restored grant, Mode B auth drops
spooled envelopes whose anonymous id no longer matches the client's at load
(diagnostics code `identity_changed`); Mode A
re-sends historic identities unchanged. See the README's "Offline
durability" section for the window-listener recipe and
[`docs/configuration.md`](configuration.md) for the knobs.
