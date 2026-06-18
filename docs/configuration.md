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
  -- Auth (ADR-0222): configure EXACTLY ONE of token_provider (Mode B) or
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

The ingest endpoint accepts two credential kinds, and the SDK supports both
(ADR-0222). Configure **exactly one**:

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

The optional `diagnostics` hook is invoked with each non-accepted ingest
outcome the server reports. Inside a `202` events-batch response the SDK parses
the per-event status array and reports every `observed`, `duplicate`,
`rejected`, or `suppressed_no_consent` event (with its server `code`); on a
non-2xx it reports the parsed error envelope (`error.code` plus per-field
detail codes). Counts are also available on `snapshot()` (`accepted`,
`rejected`, `duplicates`, `observed`, `suppressed`, `last_event_issue`). The
SDK honors a `429` `Retry-After` header by deferring the next publish, and
falls back to exponential backoff with jitter when no header is present.
