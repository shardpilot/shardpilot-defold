# shardpilot-defold

> Pure-Lua Defold source SDK for ShardPilot app-first telemetry — no native
> extension required. Buffers app-first analytics events in a Defold game and
> publishes them to the ShardPilot analytics ingest API.

See the platform guide [`../AGENTS.md`](../AGENTS.md) for ShardPilot's app-first
model. Wire shape and identity rules follow ADR-0139 (app-first analytics) and
ADR-0222 (dual-mode client ingest auth); games are a domain pack, not the
platform boundary (ADR-0106). ADRs live in
[`../docs/architecture/adr/`](../docs/architecture/adr/).

## Status

- **v0 alpha, pre-1.0, API unstable.** This is public-preview source only. The
  surface may change before v1 with no backward-compatibility guarantee.
- **Pre-launch.** No GitHub Release, tag, or package artifact is published from
  this repo, and the production ingest domain is **not provisioned** yet. Use
  local/develop endpoints for evaluation.
- **Version strings are inconsistent across files** (`shardpilot/version.lua`
  reports `0.2.0`, `game.project` declares `0.1.0`). The latest unreleased work
  is tracked as `v0.2.0` in [`CHANGELOG.md`](CHANGELOG.md); treat that as the
  intent until the strings are reconciled.

## What it does

- Provides a Defold library (`shardpilot/`) you consume as source — there is no
  C/C++/native extension.
- Buffers app-first events in a bounded in-memory queue and publishes them in
  batches over `http.request` (Defold) or an injectable transport.
- Emits canonical helpers: `session_start()` → `app.session_started`,
  `screen_view(name)` → `app.screen_view`, plus arbitrary `track(name, props)`.
- Generates and persists a UUIDv7 anonymous ID per configured app and supports
  `identify(user_id)` to upgrade attribution to a known user.
- Records a tri-state analytics consent decision (`unknown` / `granted` /
  `denied`) and enforces it at enqueue and dispatch time.
- Samples basic runtime signals via `update(dt)`, `observe_ping_ms(ms)`, and
  `observe_disconnect(reason)`.

## Installation

`game.project` exposes only the SDK folder as a Defold library:

```ini
[library]
include_dirs = shardpilot
```

Because no release ZIP or tag is published yet, the supported path today is to
vendor the `shardpilot/` directory into your project (or add this repo as a
Defold dependency from a local archive). A hosted dependency URL will be
documented once a release is published.

Then require the module:

```lua
local shardpilot = require "shardpilot.sdk"
```

## Quick start

Minimal Defold script (see [`examples/minimal/`](examples/minimal)):

```lua
local shardpilot = require "shardpilot.sdk"

function init(self)
  shardpilot.init({
    ingest_url = "http://localhost:8080",
    workspace_id = "workspace-example",
    app_id = "app-example",
    environment_id = "develop",
    -- Auth: configure exactly one of token_provider (Mode B) or api_key (Mode A).
    token_provider = function(callback)
      callback("client-token-placeholder", nil, nil)
    end,
    -- api_key = "sp_ingest_...", -- Mode A alternative (publishable key)
  })
  shardpilot.identify("user-example")
  shardpilot.set_consent(true)   -- analytics consent: granted
  shardpilot.session_start()     -- emits app.session_started
  shardpilot.screen_view("menu") -- emits app.screen_view
  shardpilot.track("play_cta_click", { cta_source = "main_menu" })
end

function update(self, dt)
  shardpilot.update(dt) -- drives flush timer + frame sampling
end

function final(self)
  shardpilot.shutdown("app_final")
end
```

For multiple independent clients, use the instance API instead of the
singleton:

```lua
local sdk = require "shardpilot.sdk"
local client = sdk.new(config)

client:identify("user-123")
client:track("play_cta_click", { cta_source = "main_menu" })
client:flush()
client:shutdown("app_final")
```

Most methods return `ok, err` so callers can branch on failures (e.g.
`not_initialized`, `consent_pending`).

## Configuration

