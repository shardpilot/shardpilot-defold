---
name: shardpilot-defold-integration
description: Use when integrating the ShardPilot Defold SDK into a Defold game — install, credentials, init, the consent-first analytics contract, remote config, crash reporting, offline durability, and how to verify the integration works.
---

# ShardPilot Defold SDK integration

This skill is the fast, contract-correct path to integrating `shardpilot-defold`
(the pure-Lua Defold SDK for ShardPilot analytics, remote config, and crash
reporting) into a Defold game. Every behavioral claim below is written from the
SDK source in this repository. When this skill and the code disagree, the code
wins — and the README plus `docs/` (configuration, events, crash, privacy) are
the deeper reference.

## What the SDK does today (honest scope)

- **Analytics events**: buffers app-first events in a bounded in-memory queue
  and batches them to `POST {ingest_url}/v1/events:batch` over Defold's
  `http.request`. JSON in, per-event outcomes surfaced back. No native
  extension — pure Lua source, written against Lua 5.1/LuaJIT (Defold's
  embedded runtime).
- **Consent-first pipeline**: nothing transmits until an explicit consent
  grant; see the consent section — it is the part most integrations get wrong.
- **Offline durability**: a bounded per-app durable event spool re-sends
  undelivered events on a later launch; consent receipts have their own
  durable outbox.
- **Remote config**: explicit `GET`-based fetch with an ETag-revalidated
  durable last-known-good cache and typed getters. No experiments/assignment
  API, no automatic refresh.
- **Crash reporting**: a separate `shardpilot.crash` module posting crash
  report JSON to a dedicated crash ingest endpoint, with PII scrubbing,
  write-ahead pending storage, and deterministic non-fatal sampling.
- **Not provided today**: no automatic capture of live Lua script errors (you
  wire your own error handler and call `crash.emit_fatal`), no experiment
  assignment endpoint, no automatic remote-config refresh, no packaged release
  ZIP assets (source archives only).
- **Pre-launch**: the production ingest domain is not provisioned yet; use
  local/develop endpoints. The SDK is v0 alpha and the API may change before
  v1.

## Install

Version pin (CI-checked): this skill matches shardpilot-defold `v0.9.1`.

Two supported paths:

1. **Vendor the `shardpilot/` directory** into your project. Copy the whole
   directory; it is self-contained Lua source. (This repo's
   `[library] include_dirs = shardpilot` line in `game.project` exists to
   expose the folder to dependency consumers — you do not need it in your own
   game when vendoring.)
2. **Pin a Defold library dependency** to a published tag's source archive:

```ini
[project]
dependencies#0 = https://github.com/shardpilot/shardpilot-defold/archive/refs/tags/v0.9.1.zip
```

The `v0.9.1` tag is published and that source-archive URL resolves; it is the
same pin the README's Installation section carries. Note there is no packaged
ZIP asset attached to any GitHub Release — the tag source archive is the only
hosted dependency URL. Pin a tag rather than tracking `main` so your build
does not shift under you between releases.

Then:

```lua
local shardpilot = require "shardpilot.sdk"
local crash = require "shardpilot.crash" -- only if you use crash reporting
```

## Credentials

Two analytics auth modes; configure **exactly one** (plus one exception below):

- **Mode A — `api_key`**: the publishable `sp_ingest_…` ingest key. It is
  **non-secret by design** — safe to embed client-side, used directly as the
  `Bearer`, never expires. This is the normal choice for a shipped game
  client. One platform-side limit matters for consent: a publishable key can
  record consent **denials** but not **grants** — see the consent section.
- **Mode B — `token_provider`**: an async function yielding a short-lived
  per-tenant **ingest JWT minted by your backend** (your backend holds the
  signing secret and binds the token to the current anonymous ID). Use this
  when you want per-player, revocable ingest credentials. Signature:
  `token_provider = function(callback) callback(token, expires_at_unix_ms, err) end`.
  The SDK handles refresh lead, expiry, and 401-remint.

Rules enforced at `init`: both configured → `auth_mode_conflict`; neither →
`auth_required`. **Exception**: remote config authenticates with the
publishable `api_key` only (a Mode B ingest JWT is scoped to event ingest and
is rejected there), so with `remote_config_url` set you must supply `api_key`
even in Mode B (`remote_config_api_key_required` otherwise) — the one valid
both-credentials configuration.

Crash reporting uses a separate **`crash:write` API key** (`crash_api_key`),
used directly as the `Bearer` on the crash endpoint.

