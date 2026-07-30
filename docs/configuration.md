# Configuration

ShardPilot Defold SDK v0 is configured with a Lua table:

```lua
{
  ingest_url = "https://ingest.shardpilot.com",
  -- Optional: enables remote config (a SEPARATE service from the ingest
  -- endpoint; requires api_key — see "Remote config" below).
  -- remote_config_url = "https://config.shardpilot.com",
  -- Optional: enables experiments (default false = off). Requires BOTH
  -- remote_config_url and api_key — see "Experiments" below.
  -- experiments_enabled = true,
  workspace_id = "workspace",
  app_id = "app",
  environment_id = "production",
  app_version = "1.0.0",
  app_build = "100",
  source = "client",
  -- Auth: configure EXACTLY ONE of token_provider (Mode B) or
  -- api_key (Mode A). See "Authentication modes" below.
  token_provider = function(callback)
    callback("client-token-placeholder", expires_at_unix_ms, nil)
  end,
  -- Mode A alternative (publishable key, no token_provider):
  -- api_key = "sp_ingest_...",
  batch_size = 25,
  buffer_size = 1000,
  flush_interval_seconds = 1,
  publish_timeout_seconds = 2,
  -- Offline event spool (durable, per app). See "Offline event spool" below.
  spool_enabled = true,
  spool_max_events = 500,
  spool_max_bytes = 262144,
  -- Schema-revision declaration on batch ingest (default: the SDK's
  -- built-in revision). A string overrides the declared value; false (or
  -- "") stops declaring. See "Schema-revision declaration" below.
  -- schema_revision = false,
  diagnostics = function(issue)
    -- issue = { scope, event_id?, status, code?, message?, detail_codes? }
  end,
}
```

`ingest.shardpilot.com` is a planned public ingest domain and is not provisioned
by this wave. Use local/develop endpoints for source evaluation until a later
release explicitly publishes production infrastructure.

Required fields are `ingest_url`, `workspace_id`, `app_id`, `environment_id`,
and exactly one auth source (`token_provider` OR `api_key`). A UUIDv7 anonymous
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
ignored in favor of the stored or freshly generated identity (the same
fallback as any other invalid config identity value). The bound is a
persistence budget: identifiers are persisted verbatim in the durable identity
record and in every retained consent receipt (`actor_identifier` plus the
decision-time `anonymous_id` snapshot), and the clamp keeps those records far
under Defold's ~512 KB save-file record cap even at the consent outbox's
32-receipt worst case — while staying generous for legitimate identifiers
(UUIDs, emails, opaque backend tokens). Records persisted before the bound
existed self-heal at load: an oversized stored anonymous ID is replaced by a
fresh one, and outbox receipts carrying oversized identifiers are dropped by
the load-time sanitizer like any other malformed entry.

## Authentication modes

The ingest endpoint accepts two credential kinds, and the SDK supports both.
Configure **exactly one**:

- **Mode B — `token_provider`** (async per-tenant JWT). A function that yields a
  short-lived ingest JWT minted by your backend. The SDK manages refresh,
  expiry-lead, and 401-retry, and requires a token before publishing.

  ```lua
  token_provider = function(callback)
    callback("client-token-placeholder", expires_at_unix_ms, nil)
  end,
  ```

- **Mode A — `api_key`** (publishable key). The non-secret `sp_ingest_...`
  publishable key, used directly as the `Bearer` credential. It is safe to
  embed client-side, never expires, and needs no token round-trip.

  ```lua
  api_key = "sp_ingest_...",
  ```

Mode is selected by presence: a configured `token_provider` is used (Mode B);
otherwise the `api_key` is the standing Bearer (Mode A). Configuring **both**
is rejected (`auth_mode_conflict`); configuring **neither** is rejected
(`auth_required`). `anonymous_id` is sent on the wire in both modes. Mode B
JWTs are memory-only.

**Remote config is the exception to "exactly one".** The remote-config
endpoint authenticates with the publishable `api_key` only — a Mode B ingest
JWT is scoped to event ingest and the remote-config endpoint rejects it. With
`remote_config_url` set, an `api_key` is therefore required even in Mode B
(rejected with `remote_config_api_key_required` otherwise), and configuring
both credentials becomes valid: the `token_provider` keeps the ingest Bearer,
the `api_key` authenticates only the remote-config fetch.

