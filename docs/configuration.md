# Configuration

ShardPilot Defold SDK v0 is configured with a Lua table:

```lua
{
  ingest_url = "https://ingest.shardpilot.com",
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
  buffer_size = 200,
  flush_interval_seconds = 1,
  publish_timeout_seconds = 2,
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
by this wave. Use local/develop endpoints for source evaluation until a later
release explicitly publishes production infrastructure.

Required fields are `ingest_url`, `workspace_id`, `app_id`, `environment_id`,
and exactly one auth source (`token_provider` OR `api_key`). A UUIDv7 anonymous
ID is generated and persisted automatically (config `anonymous_id` or
`set_anonymous_id` override it); `identify(user_id)` upgrades attribution to a
known user. `get_anonymous_id()` returns the persisted anonymous ID so a host
can hand it to its own backend at token-mint time; the SDK always sends, on the
wire, the same anonymous ID it returns.

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

## Offline event spool

Three knobs control the durable offline event spool (full behavior in the
README's "Offline durability" section and [`docs/events.md`](events.md)):

- **`spool_enabled`** (default `true`, boolean). When enabled, event envelopes
  the client could not deliver — a transiently failed batch, the undelivered
  remnant at `shutdown()`, or an explicit `persist()` snapshot — are persisted
  per app and re-sent on a later launch. With `false`, delivery is memory-only
  and `shutdown()` keeps its retry-loop contract (`false, err` while
  undelivered events remain).
- **`spool_max_events`** (default `500`, integer ≥ 1). Hard cap on spooled
  entries; the OLDEST entries are evicted first once the cap is exceeded.
- **`spool_max_bytes`** (default `262144`, integer `1024`–`393216`).
  Approximate cap on the serialized size of the spool. The size estimate uses
  the JSON-encoded envelope length when the runtime provides an encoder,
  otherwise a conservative per-field sum, so treat it as a budget rather than
  an exact bound. The maximum is capped at 384 KB to keep headroom under the
  save-file API's documented 512 KB per-record limit. The OLDEST entries are
  evicted first over budget.

The spool honors consent: a persisted "denied" decision clears it at load
without sending, and `set_consent(false)` purges it at runtime. Spooled
envelopes are re-sent verbatim (stable `event_id`/`event_ts`), so the ingest
service de-duplicates re-sends.

The optional `diagnostics` hook is invoked with each non-accepted ingest
outcome the server reports. Inside a `202` events-batch response the SDK parses
the per-event status array and reports every `observed`, `duplicate`,
`rejected`, or `suppressed_no_consent` event (with its server `code`); on a
non-2xx it reports the parsed error envelope (`error.code` plus per-field
detail codes); and when a permanent reject drops entries from the offline
spool it reports `{ scope = "spool", status = "dropped", code, count }`.
Counts are also available on `snapshot()` (`accepted`,
`rejected`, `duplicates`, `observed`, `suppressed`, `last_event_issue`, plus
the spool counters `spooled`, `spool_resent`, `spool_evicted`,
`spool_persist_failed`). The
SDK honors a `429` `Retry-After` header by deferring the next publish, and
falls back to exponential backoff with jitter when no header is present.