**Never hardcode secrets** in game code or the game repo. The publishable
`sp_ingest_…` key is the only credential designed to ship inside the client.
The Mode B signing secret lives on your backend only — never in the game.
Inject real key values from your build pipeline or a non-committed config;
in committed code use placeholders like `<YOUR-PUBLISHABLE-INGEST-KEY>`.
Tokens are memory-only in the SDK — auth material is never written to disk.

## Init

```lua
local ok, err = shardpilot.init({
  ingest_url     = "<YOUR-INGEST-BASE-URL>",   -- https required outside localhost; no path/query
  workspace_id   = "<YOUR-WORKSPACE-ID>",
  app_id         = "<YOUR-APP-ID>",
  environment_id = "develop",
  api_key        = "<YOUR-PUBLISHABLE-INGEST-KEY>", -- Mode A (or token_provider for Mode B)
  -- remote_config_url = "<YOUR-REMOTE-CONFIG-BASE-URL>", -- optional; requires api_key
  -- app_version = "1.2.3", app_build = "456",
  -- diagnostics = function(issue) print(issue.scope, issue.status, issue.code) end,
})
```

Required: `ingest_url`, `workspace_id`, `app_id`, `environment_id`, and one
auth credential. `init` returns `true`, or `false, err` with a specific code
(`ingest_url_required`, `invalid_ingest_url`, `auth_required`,
`auth_mode_conflict`, `remote_config_api_key_required`, …). Useful defaults:
`batch_size = 25` (1–100), `buffer_size = 1000`, `flush_interval_seconds = 1`,
`publish_timeout_seconds = 2`, `spool_enabled = true`,
`spool_max_events = 500`, `spool_max_bytes = 262144` (max 393216).

Wire the frame loop and teardown:

```lua
function update(self, dt) shardpilot.update(dt) end  -- drives flush timer + frame sampling
function final(self)      shardpilot.shutdown("app_final") end
```

Identity: a UUIDv7 `anonymous_id` is generated and persisted per app on first
init; `shardpilot.identify(user_id)` upgrades attribution. Identifiers are
capped at 512 bytes — oversized values are **rejected**
(`invalid_user_id` / `invalid_anonymous_id`), never truncated. The optional
`diagnostics` hook is the SDK's push-side observability surface: it receives
issue tables with `scope = "event" | "batch" | "consent" | "spool"`.

## The consent-first contract (as implemented here)

This SDK implements the ShardPilot consent-first contract in full. Integrate
it exactly as below; the failure modes are silent data loss or compliance
bugs.

- **Four persisted states**: `unknown` (default) / `granted` / `denied` /
  `denied_forced_minor`. Record decisions with
  `shardpilot.set_consent(true | false | "denied_forced_minor")`.
- **Unknown = drop.** Until an explicit grant, every
  `track`/`screen_view`/`session_start` call returns
  `false, "consent_unknown"` and the event is **dropped, not held** — nothing
  is queued, nothing is spooled, zero analytics wire traffic. A grant opens
  the pipeline for FUTURE events only; there is no pre-consent buffering.
  After a denial the same calls return `false, "consent_denied"`. Runtime
  samples (`observe_ping_ms`, `observe_disconnect`, frame sampling) are
  dropped at the source while the pipeline is closed.
- **Grant-only spool.** Only a launch that starts with a persisted **grant**
  loads the offline event spool. Any non-granted init (denied, unknown, or an
  unreadable identity record) **purges** the spool without sending. A failed
  purge fails closed: the spool stops accepting/loading/re-sending, and
  `set_consent(true)` is refused (`false, "spool_purge_failed"`) until the
  purge lands — a grant never resurrects pre-revocation data.
- **Durable consent-receipt outbox.** Every explicit decision becomes exactly
  one receipt, retained in a durable per-app outbox (at most **32 entries**,
  oldest evicted first) until the server acknowledges it. Delivery is
  automatic — serial, oldest first, in decision order, retried with
  `Retry-After`/backoff pacing at every dispatch point
  (init/`update`/`flush`/`shutdown`) and across launches. You never deliver
  receipts yourself and there is no receipt endpoint to call: recording the
  decision with `set_consent` is the entire integration surface. Receipt
  delivery is consent-plane traffic — it stays permitted while analytics
  consent is denied or unknown, because the receipt documents the decision
  itself.
