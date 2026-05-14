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
}
```

`ingest.shardpilot.com` is a planned public ingest domain and is not provisioned
by this wave. Use local/develop endpoints for source evaluation until a later
release explicitly publishes production infrastructure.

Required fields are `ingest_url`, `workspace_id`, `app_id`, `environment_id`,
and `token_provider`. Client tokens are memory-only. The SDK requires a token
and either `identify(user_id)` or `set_anonymous_id(anonymous_id)` before
publishing queued events.
