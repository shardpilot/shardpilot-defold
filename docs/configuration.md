# Configuration

ShardPilot Defold SDK v0 is configured with a Lua table. Unsupported keys,
including misspellings, return `unknown_config_key`: `new()` returns `nil, code`
and `init()` returns `false, code`. Validation happens before storage, token
callbacks or HTTP requests. Pass analytics options only to the analytics client;
crash has its own configuration. An already initialized analytics facade still
returns `already_initialized` before attempting replacement.

Constructors capture the table's raw entries once before validation or host
hooks. Metatable-provided fields are absent; use explicit table entries for
required options. Later changes to the caller's table do not change the captured
configuration. Function options retain their normal callback behavior.

The optional `transport` setting is a string label included in
`network_summary`, for example `"websocket"`. Omit it to omit that property.
Empty and custom strings are accepted; there is no fixed protocol list. It does
not select the SDK's HTTP transport. A non-string value returns
`invalid_transport` at construction.

```lua
{
  ingest_url = "https://ingest.shardpilot.com",
  -- Optional application origin (a SEPARATE service from the ingest
  -- endpoint; requires publishable_key — see "Remote config" below).
  -- app_url = "https://config.shardpilot.com",
  -- remote_config_enabled = true, -- explicit opt-in; default false
  -- Optional: enables experiments (default false = off). Requires BOTH
  -- app_url and publishable_key — see "Experiments" below.
  -- experiments_enabled = true,
  workspace_key = "workspace",
  app_key = "app",
  environment_key = "production",
  app_version = "1.0.0",
  app_build = "100",
  source = "client",
  -- Optional network-summary label (not the SDK HTTP implementation):
  -- transport = "websocket",
  -- Auth: configure EXACTLY ONE of token_provider (Mode B) or
  -- publishable_key (Mode A). See "Authentication modes" below.
  token_provider = function(callback)
    callback("client-token-placeholder", expires_at_unix_ms, nil)
  end,
  -- Mode A alternative (publishable key, no token_provider):
  -- publishable_key = "sp_ingest_...",
  batch_size = 25,
  buffer_size = 1000,
  -- flush_interval_seconds defaults to 15; at the historical tag v0.10.1 the
  -- default is 1, because that tag carries no source change. It is the longest a PARTIAL batch
  -- waits before publishing, not a heartbeat: update(dt) publishes nothing
  -- when the queue is empty. Set it explicitly only if you want a different
  -- cadence -- pinning it to 1 here is what stopped batching from happening.
  http_timeout_seconds = 2,
  -- Offline event spool (durable, per app). See "Offline event spool" below.
  spool_enabled = true,
  spool_max_events = 500,
  spool_max_bytes = 262144,
  diagnostics = function(issue)
    -- issue = { scope, event_id?, status, code?, message?, detail_codes? }
  end,
}
```

`ingest.shardpilot.com` is a planned public ingest domain and is not provisioned
in this release. Use non-production endpoints for source evaluation until a later
release explicitly publishes production infrastructure.

Canonical analytics scope configuration was introduced in `v0.13.0` and requires an
ingest consumer that accepts it. Source releases are published after owner tagging. Its values
retain the same private storage namespace; other transport formats retain their existing contracts. Do not use
database row IDs in place of public keys. The earlier configuration names are
refused even when mixed with canonical names.

Required fields are `ingest_url`, `workspace_key`, `app_key`, `environment_key`,
and exactly one auth source (`token_provider` OR `publishable_key`). A UUIDv7 anonymous
ID is generated and persisted automatically (config `anonymous_id` or
`set_anonymous_id` override it); `identify(user_id)` upgrades attribution to a
known user. A config `anonymous_id` that replaces a DIFFERENT persisted
identity boots a fresh one: the previous actor's persisted consent decision
is not carried over (consent starts `unknown`) and their offline spool is
purged at init — see `docs/privacy.md`. `get_anonymous_id()` returns the persisted anonymous ID so a host
can hand it to its own backend at token-mint time; the SDK always sends, on the
wire, the same anonymous ID it returns.

Identifiers (`user_id` and `anonymous_id`, however supplied) must be non-empty
strings of at most **512 bytes**. Oversized values are rejected exactly like
empty or non-string input — never truncated, since truncation could collide
distinct identities: `identify` returns `false, "invalid_user_id"` and
`set_anonymous_id` returns `false, "invalid_anonymous_id"`, each keeping the
previous identity, while an out-of-bounds config `anonymous_id`/`user_id` is
ignored in favor of the stored or freshly generated identity. The bound is a
persistence budget: identifiers are persisted verbatim in the durable identity
record and in every retained consent receipt (`actor_identifier` plus the
decision-time `anonymous_id` snapshot), and the clamp keeps those records far
under Defold's ~512 KB save-file record cap even at the consent outbox's
32-receipt worst case — while staying generous for legitimate identifiers
(UUIDs, emails, opaque backend tokens). The same bound is checked before
consent receipts are persisted.

Anonymous-ID setters and nonempty configured overrides also reject CR, LF, NUL,
other ASCII control bytes (including DEL), and leading or trailing spaces or
tabs with `invalid_anonymous_id`. An unsafe override refuses initialization
before identity storage is read or written; a refused setter keeps the prior
identity. A Remote Config fetch independently refuses an unsafe selected header
identity with the same error code.

### Malformed UTF-8 in new analytics

**New in `v0.11.0`:** new analytics event names, property/context keys and string
values (including nested tables and typed fields), and `app_version`/`app_build`
replace malformed UTF-8 with U+FFFD before encoding. One invalid byte consumes
one replacement character, matching the ingest JSON decoder: an overlong or
truncated encoding can therefore produce several replacements. Typed length
limits count code points of that repaired value. A malformed value within its
limit remains an event, and does not prevent a normal neighbor from being sent.
The caller's tables and valid UTF-8 are unchanged; no Unicode normalization is
performed. Distinct malformed strings can become the same string. If property
keys collide after replacement, one value survives in Lua traversal order;
applications must supply valid UTF-8 when exact distinctions matter.

