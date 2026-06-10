# ShardPilot Defold SDK

ShardPilot Defold SDK is a pure Lua v0 public-preview source SDK for app-first
telemetry. The API is unstable and may change before v1. v0.1.1 is an early
alpha pre-release.

## Defold Library

`game.project` exposes only the SDK folder:

```ini
[library]
include_dirs = shardpilot
```

After the maintainer publishes the v0.1.1 tag and GitHub Release page, use this
recommended alpha Defold dependency URL:

```text
https://github.com/shardpilot/shardpilot-defold/archive/refs/tags/v0.1.1.zip
```

v0.1.1 is an early alpha pre-release; the API is unstable and may change before v1.
Use v0.1.1 over v0.1.0 for the clean documentation archive.

After the tag exists, add the URL under Defold dependencies and use
`Project -> Fetch Libraries`.

## Singleton API

```lua
local shardpilot = require "shardpilot.sdk"

shardpilot.init({
  ingest_url = "https://ingest.shardpilot.com",
  workspace_id = "workspace",
  app_id = "app",
  environment_id = "production",
  app_version = "game-version",
  app_build = "100",
  source = "client",
  token_provider = function(callback)
    callback("client-token-placeholder", expires_at_unix_ms, nil)
  end,
})

shardpilot.identify("user-123")
shardpilot.set_consent(true) -- analytics consent: granted
shardpilot.session_start() -- emits canonical "app.session_started"
shardpilot.screen_view("menu") -- emits canonical "app.screen_view"
shardpilot.track("play_cta_click", { cta_source = "main_menu" })
shardpilot.update(dt)
shardpilot.observe_ping_ms(42)
shardpilot.observe_disconnect("websocket_disconnected")
shardpilot.flush()
shardpilot.shutdown("app_final")
```

## Instance API

```lua
local sdk = require "shardpilot.sdk"
local client = sdk.new(config)

client:identify("user-123")
client:screen_view("menu")
client:update(dt)
client:flush()
client:shutdown("app_final")
```

## Identity And Consent

The SDK generates a UUIDv7 anonymous ID on first init and persists it through
`sys.get_save_file("shardpilot", "identity")` with `sys.save`/`sys.load`. When
the Defold `sys` API is unavailable (for example plain Lua test hosts), the
record degrades gracefully to in-memory state for the process lifetime.
`identify(user_id)` upgrades attribution to a known user.

`set_consent(analytics_granted)` records a tri-state analytics consent
decision: `unknown` (default, fully open), `granted`, or `denied`. Denied
drops events at enqueue and clears the pending queue. The decision is
persisted next to the anonymous ID and reported fire-and-forget to
`POST {ingest_url}/v1/consent` over the same authenticated transport as the
events batch; consent never rides the event envelope.

## Boundary

The SDK sends `POST {ingest_url}/v1/events:batch` with app-first fields:
`event_id`, `schema_version`, `event_name`, `source`, `event_ts`,
`workspace_id`, `app_id`, `environment_id`, `session_id`,
`session_sequence`, `platform`, `app_version`, `app_build`, `props`, and
optional `context`.

It does not expose or send legacy public SDK fields such as `project_id`,
`game_id`, `env`, `event_ts_server`, `event_seq_session`, or top-level
`build_version`.

Built-in helpers emit canonical wire names: `session_start()` emits
`app.session_started` and `screen_view(...)` emits `app.screen_view`. Helper
API names are unchanged.

Tokens and queues are memory-only in v0. Durable storage is limited to a
single identity record (anonymous ID + consent state) written through Defold
`sys.save`. The SDK does not include a native extension, call
providers/models/GitHub/billing, or execute automatic actions. Project Tower
can use generic `track()` calls later, but Project Tower event names are not
hardcoded into SDK core.

See `docs/` for configuration, events, privacy, and release notes.