- **Grants need a trusted credential (platform rule).** The ingest service
  records **denial** receipts — `set_consent(false)` and the forced-minor
  denial alike — from the publishable Mode A key, but a **grant** receipt
  posted with a publishable key is rejected `403` (detail code
  `consent_grant_requires_verified_credential`) and, like every non-transient
  rejection, terminally dropped from the outbox: a public key cannot vouch
  for a grant. Grants are recorded server-side only through a trusted
  backend credential (the Mode B path, or your backend's own service-side
  consent write). `set_consent(true)` still opens the **local** pipeline in
  Mode A, but on a workspace that enforces server-side consent the server
  keeps answering that actor's events with per-event `suppressed_no_consent`
  until a trusted-path grant lands — plan your grant recording accordingly.
- **Receipts before batches.** On each flush cycle, retained receipts are
  handed to the transport strictly **before** that cycle's event batch —
  sequencing (handoff order) only; the batch never waits for the receipt's
  acknowledgment. While an analytics **grant** receipt is still awaiting its
  handoff, `flush()` holds the event batch and returns
  `false, "consent_receipt_pending"` — expected and self-resolving on the
  next dispatch; do not treat it as an error.
- **AC-8 / `denied_forced_minor`.** For age-gate-forced denials (under-age
  players), record `set_consent("denied_forced_minor")`. Analytics-wise it is
  identical to `denied` (drop + purge + zero analytics egress); the receipt
  alone carries `reason = "denied_forced_minor"` so the backend can tell a
  band-forced denial from a chosen one. In a forced-minor session the **only**
  analytics-plane wire request is that denial receipt. This Defold SDK is
  currently the only ShardPilot SDK implementing AC-8 — do not assume it on
  the other SDKs.
- **Feature detection.** `shardpilot.supports(capability)` works before
  `init()` and returns `false` for unknown names on older and newer SDKs
  alike. Keys today: `"consent_receipt_outbox"`,
  `"consent_state_denied_forced_minor"`, `"schema_revision_declaration"`.
  Gate new call shapes on it:

```lua
if shardpilot.supports("consent_state_denied_forced_minor") then
  shardpilot.set_consent("denied_forced_minor")
else
  shardpilot.set_consent(false)
end
```

`set_consent` returns `true`, or `false` with a code — and whether the
decision applied depends on the code. On `consent_persist_failed` (the durable
identity write failed — call again to retry) and
`consent_outbox_persist_failed` (receipt not yet durably captured; the write
retries automatically) the in-memory decision DID apply.
`spool_purge_failed` is two-sided: on a **denial** it means the denial applied
but the durable spool purge is still owed (retried automatically at later
dispatch points); on a **re-grant** it means the grant was **not** applied —
the persisted state stays denied until the purge lands — so retry
`set_consent(true)` and do not proceed as if granted.

## Sending analytics events

```lua
shardpilot.set_consent(true)                    -- prerequisite: nothing flows before this
shardpilot.session_start()                      -- emits app.session_started
shardpilot.screen_view("menu")                  -- emits app.screen_view
shardpilot.track("play_cta_click", { cta_source = "main_menu" })
shardpilot.observe_ping_ms(42)                  -- feeds network_summary
```

- Every send-side call returns `ok, err`. `track` failure codes:
  `consent_unknown`, `consent_denied`, `event_name_required`,
  `identity_required`, `invalid_props`, `invalid_context`, `queue_full`,
  `shutdown`.
- Batches dispatch when the queue reaches `batch_size` or every
  `flush_interval_seconds`, driven by `update(dt)`; `flush()` forces a cycle.
  A session is opened lazily on the first `track` if you never called
  `session_start` (the server requires a `session_id` for client sources).
- `persist()` snapshots undelivered events into the durable spool without
  sending — call it from your window focus-lost/iconify listener.
- `shutdown(reason)` runs a final flush; with the spool enabled it returns
  `true` once everything is delivered **or durably spooled** (re-sent next
  launch). `false, "consent_pending"` means a consent receipt could not be
  durably captured — retry `shutdown` (keep pumping so async HTTP callbacks
  can settle).
- A `schema_revision_mismatch` batch rejection (HTTP 409 with that error
  code) is terminal: the batch is dropped, never retried. Fix by updating the
  SDK (re-sync `shardpilot/schema_revision.lua`) or setting
  `schema_revision = false` to stop declaring.

## Remote config

Explicit fetch only — the SDK never fetches on its own; there is no automatic
or interval refresh. The fetch is
`GET {remote_config_url}/config/v1/{workspace_id}/{environment_id}/{client_id}`
(the `/config/v1/` plane, a separate service from ingest), authenticated with
the publishable `api_key`, ETag-revalidated, and **not consent-gated**
(configuration delivery carries no analytics payload; `client_id` is the
persisted anonymous ID and only scopes which config to serve).

