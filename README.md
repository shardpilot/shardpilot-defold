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
- **Pre-launch.** The production ingest domain is **not provisioned** yet — use
  local/develop endpoints for evaluation.
- **Version `0.10.0`.** `game.project`, `shardpilot/version.lua`, and the top
  [`CHANGELOG.md`](CHANGELOG.md) entry all report `v0.10.0`; the `v0.10.0` tag
  is published per [docs/release.md](docs/release.md).

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
- **Consent-first analytics.** Records an explicit consent decision over the
  states `unknown` / `granted` / `denied` / `denied_forced_minor` (the
  age-gate-forced denial, which gates exactly like `denied`) and transmits
  **only under an explicit grant**: while consent is `unknown` (the default)
  events are dropped at enqueue with `consent_unknown` — nothing queued,
  nothing spooled, zero wire traffic. Explicit decisions post a consent
  receipt retained in a **durable outbox** until the server acknowledges it,
  so a receipt survives process death and offline commits. See
  [Privacy & consent](#privacy--consent).
- **Capability discovery.** `shardpilot.supports(capability)` feature-detects
  SDK abilities before `init()` — `"consent_receipt_outbox"`,
  `"consent_state_denied_forced_minor"`, `"schema_revision_declaration"`, and
  `"experiments_assignment"` today; unknown names return `false` on older and
  newer SDKs alike, so integrations can gate new call shapes safely.
- Samples basic runtime signals via `update(dt)`, `observe_ping_ms(ms)`, and
  `observe_disconnect(reason)`.
- Reports **crashes** through a separate `require "shardpilot.crash"`
  module to a dedicated crash ingest endpoint with a `crash:write` key — never as
  an analytics event. Stamps a component-slug `source`, scrubs PII, samples
  non-fatal reports while **always** sending fatal ones, and forwards a
  previous-session native crash dump on next launch — automatically from
  `crash.init` (disable with `capture_previous_on_boot = false`), with the
  engine module's symbol identity synthesized as `dmengine-<version_sha1>`
  and an opt-in (default-off) Lua script-error auto-capture
  (`script_error_capture_enabled`). Every dispatched report is
  persisted **write-ahead** to a bounded per-app sidecar and re-sent on a later
  launch until the server acknowledges it — byte-identical, one report at a
  time. Crash reporting is **on by default** with a persisted per-app opt-out
  (`crash.set_enabled(false)`) that stops collection entirely and **fails
  closed** when the persisted state cannot be read. See
  [`docs/crash.md`](docs/crash.md).
- Fetches **remote config** from the remote-config endpoint with an
  ETag-revalidated durable cache and typed getters
  (`remote_config_number("spawn_rate", 1.0)`), serving the last-known-good
  snapshot across restarts and offline launches, and failing closed on
  `401`/`403`. Every fetch is an explicit game-triggered call. See
  [Remote config](#remote-config).
- Serves **experiments** — server-evaluated variant assignments with a durable
  last-known-good cache, periodic revalidation, and exposure/outcome facts.
  **Off by default** behind `experiments_enabled`, requires analytics consent
  `granted`, and fails closed (no variant served) until experiments are
  enabled server-side for your app. See [Experiments](#experiments).

## Installation

`game.project` exposes only the SDK folder as a Defold library:

```ini
[library]
include_dirs = shardpilot
```

The recommended path today is to vendor the `shardpilot/` directory into your
project. Alternatively, pin the repo as a Defold library dependency to a
published tag's source archive — the latest tag is `v0.10.0`:

```ini
[project]
dependencies#0 = https://github.com/shardpilot/shardpilot-defold/archive/refs/tags/v0.10.0.zip
```

Note that no packaged release ZIP asset is attached to any GitHub Release yet —
the tag source archive above is the only hosted dependency URL.

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
  -- Consent-first: NOTHING transmits until an explicit grant. Wire this to
  -- your consent UX; while consent is undecided every track/session call
  -- returns false, "consent_unknown" and the event is dropped, not held.
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
  -- shutdown returns true — they re-send on the next launch. An undelivered
  -- consent receipt behaves the same way: durably retained in the consent
  -- outbox, it re-sends next launch and shutdown completes. It returns
  -- false, "consent_pending" only when the receipt could NOT be durably
  -- captured (no save-file backend, or the write keeps failing) — retry
  -- shutdown then — and with spool_enabled = false it returns false, err
  -- whenever events remain undelivered (retry shutdown until it returns true).
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
client:set_consent(true) -- consent-first: required before any event flows
client:track("play_cta_click", { cta_source = "main_menu" })
client:flush()
client:shutdown("app_final")
```

Most methods return `ok, err` so callers can branch on failures (e.g.
`not_initialized`, `consent_pending`).

## AI-assisted integration

Integrating with an AI coding tool (Claude Code or similar)? This repo ships a
customer-facing integration skill at
[`.claude/skills/shardpilot-defold-integration/SKILL.md`](.claude/skills/shardpilot-defold-integration/SKILL.md)
— point your tool at it for the install paths, credential rules, the
consent-first contract, and a verify-your-integration checklist, all written
against this SDK's source. Claude Code picks it up automatically when working
inside this repository. The ShardPilot docs site (`docs.shardpilot.com`) is
pre-launch and not yet live; once it launches it will also publish an
`llms.txt` family for machine consumption — until then, this repository's
README, `docs/`, and the skill above are the reference.

## Configuration

`init(config)` / `new(config)` take a Lua table. Required: `ingest_url`,
`workspace_id`, `app_id`, `environment_id`, and **exactly one** of
`token_provider` (Mode B) or `api_key` (Mode A) — see [Authentication](#authentication).

| Field | Default | Notes |
|---|---|---|
| `ingest_url` | — (required) | `https://…`, or `http://` only for `localhost`/`127.0.0.1`/`::1`; no query/fragment/path |
| `remote_config_url` | `nil` (disabled) | Remote-config base URL (same shape rules as `ingest_url`); a **separate** service from the ingest endpoint. Requires `api_key` — see [Remote config](#remote-config) |
| `remote_config_attributes_enabled` | `false` (dark) | ADR-0310 opt-in: fetches carry the attributes stored via `set_remote_config_attributes` as query parameters — only while consent is **granted** (unknown/denied fetch attribute-less). Requires `remote_config_url` — see [Remote config](#remote-config) |
| `experiments_enabled` | `false` (off) | Opts into the experiment-assignment consumer. Requires **both** `remote_config_url` and `api_key` — see [Experiments](#experiments) |
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
| `buffer_size` | `1000` | Max queued events (≥1); cross-SDK canonical default |
| `flush_interval_seconds` | `1` | Time-based flush trigger (>0) |
| `publish_timeout_seconds` | `2` | Per-request timeout (>0) |
| `token_refresh_lead_ms` | `60000` | Refresh lead before token expiry (≥0) |
| `spool_enabled` | `true` | Durable offline event spool ([details](#offline-durability-event-spool)); `false` also clears a previously persisted record at init |
| `spool_max_events` | `500` | Max spooled entries (≥1); oldest evicted first |
| `spool_max_bytes` | `262144` | Approx. spool size budget (1024–393216); oldest evicted first |
| `schema_revision` | built-in revision | Schema-set revision declared on batch ingest (`X-ShardPilot-Schema-Revision` request header); a string overrides the value, `false`/`""` stops declaring ([details](docs/configuration.md#schema-revision-declaration)) |

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

Each batch request also declares the SDK's schema-set revision in the
`X-ShardPilot-Schema-Revision` **request header** (never a body field; only
this route — consent, crash, and remote-config requests never carry it). A
`schema_revision_mismatch` `409` from an ingest service with the handshake
armed is terminal for the batch: dropped, never retried. See
[`docs/configuration.md`](docs/configuration.md#schema-revision-declaration);
`schema_revision = false` stops declaring.

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
  clean. An undelivered consent receipt holds teardown
  (`false, "consent_pending"`) only when it is NOT durably retained — a
  receipt safe in the durable consent outbox re-sends next launch, so
  `shutdown()` completes over it exactly like it does over spooled events
  (see [Privacy & consent](#privacy--consent)).
- An explicit **`persist()`** snapshot (instance + singleton): writes every
  undelivered event to the spool without sending or tearing down, while the
  client keeps running. It reports `false, "spool_persist_failed"` when the
  snapshot could not be durably and fully captured (same strictness as
  `shutdown()`).
- **With experiments enabled, two more lifecycle failures exist — and the two
  methods report the same debt differently.** Both refuse to claim safety
  while something owed has not been captured, but the code depends on which
  debt and which call:

  | Owed debt | `persist()` reports | `shutdown()` reports |
  |---|---|---|
  | assignment-cache write still failing | `experiments_pending` | `experiments_pending` |
  | exposure fact not captured (queue full) | `experiments_pending` | `queue_full` |

  Both codes are **retryable**, exactly like `spool_persist_failed`:
  `flush()` and call again. Branch on the code the method you called actually
  emits — a host that treats any non-`true` return as fatal will tear down
  over recoverable debt.
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
relaunch cannot replay the pre-revocation record. A configured
`anonymous_id` override that replaces a DIFFERENT persisted identity boots a
**fresh identity** in both auth modes: consent starts `unknown`, the
previous actor's spool is purged at init, and their persisted decision is
never applied to the new actor (see [`docs/privacy.md`](docs/privacy.md)).
Within a restored grant, Mode B tokens are minted bound to the *current*
anonymous ID — so when the stored anonymous id itself was replaced at load
(the corrupt/oversized-record self-heal), spooled envelopes carrying the
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
  no push; every fetch is an explicit call. Remote config carries no
  experiment assignment and emits no exposure events — that is a separate,
  default-off plane with its own endpoint and its own consent rule; see
  [Experiments](#experiments). A config body
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
- **Targeting attributes (dark opt-in, ADR-0310) are the one
  granted-consent-only exception.** With
  `remote_config_attributes_enabled = true`, attributes stored via
  `shardpilot.set_remote_config_attributes({ geo = "US", … })` ride each
  fetch as sorted, percent-escaped query parameters so **server-side**
  delivery rules can target this client (`nil`/empty clears the set; the
  setter is inert while the flag is off). The vocabulary and bounds are the
  experiment consumer's, verbatim: `geo`, `app_version`, `device_type`,
  `install_date`, `user_segment`, plus `custom_attribute_<name>`
  (≤512-byte values, 64-attribute cap; out-of-vocabulary names are dropped
  client-side, never sent). Attributes ride **only while consent is
  granted**: unknown consent or either denied state (forced-minor included)
  keeps the URL byte-identical to the attribute-less path — the fetch still
  happens and serves the untargeted defaults, so config delivery stays
  consent-neutral while "no grant = zero attribute bytes" holds. The SDK
  still evaluates no rules client-side, and the durable cache stays one
  record per (workspace, environment, client, url) scope, targeted or not —
  a cached body may reflect the previously sent attribute set until the
  next successful fetch (documented v1 limit).

## Experiments

**Off by default.** The experiment-assignment consumer is dark behind
`experiments_enabled = true`. While the flag is off — the default — no
experiment code path executes at all: no subject id is minted, no request is
made, no revalidation timer runs, no exposure is emitted, and no new durable
record is written. The public calls answer `false, "experiments_not_configured"`
and the getters return `nil`, so game code that already calls them keeps
running its control experience unchanged.

One deliberate exception, and it only applies to a build that had experiments
**on** in an earlier run: turning the flag back off does not strand whatever
that run left behind. `init()` still reads the small clear marker and filters
any matching experiment facts out of the offline spool, so a
rollback launch cannot replay withdrawn assignment data. A build that has
never had the flag on has no such state, and this path does nothing.

**Enabling experiments takes three config fields, not one.** Setting the flag
by itself is rejected at `init()`:

| Setting this… | …also requires | Otherwise `init()` returns |
|---|---|---|
| `experiments_enabled = true` | `remote_config_url` | `false, "experiments_requires_remote_config_url"` |
| `remote_config_url` | `api_key` | `false, "remote_config_api_key_required"` |

The assignment endpoint is served by the **same host** as the remote-config
fetch and authenticates with the **same publishable `api_key`**, so a valid
experiments configuration always carries all three fields together:

```lua
shardpilot.init({
  ingest_url = "https://…",
  remote_config_url = "https://…", -- required by experiments_enabled
  api_key = "sp_ingest_…",         -- required by remote_config_url
  workspace_id = "workspace-example",
  app_id = "app-example",
  environment_id = "develop",
  experiments_enabled = true,
})
```

In Mode B, `token_provider` and `api_key` are configured *together* (the
documented exception to "exactly one" — see [Authentication](#authentication)):
the token stays the ingest `Bearer`, the `api_key` authenticates the
remote-config and assignment fetches. Feature-detect the surface before
`init()` with `shardpilot.supports("experiments_assignment")`.

### API

```lua
-- Fetch the server-evaluated assignment. `attributes` is optional —
-- (experiment_key, callback) is accepted too. The synchronous return is
-- DISPATCH status, not the answer: `true` means the request went out and the
-- result will arrive through the callback; `false, err` means the call was
-- refused before dispatch (and the callback still reports that refusal).
-- Read the assignment off the callback -- with one exception: shutdown()
-- cancels the callbacks of requests still in flight, so do not park state
-- that only a callback can release across a shutdown.
shardpilot.fetch_experiment_assignment("menu_layout", function(result)
  -- result = { ok, from_cache, assigned?, variant_key?, variant_payload?,
  --            version?, boundary?, reason?, error? }
  -- `boundary` is a copy of the server's boundary table, passed through on a
  -- 200 for host introspection (e.g. `assignment_unit`, `production_rollout`).
  -- Read it if you want it; the SDK itself only acts on `assignment_unit`.
  if result.ok and result.assigned then
    apply_layout(result.variant_key, result.variant_payload)
  end
end)

-- With optional targeting attributes (server-evaluated; see below):
shardpilot.fetch_experiment_assignment("menu_layout", { geo = "US" }, function(result) end)

-- Cached getters: never touch the network, never fail, never re-bucket.
-- Both return nil when there is no assignment to serve — treat nil as the
-- control experience.
local variant = shardpilot.experiment_variant("menu_layout") -- variant key string, or nil
local payload = shardpilot.experiment_payload("menu_layout") -- variant payload copy, or nil

-- Emit one extra exposure fact for the live assignment (the automatic
-- at-most-once-per-session exposure needs no call). Returns ok, err.
shardpilot.track_exposure("menu_layout")

-- Record a host-defined outcome. `outcome_value` must be a NUMBER.
-- Returns ok, err.
shardpilot.track_outcome("menu_layout", "purchase_value", 4.99)
```

| Call | Returns | Failure codes you can branch on |
|---|---|---|
| `fetch_experiment_assignment(key, [attributes], callback)` | `true` = dispatched, or `false, err` = refused before dispatch; the assignment arrives through `callback` unless `shutdown()` cancels it first | pre-dispatch: `not_initialized`, `shutdown`, `experiments_not_configured`, `experiment_key_required`, `consent_unknown`, `consent_denied`, `http_unavailable`, `json_unavailable`. In the callback's `result.error`: `unauthorized`, `not_found`, `bad_request`, `malformed_response`, `stale_subject`, `superseded`, `consent_unknown`, `consent_denied`, `consent_changed`, `http_0`, `transient_408`, `transient_429`, `transient_<5xx>`, and `http_<status>` for anything unclassified |
| `experiment_variant(key)` | variant key `string`, or `nil` | — (never fails) |
| `experiment_payload(key)` | the variant payload (a copy), or `nil` | — (never fails) |
| `track_exposure(key)` | `ok, err` | `not_initialized`, `shutdown`, `experiments_not_configured`, `experiment_key_required`, `no_assignment`, `consent_unknown`, `consent_denied`, `exposure_no_subject_fact_key`, `queue_full` |
| `track_outcome(key, outcome_key, outcome_value)` | `ok, err` | the `track_exposure` codes plus `invalid_outcome_key` (non-empty string required) and `invalid_outcome_value` (number required) |

`queue_full` is the one worth retrying: the in-memory event queue is at
`buffer_size`, so flush (or wait for the next batch) and call again rather
than dropping the exposure or outcome.

Two callback rules worth internalizing. **Consent can close the plane while a
request is in flight** — a downgrade mid-flight resolves the callback with
`consent_unknown` / `consent_denied`, and a deny→re-grant that raced the
response resolves it with `consent_changed`; all three mean no variant, and
all three reach you through `result.error`, not the synchronous return.
**`shutdown()` cancels in-flight callbacks** — a request dispatched before a
successful shutdown never calls back at all, by design, so never leave state
parked that only a callback can release.

The fetch is
`GET {remote_config_url}/api/v1/runtime/experiments/assignment?app_key=&environment_key=&experiment_key=&subject_key=`
with the publishable `api_key` as the `Bearer`. The subject is an
**SDK-minted, SDK-managed** id (`spcid_` + 32 hex) persisted in the durable
identity record: there is deliberately no config field and no setter for it,
it is distinct from the anonymous ID, and it egresses **only** as this fetch's
`subject_key` — never in an analytics event, prop, or envelope identity.

Its persistence is **best effort, and that has a stickiness consequence.** On
a host with no working save-file backend, or when the durable write simply
fails (diagnosed, not fatal), the minted id stays memory-only — so the next
launch mints a *new* subject, and the server, bucketing on that id, may put
the player in a different variant. Long-run stickiness is only as good as the
identity record's durability on the platform you ship to. This is also why
the id is never host-settable: there is no supported way to pin it yourself.

### Fetch semantics

- **Assigned** — the variant is served (`assigned = true`) and cached in
  memory plus one durable per-app record, so a later launch serves the
  last-known-good variant offline. Stickiness is entirely the server's
  deterministic hash; this client **never re-buckets locally** — the cache is
  a latency/offline device, not an assignment authority. The durable half is
  **best effort**: the record has a fixed size cap and evicts the
  oldest-fetched assignments to stay under it, and on a host without a
  working save-file backend it degrades to process-local memory. An evicted
  or unpersisted assignment keeps serving for the rest of the process, and
  the loss is never a wrong serve — but **recovering it is your call, not the
  SDK's.** The revalidation cadence only refreshes experiments already in the
  cache; it cannot rediscover a key that is missing, so a launch that starts
  without the record stays on the control path until your code calls
  `fetch_experiment_assignment` for that key. Fetch the experiments you care
  about at startup rather than assuming the cache repopulates itself.
- **Variant payloads are copied with a depth limit of 16 nested tables.**
  Both the install and `experiment_payload` use the same bounded copy, and a
  subtree at or below that depth is dropped (`nil`) rather than rejected — so
  a payload nested 16+ deep reaches your game silently truncated. Keep
  variant payloads shallow; they are meant to be configuration, not a
  document tree.
- **Not assigned** — `ok = true, assigned = false` with a closed `reason`
  vocabulary: absent (a deterministic traffic-gate miss),
  `"targeting_unmatched"`, or `"kill_switch"` (an operator kill). All three
  drop the cached assignment, and a kill additionally stops any *future*
  exposure for it. It does **not** retroactively suppress a treatment that
  already ran: an exposure still owed at kill time — the variant was applied
  but the fact had not left yet, e.g. the queue was full — is deliberately
  retained and emitted afterwards, because an application that happened is a
  fact about the past. A `experiment_exposure` arriving shortly after a kill
  is therefore expected behavior, not a client violating the kill.
- **`401`/`403` fail closed** — the fetch reports `unauthorized`, **nothing is
  served** for that outcome, the getters go `nil`, and revalidation stops
  until re-`init()` or a later authorized fetch. The durable record is kept —
  with one exception: a `403` whose body reports that real-subject assignment
  was switched off also drops the stored record, so a withdrawn assignment
  cannot outlive the switch. Both flavors report the same `unauthorized`, so
  game code has nothing extra to branch on.
- **`404`** — permanent for that experiment key: treated as not-assigned,
  never served stale, and the revalidation cadence stops asking for it.
- **Transient** (`429`, `5xx`, `408`, offline, timeout, malformed body) — the
  cached assignment is served with `from_cache = true` and `error` carrying
  the reason (`transient_429`, `transient_<5xx>`, `transient_408`, `http_0`,
  `malformed_response`); `Retry-After` is honored on `429` and `5xx` — **in
  its delta-seconds form only.** A `Retry-After` sent as an HTTP-date is not
  parsed and is ignored, and the client falls back to its own jittered
  backoff. **Serving stale is attribute-fenced:** the
  cached assignment comes back only when the failing fetch asked with the
  same normalized targeting attributes it was evaluated under. Fetch the same
  experiment with a different `geo` (or any other changed attribute) and a
  transient failure returns `ok = false, from_cache = false` instead — a
  variant chosen for one targeting context is never handed back as the answer
  to another.

Cached assignments are re-fetched roughly every **300 s (±10% jitter)** while
the SDK is running, consent is granted, and at least one assignment is cached
— that cadence is the SDK's share of the kill-switch reach. Stated honestly:
**an offline client keeps its last-known-good variant indefinitely.**

### Before the server enables experiments for your app

Experiments must be enabled **server-side for your app** as well. Until that
happens, the assignment endpoint answers `403`, and this client treats it
exactly like any other unauthorized answer — it **fails closed**:

- the fetch reports `ok = false, error = "unauthorized"`;
- **no variant is served** — not even a previously cached one;
- `experiment_variant` / `experiment_payload` return `nil`, so your game runs
  its control experience;
- in-memory serving and the revalidation cadence stop until you re-`init()` or
  a later fetch is authorized.

So turning `experiments_enabled` on in a build is safe on its own: with
nothing enabled server-side you get the control path, not an error state your
game has to handle specially.

### Consent, targeting, and facts

- **Granted-only plane.** Every assignment fetch, cached serve, revalidation
  tick, and subject-id mint requires analytics consent `granted`. Under
  `unknown` or either denial flavor (forced-minor included) the consumer
  produces **zero** experiment traffic, refuses fetches with
  `consent_unknown` / `consent_denied`, and the getters serve `nil`. The
  durable cache record is retained but not served through a downgrade, and a
  later re-grant serves it again. This is deliberately **stricter** than
  `fetch_remote_config`, which is not consent-gated.
- **Targeting attributes** ride the fixed server vocabulary — `geo`,
  `app_version`, `device_type`, `install_date`, `user_segment`, plus
  `custom_attribute_<name>` where the suffix is **1–64 bytes** (measured in
  bytes, not code points — a multibyte suffix that looks short enough can
  still be over the limit, and an over-limit name is dropped silently; keep
  custom attribute names ASCII). Values are trimmed and bounded to 512 bytes,
  at most 64 attributes ride one fetch, and names outside the vocabulary are
  dropped client-side and never sent. Matching is **100% server-evaluated**;
  the SDK evaluates no rules.
- **Exposure and outcome facts** ride the normal analytics pipeline (queue →
  batch → spool → consent gates). At most one `experiment_exposure` is emitted
  automatically per (experiment, version, subject) per session when the
  assigned variant is first applied, with a deterministic `event_id` so
  retries collapse as duplicates server-side; `track_exposure` is the explicit
  re-arm on top of that, and `track_outcome` records host-defined numeric
  outcomes. **"At most one", not "exactly one":** a fact only emits when the
  assignment carries the server-supplied opaque key the fact is allowed to be
  attributed by. An assignment served without one — a synthetic-unit answer,
  for instance — is applied normally but emits **no** exposure at all,
  because the SDK-minted subject id must never reach the analytics plane. Do
  not assume every applied treatment produces a measured exposure. **Watch
  the right name:** the *automatic* skip is reported only to your
  `diagnostics` hook, as `status = "exposure_skipped"` with
  `code = "no_subject_fact_key"`. `exposure_no_subject_fact_key` is the
  distinct `err` returned from an explicit `track_exposure` /
  `track_outcome` call. Monitoring only the latter misses every automatic
  measurement gap.
  **Honest caveat:** the platform currently rejects these fact names
  from game-embedded publishable keys by design, so an emitted exposure is
  expected to come back as a per-event reject — surfaced through your
  `diagnostics` hook and otherwise tolerated silently — until that producer
  lane opens.

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
- **Durable storage is nine small bounded records** per configured app — the
  last three only ever created by the features that own them (a consent
  denial, and a run with `experiments_enabled` on): the
  identity record (anonymous ID + consent decision), the offline event spool
  (only envelopes already bound for the wire; cleared on acknowledgment and on
  consent denial), the consent-receipt outbox (undelivered `/v1/consent`
  receipts only — at most 32, denial-preferring eviction: the oldest pure
  grant is evicted first and a denial only when everything over the cap
  carries denials; pruned the moment the
  server acknowledges one; never event payloads, never purged by a denial —
  see the consent bullet below), a bounded, per-app, TTL'd pending-crash
  sidecar (see the crash note below) that holds the already-PII-scrubbed wire
  body of EVERY dispatched crash report — a live `emit`/`emit_fatal` and a
  previous-session dump forward alike — written before its send attempt and
  removed as soon as the server acknowledges or terminally rejects it, the
  crash-reporting settings record (the persisted `crash.set_enabled` opt-out
  boolean, nothing else), the
  remote-config cache (the last served config body + ETag, no analytics
  payload; overwritten by the next successful fetch), the small write-ahead
  consent denial marker (written before a denial is applied so the denial
  survives a crash mid-purge; no analytics payload), and — created only by a
  run with `experiments_enabled` on — the experiment-assignment cache and its
  clear marker. Those last two are the SDK's most identifier-bearing storage
  and are retained across a consent downgrade and across a later launch with
  the flag off: the cache holds the SDK-minted subject id, the server-minted
  assignment and subject-fact keys, the variant payload, **and the normalized
  targeting attributes the assignment was evaluated under** — so
  user-specific values your game passes to `fetch_experiment_assignment` are
  written to disk; the clear marker holds a timestamp plus the record scope
  (workspace, environment, subject id, base URL, and a non-secret hash
  fingerprint of the API key — never the key). See
  [docs/privacy.md](docs/privacy.md) for the full at-rest inventory. The identity
  record is written through
  `sys.get_save_file("shardpilot.<workspace_id>.<app_id>", "identity")` with
  `sys.save`/`sys.load`. The per-app namespace prevents two games on one device
  from sharing an anonymous ID or consent state. Outside Defold (e.g. a plain
  Lua test host) it degrades gracefully to in-memory state. `get_anonymous_id()`
  returns the persisted anonymous ID so a host can hand it to its own backend at
  token-mint time (Mode B); the SDK always sends that same anonymous ID on the wire.
- **`set_consent(decision)`** records an explicit decision — `true`
  (granted), `false` (denied), or the string `"denied_forced_minor"` — over
  the states `unknown` (the default), `granted`, `denied`, and
  `denied_forced_minor`; the pipeline is **consent-first**: only
  `granted` transmits. While consent is `unknown`, `track`/`screen_view`/
  `session_start` return `false, "consent_unknown"` and the event is
  **dropped, not held** — nothing is queued or spooled, `flush`/`persist` are
  no-ops, no consent receipt goes out, and runtime samples
  (`observe_ping_ms` / `observe_disconnect` / frame sampling) are dropped at
  the source — a later summary can never carry pre-consent (or
  denied-period) activity. Only a launch that starts with a persisted grant
  loads the offline spool; any non-granted init (denied, unknown, or an
  unreadable identity record) **purges** it instead — a record without an
  affirmative grant behind it cannot be proven to have been written under
  one. A grant opens the pipeline for FUTURE
  events only. An unreadable identity record resolves to `unknown`, so a
  consent-state read failure fails **closed**, for the wire and for data at
  rest alike. `denied` drops events at
  enqueue (`consent_denied`), clears the pending
  queue, discards in-flight batches instead of retrying, and purges the
  offline spool. `"denied_forced_minor"` — the persisted decision for
  age-gate under-threshold players — is treated by every analytics gate
  exactly like `denied` (same refusals, same cleanup, same
  purge-at-every-launch); the one difference is its receipt, which carries
  `reason = "denied_forced_minor"` so the backend per-actor gate can tell a
  band-forced denial from a chosen one. In a forced-minor session the sole
  analytics-plane request on the wire is that receipt POST; a later explicit
  `set_consent` (the band-correction path) supersedes the state normally.
  The decision is
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
  the same authenticated transport; consent never rides the event envelope.
  Every decision becomes exactly one receipt (with its own `idempotency_key`),
  keyed to the **canonical actor** at decision time — the verified `user_id`
  with `kind = "user_verified"` only when a Mode B `token_provider` backs an
  identified session; the SDK-managed `anonymous_id` with `kind = "anon"` in
  every other case (a Mode A self-asserted `user_id` is never the receipt
  actor) — and retained in the **durable consent-receipt outbox** until the
  server acknowledges it, delivered serially, in decision order. The `kind`
  rides the wire body by default (`consent_kind_emission_enabled = false` is
  the escape hatch for pre-amendment ingest deployments — see
  `docs/configuration.md`), and each receipt dispatches under the
  **most-vouching credential**: the minted Mode B token whenever it vouches
  for the receipt's actor (the current verified user, or the current anon
  the mint binds as its subject — so current-anon grants stay deliverable
  in the dual configuration), the publishable `api_key` only for
  historic-anon receipts the token cannot vouch for and in pure Mode A. A
  `user_verified` receipt **parks** while the current session cannot vouch
  for its actor — no `token_provider`, no `identify()` yet, or a different
  user signed in: retained durably, skipped by dispatch and the grant gate,
  delivered verbatim the moment a Mode B session identifies as that actor
  again (`identify()` is a consent dispatch point) — so an undelivered
  verified denial survives signed-out relaunches. Transient
  failures — no token yet (e.g. an async Mode B `token_provider` still in
  flight), a minted-token 401, offline, timeout, `429`, `5xx` — keep the
  receipt and retry at every dispatch point (init/`update`/`flush`/`shutdown`) with
  `Retry-After`/backoff pacing, across launches, until delivered; permanent
  rejections (including a publishable-key 401, classified by the credential
  the dispatch actually used) are dropped and surfaced through the
  `diagnostics` hook (`scope = "consent"`). In a Mode-B-ONLY configuration
  (no publishable key), anon-keyed receipts
  retained under a previous anonymous id are dropped at load like the event
  spool's `identity_changed` rule (each entry keeps a decision-time anon
  snapshot as retention metadata, never sent on the wire) — a minted token
  binds the current identity, so replaying them could only wedge the trail;
  with an `api_key` configured, historic-anon receipts re-send under it
  unchanged. Receipt delivery is
  **consent-plane traffic**: it stays permitted while analytics consent is
  denied or unknown — the receipt documents the decision itself — and the
  outbox never carries analytics events. If the receipt's durable append
  fails while it is still undelivered, `set_consent` returns
  `false, "consent_outbox_persist_failed"` (the decision applied; delivery
  still proceeds and the write retries automatically — including from
  `persist()` even with the event spool disabled). On a **denial-full
  outbox** — 32 retained receipts with no pure grant available to evict —
  `set_consent(true)` is refused with `false, "consent_outbox_full"`:
  the grant is not applied and nothing is evicted (a recorded denial is
  never traded for a grant, and a grant receipt evicted before dispatch
  would open the local pipeline with no grant row ever reaching the
  server); retry once the outbox drains. Denial appends still apply at the
  cap (an all-denials overflow evicts the oldest denial). `shutdown()` completes
  over a durably retained receipt (it re-sends next launch — a receipt still
  in flight at teardown never chains further requests) and returns
  `false, "consent_pending"` only when the receipt could not be durably
  captured — call it again once a token is available or storage recovers so
  the decision is not dropped at exit.
- **Crash reporting is on by default, with a persisted opt-out.** Crash
  reports ride their own plane, independent of analytics consent:
  `crash.set_enabled(false)` persists a per-app opt-out that stops
  COLLECTION — `emit`/`emit_fatal`/`capture_previous`/`resend_pending` return
  `false, "crash_disabled"`, no sidecar entry is written, the breadcrumb ring
  is emptied and refuses new entries, and the
  previous-session native dump stays unread. `crash.is_enabled()` reports the
  state. If the persisted opt-out record cannot be READ (storage error or a
  malformed record — not
  merely absent on a fresh install), the crash client **fails closed** and
  sends nothing until a new `set_enabled` decision is persisted. A disabled
  client still runs the pending sidecar's ~7-day TTL maintenance at init, so
  already-captured reports age out on schedule while the opt-out holds. See
  [`docs/crash.md`](docs/crash.md#opting-out).
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
| `shardpilot/experiments.lua` | Experiment-assignment consumer (off by default): assignment fetch, durable cache, revalidation, exposure/outcome facts |
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
| `test/` | Lua test harness (`test_sdk.lua`, `test_crash.lua`, `test_remote_config.lua`, `test_experiments.lua`) + Defold collection/script |
| `docs/` | configuration · events · crash · privacy · release |
| `scripts/` | `check_library.sh` (content guard), `package_release.sh` |

## Conventions & boundaries

- **No native extension.** No `.c`/`.cpp`/`.mm`/`.java` or Extender references in
  SDK source. The guard greps file *contents* (`grep -RInE`) for these patterns,
  so it flags native references inside tracked files but does not catch a native
  source file added solely by filename — keep the boundary by convention.
- **No durable I/O beyond the enumerated records** (identity, event spool,
  consent-receipt outbox, consent denial marker, crash-retry sidecar,
  crash-reporting settings, remote-config cache, the experiment-assignment
  cache, and the experiment clear marker). The last two are **created** only
  by a run with `experiments_enabled` on — but once created they persist, and
  a later run with the flag **off** still reads the clear marker to filter
  withdrawn experiment facts out of the spool. For a storage or privacy
  audit: the flag gates creation, not the existence or the reading of these
  records.
  `io.*`, `os.execute`, and browser/local storage are forbidden in source;
  `sys.save`/`sys.load`/`sys.get_save_file` are confined to
  `shardpilot/storage.lua`, which writes only the identity record, the bounded
  offline event spool, the bounded consent-receipt outbox, the small
  write-ahead consent denial marker, the bounded, TTL'd
  crash-retry sidecar, the one-boolean crash-reporting settings record, the
  single bounded remote-config cache record, and the experiment-assignment
  cache record plus its clear marker.
- **No raw/provider/token/billing surface.** Terms like `raw_payload`, `prompt`,
  `access_token`, `github_token`, `billing` must not appear in SDK or example
  source.
- The README itself is **content-guarded** by `scripts/check_library.sh` (it
  requires the wire-contract line above). Run the guard after editing docs:
  ```bash
  ./scripts/check_library.sh
  lua5.1 test/test_sdk.lua
  ```

## Compatibility

- **Engine:** Defold (uses `sys`, `http.request`); degrades to in-memory
  identity state when `sys` is absent, and dispatch returns `http_unavailable`
  when `http.request` is absent.
- **Lua runtime:** Defold's embedded runtime is LuaJIT / Lua 5.1-compatible;
  write SDK source against Lua 5.1 language features so it runs in-game.
- **Test runner:** CI runs the test suite under `lua5.1` and `luajit` as the
  gating interpreters (matching Defold's embedded runtime), plus `lua5.4` as an
  extra host-only leg; when validating locally, run the tests under Lua 5.1 or
  LuaJIT and avoid Lua 5.2+ syntax or APIs that would fail inside the engine.
- **License:** Apache-2.0.

## Roadmap

Planned / deferred (not yet implemented):

- Provision the public ingest domain and publish a hosted Defold dependency URL.
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