`init(config)` / `new(config)` take a Lua table. Required: `ingest_url`,
`workspace_id`, `app_id`, `environment_id`, and **exactly one** of
`token_provider` (Mode B) or `api_key` (Mode A) — see [Authentication](#authentication).

| Field | Default | Notes |
|---|---|---|
| `ingest_url` | — (required) | `https://…`, or `http://` only for `localhost`/`127.0.0.1`/`::1`; no query/fragment/path |
| `workspace_id` | — (required) | Tenant key |
| `app_id` | — (required) | Product key |
| `environment_id` | — (required) | Environment scope (e.g. `local` / `develop` / `stage` / `prod`); any non-empty string is accepted |
| `token_provider` | — | **Mode B** (one of `token_provider`/`api_key` required): `function(callback)` → `callback(token, expires_at_unix_ms, err)` |
| `api_key` | — | **Mode A** (one of `token_provider`/`api_key` required): non-secret publishable `sp_ingest_…` key used directly as the `Bearer` |
| `source` | `"client"` | One of `client`, `server`, `backend` |
| `app_version` | `nil` | Sent in the envelope |
| `app_build` | `nil` | Sent in the envelope |
| `platform` | auto-detected | From `sys.get_sys_info`; falls back to `nil` outside Defold |
| `anonymous_id` | generated | UUIDv7 generated on first init if not provided |
| `user_id` | `nil` | Initial known-user attribution |
| `batch_size` | `25` | Flush trigger, 1–100 |
| `buffer_size` | `200` | Max queued events (≥1) |
| `flush_interval_seconds` | `1` | Time-based flush trigger (>0) |
| `publish_timeout_seconds` | `2` | Per-request timeout (>0) |
| `token_refresh_lead_ms` | `60000` | Refresh lead before token expiry (≥0) |

> `ingest.shardpilot.com` is a **planned** public domain and is not provisioned.
> Use local/develop endpoints until a release explicitly publishes production
> infrastructure. See [`docs/configuration.md`](docs/configuration.md).

## Authentication

The ingest endpoint accepts two credential kinds (ADR-0222); configure **exactly one**:

- **Mode B — `token_provider`**: an async function yielding a short-lived per-tenant
  ingest JWT minted by your backend. The SDK manages refresh, expiry-lead, and 401-retry.
- **Mode A — `api_key`**: the non-secret publishable `sp_ingest_…` key, used directly as
  the `Bearer`. Safe to embed client-side, never expires, no token round-trip.

Mode is selected by presence: a configured `token_provider` is used (Mode B); otherwise
`api_key` is the standing `Bearer` (Mode A). Configuring both is rejected
(`auth_mode_conflict`); configuring neither is rejected (`auth_required`). `anonymous_id`
is always sent on the wire in both modes.

## Wire contract

The SDK sends `POST {ingest_url}/v1/events:batch` with app-first fields:
`event_id`, `schema_version`, `event_name`, `source`, `event_ts`,
`workspace_id`, `app_id`, `environment_id`, `session_id`, `session_sequence`,
`platform`, `app_version`, `app_build`, `props`, and optional `context`.

Legacy public-SDK fields are **never** emitted: `project_id`, `game_id`, `env`,
`event_ts_server`, `event_seq_session`, and top-level `build_version` (CI-guarded
by [`scripts/check_library.sh`](scripts/check_library.sh)). See
[`docs/events.md`](docs/events.md).

## Privacy & consent

- **Memory-only by default.** Tokens and the event queue live only in memory;
  there is no durable local queue in v0.
- **Durable storage is a single identity record** (anonymous ID + consent
  decision) per configured app, written through
  `sys.get_save_file("shardpilot.<workspace_id>.<app_id>", "identity")` with
  `sys.save`/`sys.load`. The per-app namespace prevents two games on one device
  from sharing an anonymous ID or consent state. Outside Defold (e.g. a plain
  Lua test host) it degrades gracefully to in-memory state. `get_anonymous_id()`
  returns the persisted anonymous ID so a host can hand it to its own backend at
  token-mint time (Mode B); the SDK always sends that same anonymous ID on the wire.
- **`set_consent(analytics_granted)`** records `unknown` (default, fully open),
  `granted`, or `denied`. `denied` drops events at enqueue, clears the pending
  queue, and discards in-flight batches instead of retrying. Explicit decisions
  are reported fire-and-forget to `POST {ingest_url}/v1/consent` over the same
  authenticated transport; consent never rides the event envelope.
- The SDK does not log tokens or full payloads, and makes no
  provider/model/GitHub/billing/control-plane write calls. See
  [`docs/privacy.md`](docs/privacy.md) and [`SECURITY.md`](SECURITY.md).

## Project layout

| Path | Purpose |
|---|---|
| `shardpilot/sdk.lua` | Public entrypoint: singleton API + `new()` factory |
| `shardpilot/client.lua` | Client object: config validation, queue/flush lifecycle |
| `shardpilot/envelope.lua` | App-first event envelope construction |
| `shardpilot/queue.lua` | Bounded in-memory event queue |
| `shardpilot/transport.lua` | Batch/consent dispatch (`/v1/events:batch`, `/v1/consent`) |
| `shardpilot/storage.lua` | The **only** module allowed to call `sys.save`/`sys.load` |
| `shardpilot/clock.lua` · `id.lua` · `platform.lua` · `sampling.lua` | Time, UUIDv7, platform detect, runtime sampling |
| `shardpilot/version.lua` | Version string constant |
| `game.project` | Defold library metadata (`[library] include_dirs = shardpilot`) |
| `examples/minimal/` | Copy-pasteable usage example |
| `test/` | Lua test harness (`test_sdk.lua`) + Defold collection/script |
| `docs/` | configuration · events · privacy · release |
| `scripts/` | `check_library.sh` (content guard), `package_release.sh` |

## Conventions & boundaries

- **No native extension.** No `.c`/`.cpp`/`.mm`/`.java` or Extender references in
  SDK source (enforced by the guard).
- **No durable I/O beyond the identity record.** `io.*`, `os.execute`, and
  browser/local storage are forbidden in source; `sys.save`/`sys.load`/
  `sys.get_save_file` are confined to `shardpilot/storage.lua`.
- **No raw/provider/token/billing surface.** Terms like `raw_payload`, `prompt`,
  `access_token`, `github_token`, `billing` must not appear in SDK or example
  source.
- The README itself is **content-guarded** by `scripts/check_library.sh` (it
  requires the wire-contract line above). Run the guard after editing docs:
  ```bash
  ./scripts/check_library.sh
  lua5.4 test/test_sdk.lua
  ```

## Compatibility

- **Engine:** Defold (uses `sys`, `http.request`); degrades to in-memory state
  and an injectable transport when those APIs are absent.
- **Lua:** Lua 5.4 (CI installs `lua5.4` to run `test/test_sdk.lua`).
- **License:** Apache-2.0.

## Roadmap

Planned / deferred (not yet implemented):

- Provision the public ingest domain and publish a hosted Defold dependency URL.
- Reconcile the inconsistent version strings across `version.lua`,
  `game.project`, and the changelog.
- Publish a release (tag / GitHub Release / ZIP). `scripts/package_release.sh`
  only *prepares* a reviewable ZIP and explicitly does not publish tags, GitHub
  Releases, registry artifacts, websites, DNS, TLS, or production infra.
- Durable persistence for tokens/queue is intentionally out of scope for v0.

See [`CHANGELOG.md`](CHANGELOG.md) and [`docs/release.md`](docs/release.md).

## Related repositories

- [`../analytics-service`](../analytics-service) — ingest/query data plane that
  receives `/v1/events:batch`.
- [`../control-plane`](../control-plane) — mints/introspects the ingest tokens
  the `token_provider` supplies (ADR-0222).
- [`../developers`](../developers) — public docs for the ingest API and SDKs.
- [`../shardpilot-go`](../shardpilot-go) · [`../shardpilot-unity`](../shardpilot-unity)
  · [`../shardpilot-unreal`](../shardpilot-unreal) — sibling client SDKs.

## License

Apache-2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