```lua
shardpilot.fetch_remote_config(function(result)
  -- result = { ok, from_cache, error?, values?, version? }
end)
local spawn_rate = shardpilot.remote_config_number("spawn_rate", 1.0)
local motd       = shardpilot.remote_config_string("motd", "")
local hard_mode  = shardpilot.remote_config_boolean("hard_mode", false)
```

Semantics to rely on: 200 serves fresh values and overwrites the durable
cache; 304 serves the cache (`from_cache = true`); transient failures
(offline, 408, 429, 5xx, malformed body) serve the last-known-good cache with
`error` set; **401/403 fail closed** (`error = "unauthorized"`, cache not
served); any other status is a permanent failure (`http_<status>`). Typed
getters never touch the network and serve the caller's default until config is
available; the last-known-good snapshot survives restarts and offline
launches. `remote_config_version()` reads the response wrapper's `version`
metadata.

## Crash reporting

Crash reporting is a **separate module with separate init and credentials** —
crashes are never wrapped as analytics events, and analytics consent does not
gate them.

```lua
local crash = require "shardpilot.crash"
crash.init({
  crash_ingest_url = "<YOUR-CRASH-INGEST-BASE-URL>", -- base URL only; route appended by the SDK
  crash_api_key    = "<YOUR-CRASH-WRITE-KEY>",       -- crash:write scope
  app_id           = "<YOUR-APP-ID>",
  app_version      = "1.2.3",
})
crash.capture_previous()  -- once, early in init(): forwards last session's native dump, if any
crash.record_breadcrumb("menu.open")
```

- Reports go to `POST {crash_ingest_url}/api/v1/crashes/ingest` as a crash
  report JSON body (`crash_id` UUIDv7, `occurred_at`, `exception`,
  `threads[]`/`frames[]`, `breadcrumbs[]`, …). Lua-level errors use
  pre-symbolicated frames (`function`/`file`/`line`); native dump frames are
  resolved server-side.
- **Legitimate-interest posture with a persisted opt-out.** Crash reporting is
  ON by default (no first-run decision needed). `crash.set_enabled(false)`
  persists a per-app opt-out that stops **collection**, not just sending:
  `emit`/`emit_fatal`/`capture_previous`/`resend_pending` return
  `false, "crash_disabled"`, nothing is written, the breadcrumb ring is
  emptied and refuses entries, and the previous-session dump stays unread. If
  the persisted opt-out record cannot be read (or is malformed), the client
  **fails closed** — disabled until a new `set_enabled` decision persists.
  `crash.is_enabled()` returns `enabled, reason`
  (`"opt_out" | "settings_read_failed" | "not_initialized"`).
- **Fatal is never sampled**; non-fatal `emit` is sampled deterministically
  1-in-N (`sample_every`, default 10 — the first N−1 non-fatals of a process
  are dropped; set `1` or a custom `sampler` to send every one).
- **Write-ahead durability (best-effort)**: before its send attempt, every
  dispatched report is persisted to a bounded per-app pending sidecar
  (8 records / 64 KB each / 384 KB total, ~7-day TTL) and re-sent
  byte-identical on a later launch until acknowledged (de-duplicated by
  `crash_id`). When that durable write fails (storage quota/failure, an
  oversized body, or a host without the save-file API), the report is
  retained only in a bounded in-session memory fallback — still dispatched
  and retryable in-session, but it does **not** survive process death;
  `crash.snapshot().persist_failed` counts these.
  `crash.capture_previous()` runs a resend pass; `crash.resend_pending()`
  retries later in-session.
