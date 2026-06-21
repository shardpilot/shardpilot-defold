# shardpilot-defold

> Pure-Lua Defold source SDK for ShardPilot app-first telemetry — no native
> extension required. Buffers app-first analytics events in a Defold game and
> publishes them to the ShardPilot analytics ingest API.

ShardPilot is app-first: this SDK buffers analytics events and publishes them to
the ingest API. The wire shape and identity rules follow ShardPilot's app-first
analytics model and its dual-mode client ingest auth; games are a domain pack,
not the platform boundary.

## Status

- **v0 alpha, pre-1.0, API unstable.** This is public-preview source only. The
  surface may change before v1 with no backward-compatibility guarantee.
- **Pre-launch.** No GitHub Release, tag, or package artifact is published from
  this repo, and the production ingest domain is **not provisioned** yet. Use
  local/develop endpoints for evaluation.
- **Version strings are inconsistent across files** (`shardpilot/version.lua`
  reports `0.4.0`, `game.project` declares `0.1.0`). The latest unreleased work
  is tracked as `v0.4.0 — unreleased` in [`CHANGELOG.md`](CHANGELOG.md); treat
  that as the intent until the strings are reconciled.

## What it does

- Provides a Defold library (`shardpilot/`) you consume as source — there is no
  C/C++/native extension.
- Buffers app-first events in a bounded in-memory queue and publishes them in
  batches over the Defold global `http.request`. When `http.request` is absent
  (e.g. a plain Lua host) dispatch returns `http_unavailable` and events stay
  queued.
- Emits canonical helpers: `session_start()` → `app.session_started`,
  `screen_view(name)` → `app.screen_view`, plus arbitrary `track(name, props)`.
- Generates and persists a UUIDv7 anonymous ID per configured app and supports
  `identify(user_id)` to upgrade attribution to a known user.
- Records a tri-state analytics consent decision (`unknown` / `granted` /
  `denied`) and enforces it at enqueue and dispatch time.
- Samples basic runtime signals via `update(dt)`, `observe_ping_ms(ms)`, and
  `observe_disconnect(reason)`.
- Reports **crashes** through a separate `require "shardpilot.crash"`
  module to a dedicated crash ingest endpoint with a `crash:write` key — never as
  an analytics event. Stamps a component-slug `source`, scrubs PII, samples
  non-fatal reports while **always** sending fatal ones, and forwards a
  previous-session native crash dump on next launch. See [`docs/crash.md`](docs/crash.md).

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
  -- shutdown() starts a flush and returns ok, err. In Defold builds where
  -- http.request completes asynchronously it may return false, "pending"
  -- (a batch is still in flight) or false, "consent_pending" (a consent
  -- decision is awaiting a token). To avoid dropping the final batch, flush
  -- earlier (e.g. on background) or retry shutdown until it returns true.
  local ok, err = shardpilot.shutdown("app_final")
  if not ok then
    print("shardpilot shutdown not complete: " .. tostring(err))
  end
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

The ingest endpoint accepts two credential kinds; configure **exactly one**:

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
`event_ts_server`, `event_seq_session`, and top-level `build_version`. Of these,
`project_id`, `game_id`, `event_ts_server`, `event_seq_session`, and
`build_version` are CI-guarded by
[`scripts/check_library.sh`](scripts/check_library.sh). See
[`docs/events.md`](docs/events.md).

## Crash wire contract

Crashes use a **separate** module and endpoint. The crash client
(`require "shardpilot.crash"`) sends one report per crash as
`POST {crash_ingest_url}/api/v1/crashes/ingest` with a `crash:write` API key as
the `Bearer`, carrying the crash report JSON body: `crash_id`
(UUIDv7), `occurred_at`, `app{id,version,build_id}`, a component-slug `source`,
`platform`, `os`, `exception`, `modules[]`, `threads[]`/`frames[]`,
`breadcrumbs[]`, `fingerprint_components[]`, and `metadata`. A crash is **never**
wrapped as a `mobile_crash` analytics event on `/v1/events:batch`. Fatal reports
bypass sampling; a previous-session native crash dump is forwarded on next launch
via `crash.capture_previous()`. See [`docs/crash.md`](docs/crash.md).

## Privacy & consent

- **Memory-only by default.** Tokens and the event queue live only in memory;
  there is no durable local event queue in v0.
- **Durable storage is a single identity record** (anonymous ID + consent
  decision) per configured app — plus a bounded, per-app, TTL'd crash-retry
  sidecar (see the crash note below) that holds only an already-PII-scrubbed
  previous-session crash report, resent then cleared on success. The identity
  record is written through
  `sys.get_save_file("shardpilot.<workspace_id>.<app_id>", "identity")` with
  `sys.save`/`sys.load`. The per-app namespace prevents two games on one device
  from sharing an anonymous ID or consent state. Outside Defold (e.g. a plain
  Lua test host) it degrades gracefully to in-memory state. `get_anonymous_id()`
  returns the persisted anonymous ID so a host can hand it to its own backend at
  token-mint time (Mode B); the SDK always sends that same anonymous ID on the wire.
