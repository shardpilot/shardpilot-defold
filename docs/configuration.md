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
  token_provider = function(callback)
    callback("client-token-placeholder", expires_at_unix_ms, nil)
  end,
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
and `token_provider`. Client tokens are memory-only. The SDK requires a token
before publishing queued events. A UUIDv7 anonymous ID is generated and
persisted automatically (config `anonymous_id` or `set_anonymous_id` override
it); `identify(user_id)` upgrades attribution to a known user.

The optional `diagnostics` hook is invoked with each non-accepted ingest
outcome the server reports. Inside a `202` events-batch response the SDK parses
the per-event status array and reports every `observed`, `duplicate`,
`rejected`, or `suppressed_no_consent` event (with its server `code`); on a
non-2xx it reports the parsed error envelope (`error.code` plus per-field
detail codes). Counts are also available on `snapshot()` (`accepted`,
`rejected`, `duplicates`, `observed`, `suppressed`, `last_event_issue`). The
SDK honors a `429` `Retry-After` header by deferring the next publish, and
falls back to exponential backoff with jitter when no header is present.