## Remote config

- **`remote_config_url`** (default `nil` = disabled, string). The base URL of
  the remote-config endpoint, validated with the same shape rules as
  `ingest_url` (`https://…`, or `http://` for loopback hosts only; no
  path/query/fragment). This is a **separate service** from the ingest
  endpoint — pointing it at `ingest_url` is wrong. When set, the client
  exposes `fetch_remote_config(callback)` plus the typed getters
  (`remote_config_string/number/boolean/value/values/version`); fetching is
  always an explicit call (the SDK never fetches configuration on its own),
  responses are cached in one durable per-app record, and getters serve the
  last-known-good snapshot across restarts (the caller's default until any
  configuration is available). Full semantics — ETag revalidation, offline
  fallback, the `401`/`403` fail-closed rule, and the cache's scope check —
  are in the README's "Remote config" section.
- **`remote_config_attributes_enabled`** (default `false` = dark, boolean).
  ADR-0310 opt-in: fetches carry the targeting attributes stored via
  `set_remote_config_attributes(attributes)` as query parameters, so
  server-side delivery rules can target this client (`nil`/empty clears; the
  setter is inert while the flag is off, and the flag without
  `remote_config_url` is rejected with
  `remote_config_attributes_requires_remote_config_url`). The vocabulary and
  bounds are the experiment consumer's, verbatim: `geo`, `app_version`,
  `device_type`, `install_date`, `user_segment`, `custom_attribute_<name>`;
  ≤512-byte values, 64-attribute cap, sorted, out-of-vocabulary names
  dropped client-side. **Privacy contract**: attributes ride ONLY while
  consent is granted — unknown or denied consent (forced-minor included)
  keeps the fetch attribute-less and serves the untargeted defaults; see
  `docs/privacy.md`. Targeting is 100% server-evaluated.

## Experiments

- **`experiments_enabled`** (default `false` = off, boolean). Opts into the
  experiment-assignment consumer. While it is off — the default — **zero**
  experiment code paths execute: no subject id is minted, no assignment is
  fetched, no revalidation timer runs, no exposure is emitted, and no
  experiment record is written to disk; `fetch_experiment_assignment`,
  `track_exposure`, and `track_outcome` answer
  `false, "experiments_not_configured"` and `experiment_variant` /
  `experiment_payload` return `nil`. A non-boolean value is rejected with
  `invalid_experiments_enabled`.
- **The one disabled-mode exception is rollback safety.** If an *earlier* run
  of the same build had the flag on, turning it back off does not strand what
  that run left behind: `init()` still reads the small clear marker and
  filters any matching experiment facts out of the offline spool, so a
  rollback launch cannot replay withdrawn assignment data. The
  assignment-cache record written by that earlier run also stays on disk. A
  build that has never had the flag on has no such state and this path does
  nothing — but for a storage or privacy audit the rule is: the flag gates
  the *creation* of the experiment records, not their continued existence or
  the reading of the clear marker.

**Enabling it requires two more fields.** The assignment endpoint is served by
the same host as the remote-config fetch and authenticates with the same
publishable key, so `experiments_enabled = true` is only a valid configuration
alongside `remote_config_url` **and** `api_key`:

| Setting this… | …also requires | Otherwise `init()` returns |
|---|---|---|
| `experiments_enabled = true` | `remote_config_url` | `false, "experiments_requires_remote_config_url"` |
| `remote_config_url` | `api_key` | `false, "remote_config_api_key_required"` |

```lua
{
  ingest_url = "https://…",
  remote_config_url = "https://…", -- required by experiments_enabled
  api_key = "sp_ingest_…",         -- required by remote_config_url
  workspace_id = "workspace",
  app_id = "app",
  environment_id = "production",
  experiments_enabled = true,
}
```