This rule excludes envelope identity: actor, session, event and
workspace/app/environment identifiers are never rewritten by UTF-8 repair, since changing identity could
change attribution or move consent. Their existing validation remains in force.
Spool replay preserves the event names written by the current client.

Previously persisted envelopes/consent are not migrated or repaired, and crash
and remote-config paths are outside this change. The rule therefore does not
guarantee UTF-8 validity for every SDK request or repair an old corrupted identity.

## Instance handles

`new(config)` returns a handle exposing the documented module operations with
colon-call syntax. Configuration, queues, tokens, module consumers and class
tables are private implementation state. `snapshot()` and other value reads
return their documented values; callers cannot change the client by editing a
snapshot. The handle accepts the same arguments as its module counterparts,
including `flush(timeout_seconds, callback)`, which takes no internal options.
This API boundary is not a Lua
sandbox against `debug` or direct loading of implementation files.

## Flush

`flush(timeout_seconds, callback)` delivers what the client holds at the
moment of the call: queued events, a batch on the wire or kept for a retry,
spool chunks from an earlier launch, and the summaries the call builds. It
sends batch after batch from `update()`, without waiting for
`flush_interval_seconds`, until all of it is settled or `timeout_seconds`
(default `10`) passes. Events tracked after the call are not part of it.
Summaries are identified by the exact IDs built by this call. A synchronous host
hook that creates another summary during dispatch cannot extend the drain or make
its rejection the call's result.

The deadline also bounds consecutive dispatches on a synchronous HTTP bridge:
once it is reached, the dispatch step starts no further event batch. A request
already in progress can finish afterwards; unsent events remain queued or spooled.
Time spent acquiring a token counts toward the same deadline.

The callback runs once, on the main loop: inside the call when everything
settles at once, otherwise from `update()`. It receives `true`, or `false` and
a code:

| Answer | Meaning |
|---|---|
| `true` | Nothing from the call is still held. Events the SDK removed itself (a consent-denial purge, retry-age expiry) and per-event rejections in a `202` count as settled; they show in `snapshot()` counters and diagnostics, not here. |
| `false, "pending"` | The timeout passed. The remnant stays queued and, with the durable spool on, is written to it for the next launch. |
| `false, "spool_persist_failed"` | The timeout passed and the durable spool could not store the remnant. |
| `false, "consent_receipt_pending"` | The timeout passed with the events held behind a consent grant receipt that has not been sent yet. |
| `false, "shutdown"` | The client was shut down before the call settled, or before the call. |
| `false, "not_initialized"` | The module-level `flush` has no client. |
| `false, "http_<status>"` or `false, "unauthorized"` | The server refused events of the call terminally. |
| `false, "invalid_timeout_seconds"` | `timeout_seconds` is not a finite number above zero. |

The call itself returns `true` when the drain starts, or `false` and the code
it also hands the callback when it refuses at once. A `callback` that is not a
function is refused with `false, "invalid_callback"`, and nothing is sent. A
drain that does not settle inside the call answers only from `update()`, so a
host that stops calling `update()` gets no answer.

## Shutdown

`shutdown(timeout_seconds, callback)` ends the client in three steps:

1. It ends an open session with `app_final`. A session paused past its
   background deadline ends with `idle_timeout` at that deadline instead, and
   with no open session nothing is sent.