- **No automatic Lua script-error capture**: wire your own error handler (e.g.
  Defold's `sys.set_error_handler`) and call `crash.emit_fatal` with an
  `exception` + pre-symbolicated frames yourself.

## Offline / spool expectations

- Enabled by default (`spool_enabled = true`). Bounded: `spool_max_events`
  (default 500) and `spool_max_bytes` (default 256 KB, hard max 384 KB under
  the engine's 512 KB save-record cap); over a cap the **oldest** entries are
  evicted first.
- Spooled on: transient publish failures (offline, timeout, 429, 5xx, Mode B
  401), the undelivered remnant at `shutdown()`, and explicit `persist()`
  snapshots. Permanent rejects are never spooled.
- Resend on the next launch: verbatim envelopes (original `event_id` +
  `event_ts`, so the server de-duplicates), chunked to `batch_size`, before
  fresh events, through the same token/consent/backoff gates. Entries leave
  the spool on server acknowledgment (ack-based, keyed by `event_id`).
- A `429 Retry-After` deadline persists with the record and is honored across
  relaunch (clamped to 24 h).
- Consent rules override durability: denied purges the spool; only a
  granted launch loads it (see the consent section).
- On hosts without Defold's save-file API the spool falls back to process
  memory and `shutdown()`/`persist()` honestly report `false` rather than
  claiming durability.

## Verify your integration

Run this checklist in-game (or in a host with `http.request` available)
against a reachable ingest endpoint. Every observation below is the SDK's real
surface — no guessing from logs.

1. **Init**: `shardpilot.init(cfg)` returns `true`. A `false, err` here is a
   config mistake; the `err` code names the field.
2. **Consent-first sanity**: before any grant, `shardpilot.track("t")` returns
   `false, "consent_unknown"` — if it returns `true`, you are not on the
   consent-first pipeline you think you are.
3. **Grant**: `shardpilot.set_consent(true)` returns `true`.
4. **Emit a test event**: `shardpilot.track("integration_test", { ok = true })`
   returns `true` (enqueued).
5. **Deliver**: keep calling `shardpilot.update(dt)` from your script's
   `update` (or call `shardpilot.flush()`); HTTP is async, so completion lands
   on a later frame. `flush()` returning `false, "pending"` (batch in flight)
   or `false, "consent_receipt_pending"` (grant receipt awaiting handoff) is
   normal mid-cycle; `true` means the pipeline is drained.
6. **Confirm acceptance** via `local s = shardpilot.snapshot()` (a copy of the
   client counters):
   - `s.enqueued` ≥ 1, `s.published` ≥ 1, and **`s.accepted` ≥ 1** — the
     server 202 body is parsed per event, so `accepted` counts events the
     server actually accepted, not just batches sent.
   - In Mode B, `s.consent_recorded` ≥ 1 once the grant receipt is
     acknowledged. In Mode A do **not** expect that for a grant: the platform
     accepts only denial receipts from a publishable key, so the grant
     receipt is terminally rejected (surfaced via the `diagnostics` hook,
     `scope = "consent"`) and the grant must be recorded server-side through
     your backend (see the consent section).
   - Nonzero `s.rejected` / `s.suppressed` / `s.duplicates` mean per-event
     problems: check `s.last_event_issue` (a `status:code` string) and the
     `diagnostics` hook (`scope = "event"`, e.g. status
     `suppressed_no_consent` on a strict-consent workspace whose grant
     receipt has not landed server-side yet).
   - `s.last_error` holds the last transport/server error
     (e.g. `unauthorized`, `http_0`, `transient_429`) — `unauthorized` in
     Mode A means a wrong/revoked publishable key and is terminal for the
     batch.
7. **Remote config** (if configured): `fetch_remote_config(cb)` calls back
   with `result.ok = true` and your published `values`; a second fetch
   typically serves the ETag-revalidated cache (`from_cache = true`).
8. **Crash plane** (if configured): `crash.emit_fatal({ exception = { type =
   "lua_error", reason = "integration test" }, threads = { { id = "main",
   crashed = true, frames = { { ["function"] = "test.verify" } } } } })`
   returns `true`; then `crash.snapshot()` shows `emitted` ≥ 1 and, after the
   async callback, `accepted` ≥ 1 (`suppressed` counts reports the server
   accepted but did not store; `last_error`/`last_issue` name failures).
9. **Offline durability**: go offline, `track` a granted event, kill the app
   (or call `persist()` first), relaunch, come back online — `snapshot()`
   shows `spool_resent` ≥ 1 and the event arrives with its original
   `event_id`.
10. **Shutdown**: `shardpilot.shutdown("app_final")` returns `true` (or
    retry it while pumping `update`; see the shutdown notes above).

## Known limitations (2026-07-19 audit)

Stated plainly so integrations do not trip on them:

- **No engine-real CI leg**: CI runs the test suite under host Lua
  interpreters (Lua 5.1 and LuaJIT as the gating legs, matching Defold's
  embedded runtime, plus Lua 5.4 host-only). No CI job builds the SDK inside
  the Defold engine/bob toolchain — the in-engine build check is a manual
  release step, so validate your integrated game in the engine yourself.
- **No Lua script-error auto-capture**: the crash module forwards
  previous-session native dumps and accepts manual `emit`/`emit_fatal`, but
  live Lua errors are only reported if you wire your own error handler.
- **Pre-launch platform**: no production ingest domain is provisioned; the
  hosted docs site is not live yet. Use local/develop endpoints and the
  in-repo `docs/` as the reference.