In Mode B this is the same documented exception to "configure exactly one"
that remote config already uses: `token_provider` stays the ingest `Bearer`
and the `api_key` authenticates the remote-config and assignment fetches.
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
  reason?, error? }`. Never treat a synchronous `true` as a resolved
  assignment; branch on `result`. **One case produces no callback at all:** a
  request still in flight when `shutdown()` succeeds is cancelled and never
  calls back, by design — so do not park state that only a callback can
  release across a shutdown.
  Pre-dispatch failure codes: `not_initialized`, `shutdown`,
  `experiments_not_configured`, `experiment_key_required`, `consent_unknown`,
  `consent_denied`, `http_unavailable`, `json_unavailable`. Values that reach
  you as `result.error`: `unauthorized`, `not_found`, `bad_request`,
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
- **`track_exposure(experiment_key)`** — emits one extra exposure fact for the
  live assignment (the automatic at-most-once-per-session exposure needs no
  call). Returns `ok, err`; failure codes `not_initialized`, `shutdown`,
  `experiments_not_configured`, `experiment_key_required`, `no_assignment`,
  `consent_unknown`, `consent_denied`, `exposure_no_subject_fact_key`,
  `queue_full`.
- **`track_outcome(experiment_key, outcome_key, outcome_value)`** — records a
  host-defined outcome as its own fact. `outcome_key` must be a non-empty
  string (`invalid_outcome_key`) and `outcome_value` must be a **number**
  (`invalid_outcome_value`); the `track_exposure` failure codes apply too.

`queue_full` is the retryable one in that list: the in-memory event queue is
at `buffer_size`, so flush (or wait for the next batch to drain) and call
again — the exposure or outcome is otherwise silently lost.

**Automatic exposure is "at most once", not "exactly once".** A fact can only
be emitted when the assignment carries the server-supplied opaque key it is
allowed to be attributed by; the SDK-minted subject id must never reach the
analytics plane. An assignment served without one — a synthetic-unit answer,
for example — is applied normally but emits **no** exposure at all. Do not
assume every applied treatment is measured.

Watch the right name for it. The *automatic* skip surfaces **only** through
your `diagnostics` hook, as `status = "exposure_skipped"` with
`code = "no_subject_fact_key"`. The similar-looking
`exposure_no_subject_fact_key` is a different thing: the `err` returned from
an explicit `track_exposure` / `track_outcome` call. An integration watching
only the public-call error will not see the automatic gaps at all.

Treat `nil` from the getters as the control experience — that is what your
game sees before the first fetch resolves, when the subject is not assigned,
and in every fail-closed state below.

**Experiments must also be enabled server-side for your app.** Until they
are, the assignment endpoint answers `403` and this client treats it like any
other unauthorized answer — it **fails closed**: the fetch reports
`error = "unauthorized"`, **no variant is served** (not even a previously
cached one), the getters return `nil`, and in-memory serving plus the
revalidation cadence stop until you re-`init()` or a later fetch is
authorized. The durable cache record is kept, not destroyed — with one
exception: a `403` whose body reports that real-subject assignment was
switched off also drops the stored record, so a withdrawn assignment cannot
outlive the switch. Both flavors report the same `unauthorized`, so game code
has nothing extra to branch on. So shipping a build with the flag on is safe
on its own: with nothing enabled server-side your game runs the control path.

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
`custom_attribute_<name>` (suffix 1–64 characters). Values are trimmed and
bounded to 512 bytes, at most 64 attributes ride one fetch, and names outside
the vocabulary are dropped client-side and never sent. Matching is 100%
server-evaluated; the SDK evaluates no rules and never re-buckets locally.

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
unpersisted assignment keeps serving for the rest of the process, then is
simply refetched on the next launch — absence is always a refetch, never a
wrong serve. Do not rely on "cached once, offline forever" for a game that
holds many experiments at once.

**Serving a cached assignment through a failure is attribute-fenced.** On a
transient failure the cached variant is only returned when the failing fetch
asked with the same normalized targeting attributes the cached assignment was
evaluated under. Fetch the same experiment with a changed `geo` (or any other
changed attribute) and a transient failure returns `ok = false,
from_cache = false` instead — a variant chosen for one targeting context is
never handed back as the answer to another.

Full fetch semantics (the not-assigned reasons, `404`, and the
transient/`Retry-After` rules) are in the README's "Experiments" section.

## Schema-revision declaration

- **`schema_revision`** (default: the SDK's built-in revision; string or
  `false`). Every `POST {ingest_url}/v1/events:batch` request declares, in
  the `X-ShardPilot-Schema-Revision` request header, the revision of the
  analytics-service envelope-schema set this SDK build was provisioned
  against (`shardpilot/schema_revision.lua` — a public content digest of
  the service's embedded schema files, not a secret; it is re-synced when
  the service's schema set changes). The ingest service uses the
  declaration to detect writer builds whose schema set went stale; while
  the server-side handshake is off (its default), the header is ignored
  entirely, so declaring is inert until the service arms it. A non-empty
  string overrides the declared value (e.g. matched to a self-hosted
  service build); `false` or `""` disables declaring — an undeclared batch
  always passes the server's check, in every handshake mode. The header
  rides only the events-batch route (never the consent, crash, or
  remote-config requests) and only on batches that already passed the
  consent gate. If an armed service rejects a batch with a
  `schema_revision_mismatch` `409`, the batch is dropped as terminal —
  never retried or spooled, since a retry from the same build cannot
  succeed — and a log line names the declared and served revisions; the
  fix is updating the SDK (re-syncing the constant) or disabling the
  declaration. Feature-detect with
  `shardpilot.supports("schema_revision_declaration")`.

## Offline event spool

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
inside the window waits out the remainder before re-sending. Under Mode B
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
until acknowledged. `spool_enabled = false` does not affect it, and — unlike
the spool — it is never consent-purged: receipts deliver under denied and
unknown states alike, because a receipt documents the decision itself. See
`docs/privacy.md`.

- **`consent_kind_emission_enabled`** (default `true`, boolean;
  `invalid_consent_kind_emission_enabled` otherwise). Every `/v1/consent`
  body carries the receipt's actor class — `kind = "anon"` or
  `"user_verified"`, chosen by the canonical-actor rule described in
  `docs/privacy.md` — next to `actor_identifier`. `false` is the escape
  hatch for a deployment whose ingest service still runs the pre-amendment
  strict decoder (`INGEST_CONSENT_KIND_MODE=off` rejects a kind-bearing
  body `400` as an unknown field, a terminal outcome that would drop the
  receipt, denials included): it suppresses the **wire field only** — the
  kind is still chosen at decision time, persisted with the receipt, and
  used to select the dispatch credential (anon-keyed receipts under the
  publishable `api_key` where configured; `user_verified` receipts only
  under the minted Mode B token).

The optional `diagnostics` hook is invoked with each non-accepted ingest
outcome the server reports. Inside a `202` events-batch response the SDK parses
the per-event status array and reports every `observed`, `duplicate`,
`rejected`, or `suppressed_no_consent` event (with its server `code`); on a
non-2xx it reports the parsed error envelope (`error.code` plus per-field
detail codes); when a permanent reject drops entries from the offline
spool it reports `{ scope = "spool", status = "dropped", code, count }`; and
when a consent receipt is dropped (a permanent rejection, an overflow of
the outbox cap, or the Mode-B-only identity-change drop at load) it reports
`{ scope = "consent", status = "dropped", code }` (codes `outbox_overflow`
and `identity_changed` carry a `count`); and when a configured
`anonymous_id` override replaces a different persisted identity, the
fresh-identity reset is reported as
`{ scope = "consent", status = "dropped", code = "identity_override_changed" }`.
Counts are also available on `snapshot()` (`accepted`,
`rejected`, `duplicates`, `observed`, `suppressed`, `last_event_issue`, plus
the spool counters `spooled`, `spool_resent`, `spool_evicted`,
`spool_persist_failed` and the consent-outbox counters
`consent_outbox_evicted`, `consent_outbox_persist_failed`). The
SDK honors a `429` `Retry-After` header by deferring the next publish, and
falls back to exponential backoff with jitter when no header is present —
consent-receipt retries pace themselves the same way, on their own
consent-plane deferral.
