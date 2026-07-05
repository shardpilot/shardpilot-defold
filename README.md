# shardpilot-defold

> Pure-Lua Defold source SDK for ShardPilot app-first telemetry — no native
> extension required. Buffers app-first analytics events in a Defold game,
> publishes them to the ShardPilot analytics ingest API, and fetches
> ETag-cached remote config with a durable last-known-good fallback.

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
  reports `0.5.0`, `game.project` declares `0.1.0`). The latest unreleased work
  is tracked as `v0.5.0 — unreleased` in [`CHANGELOG.md`](CHANGELOG.md); treat
  that as the intent until the strings are reconciled.

## What it does

- Provides a Defold library (`shardpilot/`) you consume as source — there is no
  C/C++/native extension.
- Buffers app-first events in a bounded in-memory queue and publishes them in
  batches over the Defold global `http.request`. When `http.request` is absent
  (e.g. a plain Lua host) dispatch returns `http_unavailable` and events stay
  queued.
- **Survives offline play and app kills.** Undeliverable events (a transiently
  failed batch, the remnant at `shutdown()`, or an explicit `persist()`
  snapshot) are written to a bounded per-app durable spool and re-sent on a
  later launch with their original `event_id`, so the ingest service
  de-duplicates re-sends. See [Offline durability](#offline-durability-event-spool).
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
  previous-session native crash dump on next launch. Every dispatched report is
  persisted **write-ahead** to a bounded per-app sidecar and re-sent on a later
  launch until the server acknowledges it — byte-identical, one report at a
  time. See [`docs/crash.md`](docs/crash.md).
- Fetches **remote config** from the remote-config endpoint with an
  ETag-revalidated durable cache and typed getters
  (`remote_config_number("spawn_rate", 1.0)`), serving the last-known-good
  snapshot across restarts and offline launches, and failing closed on
  `401`/`403`. Every fetch is an explicit game-triggered call. See
  [Remote config](#remote-config).

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
  -- shutdown() starts a final flush. When the flush cannot deliver everything,
  -- the undelivered events are written to the durable offline spool and
  -- shutdown returns true — they re-send on the next launch. It still returns
  -- false, "consent_pending" while a consent decision is awaiting a token
  -- (consent receipts are not spooled; retry shutdown once the token lands),
  -- and with spool_enabled = false it returns false, err whenever events
  -- remain undelivered (retry shutdown until it returns true).
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
| `remote_config_url` | `nil` (disabled) | Remote-config base URL (same shape rules as `ingest_url`); a **separate** service from the ingest endpoint. Requires `api_key` — see [Remote config](#remote-config) |
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
| `spool_enabled` | `true` | Durable offline event spool ([details](#offline-durability-event-spool)); `false` also clears a previously persisted record at init |
| `spool_max_events` | `500` | Max spooled entries (≥1); oldest evicted first |
| `spool_max_bytes` | `262144` | Approx. spool size budget (1024–393216); oldest evicted first |

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

> **Remote config is the exception.** The remote-config endpoint authenticates
> with the publishable `sp_ingest_…` `api_key` only — a Mode B ingest JWT is
> scoped to event ingest and the remote-config endpoint rejects it. So with
> `remote_config_url` set, `api_key` is required even in Mode B
> (`remote_config_api_key_required` otherwise), and that is the **one**
> configuration where both credentials are valid together: the
> `token_provider` keeps the ingest `Bearer`, the `api_key` authenticates only
> the remote-config fetch.

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

## Offline durability (event spool)

Player devices go offline and games get killed mid-session. To keep those
events, the SDK persists undeliverable event envelopes to a small durable
per-app spool and re-sends them on a later launch. Enabled by default
(`spool_enabled = true`).

**What is spooled, and when.**

- A batch whose publish failed for a **transient** reason — network
  unreachable, timeout, `429`, or `5xx` (the same classification that already
  retains a batch for in-process retry; a Mode B `401` is included since a
  fresh token can be minted, a Mode A `401` is terminal and never spooled).
- The **undelivered remnant at `shutdown()`** (queue + in-flight batch). When
  that remnant is durably saved, `shutdown()` completes the teardown and
  returns `true` — the events are safe on disk, so a host retry loop is no
  longer needed for events. "Durably" is strict: on a runtime without the
  save-file API (where the spool falls back to process memory), or when part
  of the remnant itself was evicted by the caps, `shutdown()` keeps the old
  contract and returns `false, err` so the host can retry. The same holds
  when a **permanent** rejection during the final flush dropped the batch:
  nothing is left to spool (permanent rejects never are), so the failure
  surfaces as `false, err` instead of a clean teardown — a repeated
  `shutdown()` call then completes normally, since the queue is already
  clean. A pending consent
  decision still returns `false, "consent_pending"` (consent receipts are not
  spooled).
- An explicit **`persist()`** snapshot (instance + singleton): writes every
  undelivered event to the spool without sending or tearing down, while the
  client keeps running. It reports `false, "spool_persist_failed"` when the
  snapshot could not be durably and fully captured (same strictness as
  `shutdown()`).
- Permanent `4xx` rejects are **never** spooled — they would fail forever.

**Resend.** On the next `init`/`new`, spooled envelopes are re-sent through
the normal publish machinery — chunked to `batch_size`, **before** fresh
events, honoring the same token, consent, `Retry-After`-deferral, and backoff
gates. Envelopes are stored and re-sent **verbatim**: the `event_id` and
`event_ts` stamped at `track()` time are never rebuilt, so the ingest service
de-duplicates a re-send that raced an original delivery. Entries leave the
spool only when the server acknowledges their batch (2xx) — ack-based removal
keyed by `event_id` — or when a re-send is permanently rejected (surfaced via
the `diagnostics` hook with `scope = "spool"`). A transient re-send failure
keeps the entry for the launch after that. If the removal rewrite itself hits
a storage error, the entries stay marked settled and the rewrite is retried on
the flush cadence until it lands. A server-requested delay also survives a
relaunch: when a `429` `Retry-After` arrives while a batch is spooled, the
deadline is stored with the record, and a launch inside that window waits out
the remainder before re-sending (bounded by the same 24-hour clamp as the
in-process deferral).

**Caps.** The spool is bounded by `spool_max_events` (default 500) and
`spool_max_bytes` (default 256 KB, max 384 KB to keep headroom under the
save-file API's documented 512 KB per-record cap; the size estimate is
approximate). Over a cap, the **oldest** entries are evicted first. When the
eviction reaches into the batch being captured itself, `shutdown()` /
`persist()` report failure (the in-memory copy is kept for in-process retry)
rather than claiming the whole remnant is safe. The caps are re-applied to a
previously persisted record at load, so lowering the budgets trims an old
record (oldest first) durably.

**Consent & identity.** A persisted "denied" consent decision clears the spool
at load without sending anything — the purge runs even when the record cannot
be read (a corrupt record is still cleared); `set_consent(false)` at runtime
purges it too. A denied player's events never linger on disk. If the durable
purge itself fails (a storage error), `set_consent(false)` returns
`false, "spool_purge_failed"` and the spool goes **fail-closed** — nothing is
appended, loaded, or re-sent — while the purge is retried at later dispatch
points (and at the next launch) until it lands; calling `set_consent(false)`
again retries it immediately. Revocation cleanup completes **before** a new
grant takes effect: `set_consent(true)` while that purge is still owed
retries it first and, if it still fails, returns `false, "spool_purge_failed"`
without applying the grant — the persisted decision stays denied, so a
relaunch cannot replay the pre-revocation record. Under Mode B auth, tokens
are minted bound to the *current* anonymous ID — so if an init-time
`anonymous_id` override changes the identity, spooled envelopes carrying the
previous one are dropped from the record at load (surfaced via the
`diagnostics` hook as `scope = "spool"`, code `identity_changed`) instead of
being re-sent into a guaranteed rejection; Mode A has no token binding and
re-sends historic-identity envelopes unchanged. Disabling the spool
(`spool_enabled = false`) also deletes any previously persisted record at the
next init. The spool stores only the envelope fields that were already bound
for the wire — never tokens. See [`docs/privacy.md`](docs/privacy.md).

**Recommended: snapshot on focus loss.** The SDK never installs global
listeners itself, so call `persist()` from your window listener — on mobile an
iconified app can be killed without `final()` ever running. Note that Defold
keeps a **single** window listener (`window.set_listener` replaces any
previously set one), so add the `persist()` branch inside your existing
listener rather than registering a new one:

```lua
window.set_listener(function(self, event, data)
  -- ... your existing resize/focus/iconify handling ...
  if event == window.WINDOW_EVENT_ICONFIED or event == window.WINDOW_EVENT_FOCUS_LOST then
    shardpilot.persist() -- snapshot undelivered events; delivery continues normally
  end
end)
```

Events persisted this way are removed from the spool as soon as their normal
delivery is acknowledged, so the snapshot costs nothing when the app keeps
running.

## Remote config

```lua
shardpilot.fetch_remote_config(function(result)
  -- result = { ok, from_cache, error?, values?, version? }
end)

-- Typed getters read the last served snapshot; they never touch the network,
-- never fail, and return the default until config is available.
local spawn_rate = shardpilot.remote_config_number("spawn_rate", 1.0)
local motd = shardpilot.remote_config_string("motd", "")
local hard_mode = shardpilot.remote_config_boolean("hard_mode", false)
```

The fetch is `GET {remote_config_url}/config/v1/{workspace_id}/{environment_id}/{client_id}`
with the publishable `api_key` as the `Bearer` (`client_id` = the persisted
anonymous ID — the same identity the events carry, so per-client rollout
bucketing is consistent with analytics). The endpoint answers
`{ "version": <number>, "values": { key: value } }` with an `ETag`; the getters
serve the `values` map, and `remote_config_version()` reads the wrapper's
`version` only — it is response metadata, never a configuration value.
Responses are cached in a durable per-app record
(`{scope, etag, body, fetched_at_ms}`) through the same `sys.save` storage
seam as the identity record and the spools.

Fetch semantics:

- **200** — fresh values are served (`from_cache = false`) and the cache is
  overwritten.
- **304 Not Modified** — subsequent fetches revalidate with `If-None-Match`,
  and the cached snapshot is served (`from_cache = true`); the record's
  freshness stamp is renewed (best-effort in the durable record too), since
  the endpoint just confirmed the body as current. A fresher record with a
  **different** body persisted while the request was in flight is never
  displaced by the renewal — a 304 validates at server handling time, not
  delivery time.
- **Transient failure** (offline, a request timeout (`408`), `429`, `5xx`,
  malformed body) — the cached snapshot is served with `from_cache = true`
  and `error` carrying the reason; with no usable cache the fetch fails.
- **`401`/`403` fails closed** — the fetch reports `unauthorized` and the
  cached snapshot is **not** served for that outcome, so a revoked or wrong
  key never keeps supplying config. The cache file itself is left untouched
  (getters keep the last served snapshot; a later authorized fetch
  revalidates against the kept ETag).
- **Any other status is a permanent failure** — a `404` for a removed
  environment, an unexpected redirect, other `4xx`: retrying cannot help, so
  the fetch fails (`http_<status>`) instead of reporting stale values as a
  healthy `ok = true`. As with `401`/`403`, the record and the getter
  snapshot are left untouched.

The cache is scoped to the `(workspace_id, environment_id, client_id,
remote_config_url)` tuple; a record written by any other scope is a miss (its
ETag is never sent, its values never served) and is overwritten by the next
successful fetch. Rotating the anonymous ID re-scopes the next fetch the same
way.

**Honest boundaries:**

- **Guaranteed:** after one successful fetch, the last-known-good snapshot
  survives restarts and is served offline (from the durable record; on hosts
  without the `sys` save-file API the cache is memory-only and lasts for the
  process lifetime, like the identity record).
- **Not guaranteed / not provided:** the SDK never fetches on its own — there
  is no automatic or interval refresh, no `Cache-Control` interpretation, and
  no push; every fetch is an explicit call. There is no experiment
  assignment, no exposure events, and no client-side stats. A config body
  large enough to approach the documented 512 KB `sys.save` cap — or any
  body whose durable write fails — is still served and stays the in-process
  offline fallback, but is not persisted (surfaced via `diagnostics`), and
  the older persisted record it superseded is cleared (best-effort; a
  fresher record persisted meanwhile by another client of the same app is
  left in place) so a restart serves the game's defaults rather than
  rolled-back values. Before the first successful fetch on a fresh install,
  getters serve the caller's defaults.
- The fetch is **not consent-gated**: config delivery carries no analytics
  payload — the client id in the URL only scopes which config to serve
  (consistent across our SDKs). See [`docs/privacy.md`](docs/privacy.md).

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
via `crash.capture_previous()`, which first re-sends any reports whose earlier
delivery was never confirmed — every dispatched report is persisted write-ahead
to a bounded per-app sidecar (exact wire bytes, re-sent verbatim and
de-duplicated by `crash_id`; a `429 Retry-After` window persists across
relaunches and stops the serial resend pass). See [`docs/crash.md`](docs/crash.md).

## Privacy & consent

- **Tokens are memory-only.** Auth material is never written to disk. The live
  event queue is in-memory; only undeliverable event envelopes are persisted,
  to the bounded offline spool
  ([above](#offline-durability-event-spool)) — set `spool_enabled = false` for
  a fully memory-only event path.
- **Durable storage is four small bounded records** per configured app: the
  identity record (anonymous ID + consent decision), the offline event spool
  (only envelopes already bound for the wire; cleared on acknowledgment and on
  consent denial), a bounded, per-app, TTL'd pending-crash
  sidecar (see the crash note below) that holds the already-PII-scrubbed wire
  body of EVERY dispatched crash report — a live `emit`/`emit_fatal` and a
  previous-session dump forward alike — written before its send attempt and
  removed as soon as the server acknowledges or terminally rejects it, and the
  remote-config cache (the last served config body + ETag, no analytics
  payload; overwritten by the next successful fetch). The identity
  record is written through
  `sys.get_save_file("shardpilot.<workspace_id>.<app_id>", "identity")` with
  `sys.save`/`sys.load`. The per-app namespace prevents two games on one device
  from sharing an anonymous ID or consent state. Outside Defold (e.g. a plain
  Lua test host) it degrades gracefully to in-memory state. `get_anonymous_id()`
  returns the persisted anonymous ID so a host can hand it to its own backend at
  token-mint time (Mode B); the SDK always sends that same anonymous ID on the wire.
- **`set_consent(analytics_granted)`** records `unknown` (default, fully open),
  `granted`, or `denied`. `denied` drops events at enqueue, clears the pending
  queue, discards in-flight batches instead of retrying, and purges the
  offline spool. The decision is
  applied in memory and persisted to the identity record; if that durable write
  fails, `set_consent` returns `false, "consent_persist_failed"` (the in-memory
  decision and the wire report still proceed). If the identity record persisted
  but the durable spool purge failed, it returns `false, "spool_purge_failed"`
  and the spool stays fail-closed while the purge is retried automatically at
  later dispatch points; a later `set_consent(true)` retries that purge first
  and is **not applied** (same `false, "spool_purge_failed"` return, persisted
  decision stays denied) until the purge lands — revocation cleanup completes
  before a new grant takes effect. Call `set_consent` again to retry
  persistence, otherwise the decision can be lost on restart.
- Explicit consent decisions are reported to `POST {ingest_url}/v1/consent` over
  the same authenticated transport; consent never rides the event envelope. The
  report is **not** strictly fire-and-forget: if no token is available yet (e.g.
  an async Mode B `token_provider` still in flight) or the POST returns 401, the
  decision is retained as a pending consent and retried at the next dispatch
  point (`update`/`flush`/`shutdown`). While a pending consent is outstanding,
  `shutdown()` returns `false, "consent_pending"` instead of tearing down — call
  it again once a token is available so the decision is not dropped at exit.
- **Pending-crash sidecar.** Every dispatched crash report — a live
  `emit`/`emit_fatal` and a previous-session dump forward alike — has its
  already-PII-scrubbed wire body written to a small, bounded, per-app sidecar
  BEFORE the send attempt, so a process death or transient failure (offline /
  rate-limited / server error) never loses it; crash reports carry no actor
  identity keys. A pending report older than about seven days is discarded on
  read (a retention limit), and any entry is removed as soon as its report is
  accepted or terminally rejected. See
  [`docs/crash.md`](docs/crash.md#privacy).
- **Remote config is not consent-gated.** The fetch delivers configuration TO
  the device and carries no analytics payload; the anonymous client id in the
  URL only scopes which config to serve (per-client rollout bucketing). A
  denied analytics consent therefore does not block `fetch_remote_config` —
  consistent across our SDKs. The cached record holds only the served config
  body and its ETag.
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
| `shardpilot/remote_config.lua` | Remote-config fetch (`GET /config/v1/...`), ETag cache, typed getters |
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
| `test/` | Lua test harness (`test_sdk.lua`, `test_crash.lua`, `test_remote_config.lua`) + Defold collection/script |
| `docs/` | configuration · events · crash · privacy · release |
| `scripts/` | `check_library.sh` (content guard), `package_release.sh` |

## Conventions & boundaries

- **No native extension.** No `.c`/`.cpp`/`.mm`/`.java` or Extender references in
  SDK source. The guard greps file *contents* (`grep -RInE`) for these patterns,
  so it flags native references inside tracked files but does not catch a native
  source file added solely by filename — keep the boundary by convention.
- **No durable I/O beyond the identity record, the event spool, the
  crash-retry sidecar, and the remote-config cache.**
  `io.*`, `os.execute`, and browser/local storage are forbidden in source;
  `sys.save`/`sys.load`/`sys.get_save_file` are confined to
  `shardpilot/storage.lua`, which writes only the identity record, the bounded
  offline event spool, the bounded, TTL'd crash-retry sidecar, and the
  single bounded remote-config cache record.
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
- Durable persistence for tokens is intentionally out of scope (tokens stay
  memory-only by design); undeliverable events are covered by the offline
  event spool.

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