- **`set_consent(analytics_granted)`** records `unknown` (default, fully open),
  `granted`, or `denied`. `denied` drops events at enqueue, clears the pending
  queue, and discards in-flight batches instead of retrying. The decision is
  applied in memory and persisted to the identity record; if that durable write
  fails, `set_consent` returns `false, "consent_persist_failed"` (the in-memory
  decision and the wire report still proceed). Call `set_consent` again to retry
  persistence, otherwise the decision can be lost on restart.
- Explicit consent decisions are reported to `POST {ingest_url}/v1/consent` over
  the same authenticated transport; consent never rides the event envelope. The
  report is **not** strictly fire-and-forget: if no token is available yet (e.g.
  an async Mode B `token_provider` still in flight) or the POST returns 401, the
  decision is retained as a pending consent and retried at the next dispatch
  point (`update`/`flush`/`shutdown`). While a pending consent is outstanding,
  `shutdown()` returns `false, "consent_pending"` instead of tearing down — call
  it again once a token is available so the decision is not dropped at exit.
- **Crash-retry sidecar.** When a previous-session crash report cannot be sent on
  the next launch (offline / rate-limited / server error), the
  already-PII-scrubbed report is written to a small, bounded, per-app sidecar so
  it can be resent later. A pending report older than about seven days is
  discarded on read (a retention limit), and any entry is removed as soon as its
  report is accepted or terminally rejected. See
  [`docs/crash.md`](docs/crash.md#privacy).
- The SDK does not log tokens or full payloads, and makes no
  provider/model/GitHub/billing/account-management write calls. See
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
| `shardpilot/crash.lua` | Public crash entrypoint: singleton API + `new()` factory |
| `shardpilot/crash/client.lua` | Crash client: config, sampling, emit/emit_fatal/capture_previous |
| `shardpilot/crash/event.lua` | Crash report JSON body shape, normalize, sanitize, validate |
| `shardpilot/crash/sanitize.lua` | Crash PII scrubbing (emails, IPs, raw-id prefixes, tokens) |
| `shardpilot/crash/breadcrumbs.lua` | Bounded breadcrumb ring |
| `shardpilot/crash/transport.lua` | Crash dispatch (`/api/v1/crashes/ingest`) |
| `shardpilot/crash/dump.lua` | Previous-session native dump → crash event |
| `game.project` | Defold library metadata (`[library] include_dirs = shardpilot`) |
| `examples/minimal/` | Copy-pasteable usage example |
| `test/` | Lua test harness (`test_sdk.lua`, `test_crash.lua`) + Defold collection/script |
| `docs/` | configuration · events · crash · privacy · release |
| `scripts/` | `check_library.sh` (content guard), `package_release.sh` |

## Conventions & boundaries

- **No native extension.** No `.c`/`.cpp`/`.mm`/`.java` or Extender references in
  SDK source. The guard greps file *contents* (`grep -RInE`) for these patterns,
  so it flags native references inside tracked files but does not catch a native
  source file added solely by filename — keep the boundary by convention.
- **No durable I/O beyond the identity record and the crash-retry sidecar.**
  `io.*`, `os.execute`, and browser/local storage are forbidden in source;
  `sys.save`/`sys.load`/`sys.get_save_file` are confined to
  `shardpilot/storage.lua`, which writes only the identity record and the
  bounded, TTL'd crash-retry sidecar.
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

- **Engine:** Defold (uses `sys`, `http.request`); degrades to in-memory
  identity state when `sys` is absent, and dispatch returns `http_unavailable`
  when `http.request` is absent.
- **Lua runtime:** Defold's embedded runtime is LuaJIT / Lua 5.1-compatible;
  write SDK source against Lua 5.1 language features so it runs in-game.
- **Test runner:** CI installs `lua5.4` only as the host interpreter for
  `test/test_sdk.lua`; it is not the in-Defold runtime target, so avoid relying
  on Lua 5.4-only syntax or APIs that would fail inside the engine.
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

## Related

- The **ShardPilot platform** — receives the event batches this SDK publishes
  (`/v1/events:batch`) and issues and introspects the ingest credentials
  (publishable `sp_ingest_…` keys and, for Mode B, the per-tenant signing secret
  your backend uses to mint ingest JWTs).
- [`shardpilot-go`](https://github.com/shardpilot/shardpilot-go) — the public Go
  client SDK.

## License

Apache-2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