2. It delivers what the client holds, the same way [`flush()`](#flush) does,
   within `timeout_seconds` (default `10`). What it holds is written to the
   durable spool as soon as the call starts, so a process that ends before
   the answer loses nothing.
3. It tears the client down once that settles, or at the deadline with
   whatever is left. The close advances from `update()`, so the client is
   torn down by its deadline only while the host keeps calling `update()`.

During the close, experiment cache writes and owed facts continue draining, while
assignment revalidation starts no further request. Each key rechecks this state if
a synchronous host hook begins shutdown during a revalidation tick. Mismatch
corrections and grammar retries are fenced too; closing never remints for a retry.

The callback runs once, on the main loop, with `true` or `false` and a code:

| Answer | Meaning |
|---|---|
| `true` | Everything the client held was delivered or removed locally, including cleanup of acknowledged spool copies. |
| `false, "pending"` | The deadline passed. The remnant is in the durable spool and is sent on the next launch. |
| `false, "spool_persist_failed"` | At the deadline, storage could not finish required persistence or cleanup: the remnant, a consent receipt or decision, experiment state, or acknowledged spool copies. A diagnostic with `scope = "shutdown"` names what remains owed. |
| `false, "http_<status>"` or `false, "unauthorized"` | The server refused events of the final flush terminally. |
| `false, "shutdown"` | The client was already shut down. |
| `false, "not_initialized"` | The module-level `shutdown` has no client. |
| `false, "invalid_timeout_seconds"` | The timeout is not a finite number above zero. Nothing is torn down. |

A second call on the same client, during the close or after it, gets the
first call's answer. The module releases its client when the close ends, so a
later module-level `shutdown` answers `not_initialized`.

A failed acknowledgement-removal rewrite keeps the close pending even after
delivery succeeds. Keep calling `update()` so storage is retried on every tick,
without waiting for the normal flush interval. Recovery before the deadline
allows success; otherwise the close answers `spool_persist_failed` and tears
down at the deadline. An acknowledged copy that could not be removed can still
be replayed on the next launch after that failure.

From the call on, the client admits nothing new: `track` and the other event
calls, `session_start`, `track_exposure`, `track_outcome`,
`apply_experiment_variant` and experiment fetches answer `false, "shutdown"`
(`apply_experiment_variant` answers `nil, "shutdown"`). It keeps draining what it holds through
`update()`, and the module holds it: `init()` answers `already_initialized`
until the callback has run.

A denial that neither the identity record nor its write-ahead marker could
store would let the next launch restore the earlier grant. At the deadline the
client therefore deletes the stored identity record first: a delete can succeed
where a write fails, and the next launch starts with consent unknown. When even
the delete fails, the answer is `spool_persist_failed` with a diagnostic, and
the next launch may still restore the earlier grant.

## One client per app

The SDK supports **one live client per app** in a process. An app is the
storage scope that `workspace_key` and `app_key` name. Every durable record is
kept per app: the identity and consent record, the offline event spool, the
consent-receipt outbox and, with `experiments_enabled`, the experiment
records. A client loads them when it is created and works from its own
in-memory copy afterwards.

A second `new(config)` for an owned app returns `nil, "storage_scope_in_use"`
before any storage read or write. `init(config)` returns `false` with the same
error when a `new` instance already owns that app. The reservation starts before
construction accesses persistence, so reentrant storage hooks cannot create
another owner. Changing `environment_key` still uses the same app storage scope.

- Create one client with `init(config)` (or `new(config)`) and keep it.
- To replace it, call `shutdown()` and wait for its callback, then create the
  next client. A closing client is still live until then. Teardown discards
  in-flight remote-config responses and cancels their callbacks without changing
  the cache or getters. No separate wait for those fetches is needed.
- Clients of different apps (another `app_key`, or another `workspace_key`) are
  independent and may run side by side. Create each with `new(config)` and
  keep every instance: `init(config)` holds one default client, and a second
  `init` returns `false, "already_initialized"` while that client remains live
  or is being constructed. A completed shutdown releases the default client;
  a later `init` can then create its replacement.
- A failed constructor releases its reservation. An unreachable client releases
  ownership when it is garbage collected; callbacks or other references that
  retain the client keep it live. Use completed shutdown for a predictable handoff.
- Raw workspace/app identifiers remain distinct in storage: `com.game` and
  `com_game`, or `Game` and `game`, have separate identity and consent records.
  All record categories share the same byte-encoded scope base; see
  [durable storage](privacy.md).

The decision to support one client per app, instead of coordinating several,
is recorded in [#145](https://github.com/shardpilot/shardpilot-defold/issues/145).

## Authentication modes

The ingest endpoint accepts two credential kinds, and the SDK supports both.
Configure **exactly one**:

- **Mode B — `token_provider`** (async per-tenant JWT). A function that yields a
  short-lived ingest JWT minted by your backend. The SDK manages refresh,
  expiry-lead, and 401-retry, and requires a token before publishing.
  After `shutdown()` completes, a pending token completion is discarded without
  changing tokens, diagnostics or publish scheduling. This also applies if the
  provider closes the client and then throws. A closing client is still live,
  so a completion that arrives before the close ends settles normally.

  ```lua
  token_provider = function(callback)
    callback("client-token-placeholder", expires_at_unix_ms, nil)
  end,
  ```

- **Mode A — `publishable_key`** (publishable key). The non-secret `sp_ingest_...`
  publishable key, used directly as the `Bearer` credential. It is safe to
  embed client-side, never expires, and needs no token round-trip.

  ```lua
  publishable_key = "sp_ingest_...",
  ```

Mode is selected by presence: a configured `token_provider` is used (Mode B);
otherwise the `publishable_key` is the standing Bearer (Mode A). Configuring **both**
is rejected (`auth_mode_conflict`); configuring **neither** is rejected
(`auth_required`). `anonymous_id` is sent on the wire in both modes. Mode B
JWTs are memory-only.

**Remote config is the exception to "exactly one".** The remote-config
endpoint authenticates with the publishable `publishable_key` only — a Mode B ingest
JWT is scoped to event ingest and the remote-config endpoint rejects it. With
`app_url` set, a `publishable_key` is therefore required even in Mode B
(rejected with `remote_config_publishable_key_required` otherwise), and configuring
both credentials becomes valid: the `token_provider` keeps the ingest Bearer,
the `publishable_key` authenticates only the remote-config fetch.

## Remote config

- **`app_url`** (default `nil`, string). The base URL of
  the remote-config endpoint, validated with the same shape rules as
  `ingest_url` (`https://…`, or `http://` for loopback hosts only; no
  path/query/fragment). This is a **separate service** from the ingest
  endpoint — pointing it at `ingest_url` is wrong. With
  **`remote_config_enabled = true`** (default `false`), the client enables `fetch_remote_config(callback)` plus the typed getters
  (`remote_config_string/number/boolean/value/values/version`); fetching is
  always an explicit call (the SDK never fetches configuration on its own),
  responses are cached in one durable per-app record, and getters serve the
  last-known-good snapshot across restarts (the caller's default until any
  configuration is available). Every state uses `/config/v1/{workspace_key}/{environment_key}`.
  Granted consent permits the anonymous ID in `X-ShardPilot-Anonymous-Id`;
  unknown and both denied states omit that header and targeting attributes.
  Their empty client cache scope
  prevents reuse of identified values or validators, including on restart.
  Full semantics — ETag revalidation, offline
  fallback, the `401`/`403` fail-closed rule, and the cache's scope check —
  are in the README's "Remote config" section.
- `experiments_enabled` and `remote_config_attributes_enabled` require the
  application origin independently of the remote-config switch.
- **`remote_config_attributes_enabled`** (default `false` = dark, boolean).
  This flag does not construct the consumer; set `remote_config_enabled = true`
  to enable fetches. Experiments remain independent of that switch.
  Opt-in: fetches carry the targeting attributes stored via
  `set_remote_config_attributes(attributes)` as query parameters, so
  server-side delivery rules can target this client (`nil`/empty clears; the
  setter is inert while the flag or remote-config consumer is off, and the flag without
  `app_url` is rejected with
  `remote_config_attributes_requires_app_url`). The vocabulary and
  bounds are the experiment consumer's, verbatim: `geo`, `app_version`,
  `device_type`, `install_date`, `user_segment`, `custom_attribute_<name>`;
  ≤512-byte values, 64-attribute cap, sorted, out-of-vocabulary names
  dropped client-side. **Privacy contract**: attributes ride ONLY while
  consent is granted — unknown or denied consent (forced-minor included)
  keeps the fetch free of identity and attributes; see
  `docs/privacy.md`. Targeting is 100% server-evaluated.

## Experiments

- **`experiments_enabled`** (default `false` = off, boolean). Opts into the
  experiment-assignment consumer. While it is off — the default — **zero**
  experiment code paths execute: no subject id is minted, no assignment is
  fetched, no revalidation timer runs, no exposure is emitted, and no
  experiment record is written to disk; `fetch_experiment_assignment`,
  `track_exposure`, and `track_outcome` answer
  `false, "experiments_not_configured"` and `experiment_variant` /
  `experiment_payload` return `nil`. `apply_experiment_variant` returns
  `nil, "experiments_not_configured"`. A non-boolean value is rejected with
  `invalid_experiments_enabled`.
- **The one disabled-mode exception is rollback safety.** If an *earlier* run
  of the same build had the flag on, turning it back off does not strand what
  that run left behind: `init()` still reads the small clear marker and
  filters any matching experiment facts out of the offline spool, so a
  rollback launch cannot replay withdrawn assignment data. The
  assignment-cache record written by that earlier run also stays on disk.
  Pending non-adult declarations share that existing clear record: recovery
  treats a process death before the assignment callback as unconfirmed and
  filters the recorded subject-fact keys before replay. The witness uses the
  full assignment scope, preserves synthetic-unit assignments and other known
  scopes, and remains until its cache and facts are durably settled. A rollback
  may omit the assignment endpoint or credential; recovery compares every
  component still known instead of treating an omitted value as a different scope. Failed
  witness writes remain owed (`persist()` reports `experiments_pending`);
  storage failing through process death before the first successful write
  cannot supply a durable witness. No eleventh record is introduced. A
  build that has never had the flag on has no such state and this path does
  nothing — but for a storage or privacy audit the rule is: the flag gates
  the *creation* of the experiment records, not their continued existence or
  the reading of the clear marker.

**Enabling it requires two more fields.** The assignment endpoint is served by
the same host as the remote-config fetch and authenticates with the same
publishable key, so `experiments_enabled = true` is only a valid configuration
alongside `app_url` **and** `publishable_key`:

| Setting this… | …also requires | Otherwise `init()` returns |
|---|---|---|
| `experiments_enabled = true` | `app_url` | `false, "experiments_requires_app_url"` |
| `app_url` | `publishable_key` | `false, "remote_config_publishable_key_required"` |

```lua
{
  ingest_url = "https://…",
  app_url = "https://…", -- required by experiments_enabled
  publishable_key = "sp_ingest_…",         -- required by app_url
  workspace_key = "workspace",
  app_key = "app",
  environment_key = "production",
  experiments_enabled = true,
}
```

In Mode B this is the same documented exception to "configure exactly one"
that remote config already uses: `token_provider` stays the ingest `Bearer`
and the `publishable_key` authenticates remote-config, assignment and apply requests.
Feature-detect the surface before `init()` with
`shardpilot.supports("experiments_assignment")`.

The public calls, verified against `shardpilot/sdk.lua`:

- **`fetch_experiment_assignment(experiment_key, [attributes], callback)`** —
  fetches the server-evaluated assignment. `attributes` is optional:
  `(experiment_key, callback)` is accepted. **The synchronous return is
  dispatch status, not the answer.** `true` means only that the request was
  handed to the HTTP layer; `false, err` means the call was refused before
  dispatch. Either way the assignment — or the failure — arrives through
  `callback(result)`, where `result` is
  `{ ok, from_cache, assigned?, variant_key?, variant_payload?, version?,
  boundary?, reason?, error? }` — `boundary` being a copy of the server's
  boundary table, passed through on a `200` for host introspection (it
  carries e.g. `assignment_unit` and `production_rollout`; the SDK itself
  acts only on `assignment_unit`). Future reason strings become `unknown`
  and install not assigned. A future assignment-unit string also becomes
  `unknown` and installs not assigned, clearing the affected cache without
  creating an exposure; other boundary members remain available. Malformed
  types and scope mismatches are still validated. Every `200` reply requires
  `served_revision`, `served_kill_gate` and `served_at`; revision `0`, kill gate
  `false` and the server's zero-time string are valid. Incomplete replies are
  malformed. Cached assignments require these pins and a nonempty subject.
  A numeric clear marker without a scope is unreadable; recovery fails closed.
  Never treat a synchronous `true` as a resolved assignment; branch on `result`. **One case produces no callback at all:** a
  request still in flight when `shutdown()` succeeds is cancelled and never
  calls back, by design — so do not park state that only a callback can
  release across a shutdown.
  Pre-dispatch failure codes: `not_initialized`, `shutdown`,
  `experiments_not_configured`, `experiment_key_required`, `consent_unknown`,
  `consent_denied`, `http_unavailable`, `json_unavailable`. Values that reach
  you as `result.error`: `disabled`, `unauthorized`, `not_found`, `bad_request`,
  `malformed_response`, `stale_subject`, `superseded`, the consent trio
  below, and the transient family — `http_0` (no connection),
  `transient_408`, `transient_429`, `transient_<5xx>` — with `http_<status>`
  reserved for anything else the client cannot classify. Branch throttling
  and server-error retries on `transient_429` / `transient_<5xx>`, not on
  `http_<status>`.
- **Consent can close the plane mid-flight**, so `consent_unknown` and
  `consent_denied` are not only pre-dispatch refusals: a downgrade while the
  request is in flight resolves the callback with them, and a deny→re-grant
  that raced the response resolves it with `consent_changed`. All three mean
  no variant is served, and all three arrive as `result.error`. An
  integration classifying callback outcomes must handle them there, not only
  on the synchronous return.
- **`experiment_variant(experiment_key)`** — the cached variant key (a string)
  or `nil`. Never touches the network, never fails.
- **`experiment_payload(experiment_key)`** — a copy of the cached variant
  payload, or `nil`. Never touches the network, never fails.
- **`apply_experiment_variant(experiment_key)`** — returns the cached variant
  and records that your game acted on it. Call at the point of application.
  Fetches, getters, restores, session changes and consent re-grants record
  nothing. Deduplication is per experiment, version, subject and session.
  The call pins the served inputs and queues work; it performs no network I/O.
  Returns `variant, err` or `nil, err`. Corrupted in-memory serving pins or a
  missing fact key still return the variant, with `serving_pins_missing` or
  `exposure_no_subject_fact_key`; neither records a fact. Other failures are
  `not_initialized`, `shutdown`, `experiments_not_configured`,
  `experiment_key_required`, `no_assignment`, `consent_unknown`,
  `consent_denied`, or `queue_full` while opening a new session.
- **`track_exposure(experiment_key)`** — records an additional explicit
  application, with its own random occurrence ID. Returns `ok, err`, with the
  application failures above. It also becomes the last application for outcomes.
- **`track_outcome(experiment_key, outcome_key, outcome_value)`** — records an
  outcome against the last explicit application's pinned version, variant,
  attributes and serving times. Without that application it returns
  `false, "no_assignment"`. Keys are 1–128 ASCII letters, digits, `_`, `.`,
  `:` or `-`; values are integers with absolute value at most 2^53. Invalid
  inputs return `invalid_outcome_key` or `invalid_outcome_value`. Lifecycle,
  configuration and consent failures use the same codes as the other methods.

Use `type(shardpilot.apply_experiment_variant) == "function"` when supporting
older SDKs. The existing experiment capability does not promise this method.

**Success means queued locally.** `update()` seals an application via
`{app_url}/api/cp/v1/runtime/experiments/exposures` or `outcomes`,
then forwards the exact fact and seal to analytics as a v2 event with literal
`*_key` scope fields. Raw subject identity goes only to the configured remote-config host; anonymous
and session identity go only to analytics. `user_id` is omitted. Both stages
share an eight-record FIFO per experiment; overflow drops the oldest and reports
`fact_skipped` / `owed_overflow`. A full analytics queue retains a sealed record.
A fact member or `attestation` value this release does not know is forwarded
unchanged inside the signed bytes. A `server_attested` fact, a fact that carries
the raw subject, and a fact with a top-level member the SDK owns on the analytics
envelope are refused as malformed and retried.

Apply `401`/`403` responses hold the record until an authorized fetch; the
exact `403` `real_subjects_disabled` code withdraws the whole plane.
`403` `experiment_apply_disabled` keeps unsent facts and reports a `disabled`
diagnostic. Other `4xx` responses
are terminal except `408` and `429`. Exact `409` `not_assigned` with
`details:[{"field":"reason","code":"age_ineligible"}]` withdraws the subject's
facts for that experiment. `409` `version_mismatch`, `variant_mismatch`, and
`unit_not_recordable` drop the refused fact and refetch current targeting unless
a newer host fetch or assignment already supersedes the occurrence, including a
changed version, variant or assignment key installed before apply dispatch.
Offline, timeout, malformed responses,
redirects, `408`, `429` and `5xx` retry with backoff and `Retry-After`
(delta-seconds or an HTTP date). Redirects are never followed. Analytics per-event rejection stays
terminal and visible through the rejection ring.

Cap-retired keys join memory history even when durable history cannot fit.
Their durable history ends once no queued, in-flight, spooled or owed fact uses them.
Unchanged live history that exceeds the cap stays in memory without repeated writes.

Unsealed applications are memory-only. `persist()` starts no network request and
reports incomplete capture while they remain; sealed facts use the existing
spool. An offline process exit can therefore lose unsealed applications. Consent
denial purges both stages; re-grant needs a new explicit application. See the
[README delivery contract](../README.md#consent-targeting-and-facts) for the
pinned inputs and diagnostics.

Treat `nil` from the getters as the control experience — that is what your
game sees before the first fetch resolves, when the subject is not assigned,
and in every fail-closed state below.

**Experiments must also be enabled server-side for your app.** Until they
are, `403` with `error.code` `runtime_disabled`, `experiments_disabled`, or
`experiment_assignment_disabled` **fails closed** and reports `error = "disabled"`
plus a `disabled` diagnostic with that code. Other `401`/`403` answers report
`unauthorized`. No variant is served, the getters return `nil`, and revalidation
stops until re-`init()` or a later authorized explicit fetch. The durable cache
is retained except for exact `403` `real_subjects_disabled`, which also
withdraws every cached assignment and owed experiment fact.
Per-experiment ordering fences do not suppress plane-wide authorization or
withdrawal. Grammar retries retain their original host-call order; a pending
non-adult declaration preserves its exempt synthetic assignment against older
per-key refusals and age-gated assignments. A later adult call fences the
experiment's older fetches: an age refusal to a fetch sent before it withdraws
nothing and the adult call's own answer decides, while that answer's own
`age_ineligible` refusal still withdraws.

Assignment and apply actions use exact, case-sensitive `error.code`, never
human messages. Unknown codes, malformed/ambiguous envelopes, and older flat
error strings get the status-only policy. This build requires the structured
SDK error envelope from the server; there is no dual-read text fallback.
Exact `400` `subject_id_invalid` or `subject_pii_marker` remints the SDK's subject
once per process and retries the same targeting. Other `400` codes never remint;
`500` `definition_invalid` remains transient and serves matching stale state.

**Consent: granted-only.** Assignment fetches, cached serving, revalidation,
and the subject-id mint all require analytics consent `granted`. Under
`unknown` or either denial flavor (forced-minor included) the consumer
produces zero experiment traffic on both planes, refuses fetches with
`consent_unknown` / `consent_denied`, and the getters serve `nil`; the durable
record is retained but not served through a downgrade, and a later re-grant
serves it again. This is deliberately stricter than `fetch_remote_config`,
which is not consent-gated — see [`privacy.md`](privacy.md).

**Targeting attributes** use the fixed server vocabulary: `geo`,
`app_version`, `device_type`, `install_date`, `user_segment`, and
`custom_attribute_<name>`, where the suffix is **1–64 bytes** — measured in
bytes, not code points, so a multibyte suffix can pass a character count and
still be over the limit. An over-limit or out-of-vocabulary name is dropped
client-side and never sent, silently; keep custom attribute names ASCII.
Values are trimmed and bounded to 512 bytes and at most 64 attributes ride one
fetch. Matching is 100% server-evaluated; the SDK evaluates no rules and never
re-buckets locally.

**Caching and kill latency.** An assignment is cached in memory and in one
durable per-app record, so a later launch serves the last-known-good variant
offline. Cached assignments are re-fetched about every 300 seconds (±10%
jitter) while the SDK runs, consent is granted, and at least one assignment is
cached — this cadence is the SDK's share of the operator kill-switch reach.
Stated honestly: an offline client keeps its last-known-good variant
indefinitely.

**Durable caching is best effort.** The record has a fixed size cap and evicts
the oldest-fetched assignments to stay under it, and on a host with no working
save-file backend it degrades to process-local memory. An evicted or
unpersisted assignment keeps serving for the rest of the process, and its loss
is never a wrong serve — but **your code has to recover it.** The revalidation
cadence only refreshes experiments already in the cache and cannot rediscover
a missing key, so a launch that starts without the record stays on the control
path until you call `fetch_experiment_assignment` for that experiment. Fetch
the experiments you care about at startup instead of relying on "cached once,
offline forever".

**The subject id is best effort too, and stickiness follows it.** With no
working save-file backend, or on a failed durable write (diagnosed, not
fatal), the minted `spcid_` id stays memory-only — the next launch mints a new
one, and the server, which buckets on that id, may place the player in a
different variant. There is no host setter to pin it. Long-run stickiness is
only as good as the identity record's durability on your target platform.

**Variant payloads are copied with a depth limit of 16 nested tables.** The
same bounded copy runs on install and on every `experiment_payload` read, and
a subtree at or beyond that depth is dropped (`nil`) rather than rejected — a
payload nested 16+ deep arrives silently truncated. Keep variant payloads
shallow; they are configuration, not a document tree.

**`Retry-After` is a floor, capped at 24 hours.** It is read as
delta-seconds or an HTTP date. An unreadable value is ignored, and the client
falls back to its own jittered backoff.

**Serving a cached assignment through a failure is attribute-fenced.** On a
transient failure the cached variant is only returned when the failing fetch
asked with the same normalized targeting attributes the cached assignment was
evaluated under. Fetch the same experiment with a changed `geo` (or any other
changed attribute) and a transient failure returns `ok = false,
from_cache = false` instead — a variant chosen for one targeting context is
never handed back as the answer to another.

Full fetch semantics (the not-assigned reasons, `404`, and the
transient/`Retry-After` rules) are in the README's "Experiments" section.

## Platform

Leave `platform` unset or empty to use `sys.get_sys_info` detection, or set a
value explicitly. Analytics accepts the canonical values `windows`, `macos`,
`linux`, `android`, `ios`, `tvos`, `web`, `ps4`, `ps5`, `xbox`, `switch` and
`other`. Existing aliases such as `WIN32`, `OSX`, `html5`, `browser` and
`steamdeck` are folded, ignoring case and surrounding whitespace. Human-supplied
build suffixes are not inferred.
Both platform and experiment-transport probes request `{ ignore_secure = true }`
so engine-protected identifiers are omitted. The protected platform probe still
uses `other` when the API is absent, throws or returns malformed information.

A missing or unrecognized detected value uses `other` silently. A configured
unknown value also uses `other`, and retains the existing diagnostic:

```lua
{ scope = "config", status = "ignored", code = "platform_unmapped",
  platform = "Windows 11" }
```

Here `ignored` refers to the unrecognized input, which is replaced by the
fallback. A blank string means detection; whitespace-only input is reported
as unrecognized. Known configured values remain silent.

**Stored envelopes retain their platform at replay.** The current client chooses
the canonical value when building each envelope. Replay preserves that value,
`event_id` and `event_ts`. Source is `client` by default and country is omitted.

Crash reports and the consent-policy request use the same twelve values and
the same folding. See `docs/crash.md`. Pending crash retries replay the encoded
body with its original token, timestamp and fatal marker.

## Schema-revision declaration

The SDK does not send `X-ShardPilot-Schema-Revision`. Engine builds do not
redeploy with the server's schema set. There is no `schema_revision` setting or
exported default revision: constructors reject that key with
`unknown_config_key`, including `false` and an empty string.
`shardpilot.supports("schema_revision_declaration")` returns `false`.
This does not change the `schema_version` carried by each event envelope.

## Offline event spool

Delivery is bounded by seven days from local event intake and fifteen minutes
from the first potentially delivered HTTP attempt. Neither is configurable or
renewed by retry. Missing, invalid or future stored clocks expire conservatively;
older spool records without clocks are dropped. See [delivery age](../README.md#offline-durability-event-spool)
for HTTP outcomes, persistence failures and the one-live-client-per-app contract.

Three knobs control the durable offline event spool (full behavior in the
README's "Offline durability" section and [`docs/events.md`](events.md)):

- **`spool_enabled`** (default `true`, boolean). When enabled, event envelopes
  the client could not deliver — a transiently failed batch, the undelivered
  remnant at `shutdown()`, or an explicit `persist()` snapshot — are persisted
  per app and re-sent on a later launch. With `false`, delivery is memory-only
  and `shutdown()` keeps its retry-loop contract (`false, err` while
  undelivered events remain); disabling also **deletes any previously
  persisted spool record** at the next init, so nothing lingers on disk or
  would re-send after a later re-enable.
- **`spool_max_events`** (default `500`, integer ≥ 1). Hard cap on spooled
  entries; the OLDEST entries are evicted first once the cap is exceeded.
- **`spool_max_bytes`** (default `262144`, integer `1024`–`393216`).
  Approximate cap on the serialized size of the spool. The size estimate uses
  the JSON-encoded envelope length when the runtime provides an encoder,
  otherwise a conservative per-field sum, so treat it as a budget rather than
  an exact bound. The maximum is capped at 384 KB to keep headroom under the
  save-file API's documented 512 KB per-record limit. The OLDEST entries are
  evicted first over budget.

A failed clear of the spent experiment-withdrawal record is retried at dispatch,
`persist()` and `shutdown()` even while consent is denied or spooling is disabled.
A newer withdrawal keeps its debt until its own spool removal succeeds.

Both caps are re-applied to a previously persisted record at load: a
configuration that lowered the budgets trims an over-budget old record
(oldest first, counted in `spool_evicted`) before anything re-sends.

The spool honors consent — it is written, loaded, and re-sent only under a
**granted** decision (consent-first). Any init in a non-granted state
(denied, unknown, or an unreadable identity record) purges an existing
record instead of holding it: without an affirmative persisted grant NOW the
record cannot be proven to have been written under one (a pre-consent-first
install spooled while "unknown" was still open, and an unreadable identity
record may have carried a denial), so its envelopes must not re-send under a
later grant. A persisted "denied" decision clears it
at load
without sending (the purge runs even when the record cannot be read — a
corrupt record is still cleared), and `set_consent(false)` purges it at
runtime. If the durable
purge itself fails, `set_consent(false)` returns `false, "spool_purge_failed"`
and the spool goes fail-closed (nothing appended, loaded, or re-sent) while
the purge is retried automatically at later dispatch points and at the next
launch. Revocation cleanup completes before a new grant takes effect:
`set_consent(true)` retries an owed purge first and is NOT applied while it
keeps failing (same `false, "spool_purge_failed"` return; the persisted
decision stays denied), so a relaunch can never replay the pre-revocation
record under a granted decision. The same fail-closed family covers the
receipt outbox: on a denial-full outbox (32 retained receipts, no pure
grant available to evict) `set_consent(true)` is refused with
`false, "consent_outbox_full"` — the state does not flip and nothing
is evicted — until the outbox drains below the cap. Spooled
envelopes are re-sent verbatim (stable `event_id`/`event_ts`), so the ingest
service de-duplicates re-sends; when a `429` `Retry-After` arrives while a
batch is spooled, the deadline is stored with the record and a relaunch
inside the window waits out the remainder before re-sending. When experiment
withdrawal empties restored work, its deadline is cleared too. A failed
deadline-only rewrite retries at `flush()`, `persist()` and `shutdown()` even
without new events to append; deadlines for remaining work stay effective. Under Mode B
auth, spooled envelopes whose
`anonymous_id` no longer matches the client's (the stored anonymous id was
replaced at load — the corrupt/oversized-record self-heal) are dropped from
the record at load and
surfaced via `diagnostics` (`scope = "spool"`, code `identity_changed`) — the
minted token binds the current identity, so re-sending them would be rejected;
Mode A re-sends historic identities unchanged. A configured `anonymous_id`
override that replaces a DIFFERENT persisted identity never gets that far:
it boots a fresh identity in both modes — consent `unknown`, spool purged at
init, nothing of the previous actor's decision applied (diagnosed
`scope = "consent"`, code `identity_override_changed`; see
`docs/privacy.md`).

Durability is strict: on a runtime without the save-file API the spool falls
back to process memory (in-process retries keep working), but
`shutdown()`/`persist()` then report failure rather than claiming the events
are safe on disk — the same applies when the caps evict part of the remnant
being captured itself, and when a permanent rejection during the final flush
dropped the batch (nothing is left to spool, so `shutdown()` surfaces
`false, err`; a repeated call completes teardown since the queue is already
clean). A failed acknowledgment-removal rewrite keeps the
settled entries marked and retries the rewrite on the flush cadence, so the
record converges as soon as storage recovers.

The **consent-receipt outbox** is separate from the spool and has one
configuration knob (below): undelivered `POST /v1/consent` receipts are
always retained durably (fixed cap of 32, denial-preferring eviction —
oldest pure grant first, denials only among denials — no TTL) and retried
until acknowledged. The bound is enforced when receipts enter the outbox;
acknowledgment removals and owed-write retries preserve the retained list.
`spool_enabled = false` does not affect it, and — unlike
the spool — it is never consent-purged: receipts deliver under denied and
unknown states alike, because a receipt documents the decision itself. See
`docs/privacy.md`. Every persisted receipt requires its actor `kind` and
decision-time anonymous-ID snapshot. Missing metadata is malformed and keeps
the retained trail unaccounted; a normal retry cannot overwrite that evidence.

- **`consent_kind_emission_enabled`** (default `true`, boolean;
  `invalid_consent_kind_emission_enabled` otherwise). Every `/v1/consent`
  body carries the receipt's actor class — `kind = "anon"` or
  `"user_verified"`, chosen by the canonical-actor rule described in
  `docs/privacy.md` — next to `actor_identifier`. `false` is the escape
  hatch for a deployment whose ingest service still runs the pre-amendment
  strict decoder (which rejects a kind-bearing body `400` as an unknown field, a terminal outcome that would drop the
  receipt, denials included): it suppresses the **wire field only** — the
  kind is still chosen at decision time, persisted with the receipt, and
  used to select the dispatch credential (anon-keyed receipts under the
  publishable `publishable_key` where configured; `user_verified` receipts only
  under the minted Mode B token).

Per-event rejections are retained without opting into diagnostics. Set
`rejection_capacity` to a finite positive integer (default `64`); invalid values return
`invalid_rejection_capacity` from initialization. `client:get_rejections()` and
`shardpilot.get_rejections()` return oldest-first copies of `event_id`, `status`,
`code`, and `message`. Eviction never resets `snapshot().rejected`. With no
`diagnostics` hook, rejected entries produce bounded default `print` warnings;
a configured hook replaces that channel while retention remains mandatory.
The ring belongs to the client instance and clears on reinitialization; it is
neither persisted nor retried. These additions are new in
`v0.10.2`. See [Batch verdicts](../README.md#batch-verdicts) for the warning limits
and how [`flush()`](#flush) answers such a batch.

The optional `diagnostics` hook is invoked with each non-accepted ingest
outcome the server reports, and with construction issues such as a configured
`platform` it did not recognise, reported as
`{ scope = "config", status = "ignored", code = "platform_unmapped" }`
(see "Platform" and the delivery timing below). Inside a `202` events-batch response the SDK parses
the per-event status array and reports every `observed`, `duplicate`,
`rejected`, `suppressed_no_consent`, or `suppressed_ad_revenue_consent`
event (with its server `code`); on a
non-2xx it reports the parsed error envelope (`error.code` plus per-field
detail codes); when a permanent reject drops entries from the offline
spool it reports `{ scope = "spool", status = "dropped", code, count }`; when
restored spool envelopes carry a platform this SDK does not recognise it reports
`{ scope = "spool", status = "ignored", code = "platform_unmapped", count }`; and
when a consent receipt is dropped (a permanent rejection, an overflow of
the outbox cap, or the Mode-B-only identity-change drop at load) it reports
`{ scope = "consent", status = "dropped", code }` (codes `outbox_overflow`
and `identity_changed` carry a `count`); and when a configured
`anonymous_id` override replaces a different persisted identity, the
fresh-identity reset is reported as
`{ scope = "consent", status = "dropped", code = "identity_override_changed" }`.

**New in `v0.11.0` — boot delivery timing:** module-level `init()` finishes construction
and adopts the client before any of its diagnostic hooks run. The first module
`update(dt)` delivers those queued boot issues before pumping that client. Keep
calling `update(dt)` even if there are no analytics events to publish. Boot stats
and `last_event_issue` are updated during construction; delivering the hook later
does not overwrite a newer runtime diagnostic latch.

If a boot hook calls module `shutdown()` or `init()`, that action applies to the
adopted client. The remaining old boot issues are discarded and that update does
not pump either the old client or its replacement. A shutdown attempt stops the
drain even if teardown fails; the retained client can be updated or retried later.
Nested module `update(dt)` calls during boot delivery are ignored, so they neither
add frame time nor publish before the remaining boot issues are delivered.
A client shut down or replaced
before its first update never delivers its pending boot hooks; a failed re-init
preserves the existing client's pending delivery. Throwing hooks remain isolated.
A replacement installed by a shutdown response hook is preserved too.
Standalone `new()` has no singleton adoption step: its boot hooks still run before
it returns, after construction has settled. Runtime diagnostics remain synchronous,
including between module `init()` and its first `update()`.

Counts are also available on `snapshot()` (`accepted`, `dropped`, `last_error`,
`rejected`, `duplicates`, `observed`, `suppressed`, `last_event_issue`, plus
the spool counters `spooled`, `spool_resent`, `spool_evicted`, `spool_expired`,
`spool_persist_failed` and the consent-outbox counters
`consent_outbox_evicted`, `consent_outbox_persist_failed`). The
SDK retries a batch answered `408`, `429` or `5xx`. It honors a `429` or
`5xx` `Retry-After` header (delta-seconds or an HTTP date, capped at 24 hours)
by deferring the next publish, and falls back to exponential backoff with
jitter when no header is present —
consent-receipt retries pace themselves the same way, on their own
consent-plane deferral.

**New in `v0.11.0`:** `suppressed` counts both `suppressed_no_consent` and
`suppressed_ad_revenue_consent`, once per returned event, accumulating across
batches. The response's aggregate suppression count is not added again.
Suppressed entries remain terminal and are not retried; other counters and
the per-event diagnostics retain their existing behavior.

**New in `v0.11.0`:** `dropped` also counts each early validation refusal from
`track_level_start`, `track_level_complete`, `track_level_fail` and
`track_ad_impression_revenue`, on a client or initialized singleton. These
refusals set `last_error` to the same code returned to the caller; consent
diagnostics are derived independently from consent dispatch. Each call
adds one, even when several fields are invalid; validation order and error
codes are unchanged. Nothing is queued, sent or spooled by a refused call.
Successful calls add no drop, and a refusal delegated to the normal enqueue
path (consent, properties, queue capacity or shutdown) is still counted once.
`rejected` continues to describe server responses. A singleton with no client
returns `not_initialized` and has no client counter to update. This change
does not redefine experiment/session operations or other SDK refusal counters.
