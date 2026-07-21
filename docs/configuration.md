# Configuration

ShardPilot Defold SDK v0 is configured with a Lua table:

```lua
{
  ingest_url = "https://ingest.shardpilot.com",
  -- Optional: enables remote config (a SEPARATE service from the ingest
  -- endpoint; requires api_key — see "Remote config" below).
  -- remote_config_url = "https://config.shardpilot.com",
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
known user. `get_anonymous_id()` returns the persisted anonymous ID so a host
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
record under a granted decision. Spooled
envelopes are re-sent verbatim (stable `event_id`/`event_ts`), so the ingest
service de-duplicates re-sends; when a `429` `Retry-After` arrives while a
batch is spooled, the deadline is stored with the record and a relaunch
inside the window waits out the remainder before re-sending. Under Mode B
auth, spooled envelopes whose
`anonymous_id` no longer matches the client's (an init-time `anonymous_id`
override changed the identity) are dropped from the record at load and
surfaced via `diagnostics` (`scope = "spool"`, code `identity_changed`) — the
minted token binds the current identity, so re-sending them would be rejected;
Mode A re-sends historic identities unchanged.

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
and `identity_changed` carry a `count`).
Counts are also available on `snapshot()` (`accepted`,
`rejected`, `duplicates`, `observed`, `suppressed`, `last_event_issue`, plus
the spool counters `spooled`, `spool_resent`, `spool_evicted`,
`spool_persist_failed` and the consent-outbox counters
`consent_outbox_evicted`, `consent_outbox_persist_failed`). The
SDK honors a `429` `Retry-After` header by deferring the next publish, and
falls back to exponential backoff with jitter when no header is present —
consent-receipt retries pace themselves the same way, on their own
consent-plane deferral.
