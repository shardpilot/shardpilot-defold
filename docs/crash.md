# Crash reporting

The ShardPilot Defold SDK reports crashes to a **dedicated crash ingest
endpoint**, separate from analytics events. A crash report is **never** wrapped
as a `mobile_crash` analytics event — it is a crash report JSON body, sent to:

```
POST {crash_ingest_url}/api/v1/crashes/ingest
Authorization: Bearer <crash:write API key>
Content-Type: application/json
```

The module lives under `shardpilot/crash/` and is loaded with
`require "shardpilot.crash"`. It has its own client, config, and ingest URL,
independent of the analytics client.

## Configuration

```lua
local crash = require "shardpilot.crash"

crash.init({
  crash_ingest_url = "https://crashes.example.com", -- crash ingest base URL
  crash_api_key    = "sp_crash_...",                -- a crash:write API key
  app_id           = "app-example",                  -- must match the key's app scope
  app_version      = "1.4.2",
  app_build        = "4201",
  crash_source     = "game-client",                  -- component slug (optional)
  -- sample_every      = 10,  -- every-Nth NON-fatal is sent (deterministic counter; fatal always sent)
  -- publish_timeout_seconds = 30,
  -- sampler = function(event) return true end,       -- custom NON-fatal sampler
  -- diagnostics = function(issue) ... end,            -- per-report failure hook
})
```

| Key | Required | Meaning |
| --- | --- | --- |
| `crash_ingest_url` | yes | The crash ingest **base** URL (no path/query/fragment). `https` is required outside loopback. The `/api/v1/crashes/ingest` route is appended by the SDK. |
| `crash_api_key` | yes | A `crash:write` API key, used directly as the `Bearer` credential. |
| `app_id` | yes | App/project scope; must match the API key's app scope. A product slug such as `user_app` or `customer_portal` is fine; a value carrying real PII (an email, an IP, a token, a digit-bearing raw actor id) fails `crash.init` with `invalid_app_id`. |
| `app_version`, `app_build` | no | Defaulted onto every report. |
| `platform` | no | Auto-detected from `sys.get_sys_info` (`ios`/`android`/`windows`/`macos`/`linux`/`web`). Set it explicitly when running outside Defold or on an unrecognized system; if it is neither configured nor auto-detectable, `crash.init` fails with `platform_required` rather than returning a client that can never send a report. |
| `crash_source` | no | The component slug (see below). |
| `sample_every` | no | Every-Nth sampling for **non-fatal** reports (default 10): a deterministic per-process counter transmits calls N, 2N, 3N, … — the first N−1 non-fatals of a process are always dropped, so a process emitting fewer than N non-fatals in its lifetime reports none (set `1` to send every one). Fatal reports are **never** sampled. |
| `publish_timeout_seconds` | no | Per-request timeout (default 30). |
| `sampler` | no | A custom `function(event) -> boolean` for non-fatal reports. A fatal report bypasses it. |
| `diagnostics` | no | A hook invoked with `{ scope, status, code, retryable, response }` when a report is rejected or unauthorized. |

### The `source` component slug

`crash_source` is the **component slug** within the app: the game client vs each
backend service, so a multi-repo product attributes crashes per component under
one app id. It is stamped on **every** report and is part of the server-side
crash group key.

This mirrors how the analytics SDK's `source` is configured (a config field
defaulted onto every event), but the **value space is different**: the crash
`source` is a lowercase DNS-style slug — `^[a-z0-9][a-z0-9-]{0,62}$`, max 63
chars — **not** the analytics `client` / `server` / `backend` enum.

- Omit it (or set `""`) for a **bare app** with no component dimension — the
  field is then absent from the wire.
- A per-report `source` (passed in the event table) overrides the configured
  default.
- The slug is validated **before** it reaches the wire; an invalid value is
  rejected.

## Manual emit

Build an event table and emit it. `emit` is subject to sampling; `emit_fatal` is
**always** sent.

```lua
crash.emit_fatal({
  exception = { type = "lua_error", reason = tostring(err) },
  threads = {
    {
      id = "main",
      crashed = true,
      frames = {
        { ["function"] = "game.update", file = "game/update.lua", line = 42 },
      },
    },
  },
})
```

Two frame shapes are accepted:

- **Pre-symbolicated** — a frame with a `function` (and optional `file`/`line`),
  no native module/address. This is the natural shape for a Lua-level error. No
  `modules` are required.
- **Native** — a frame with an `instruction_addr` (`0x…` hex), resolved
  server-side against a `modules` map. At least one module must be present; a
  per-frame module reference is optional (the server records `module_missing`
  when it cannot attribute an address).

### Breadcrumbs

```lua
crash.record_breadcrumb("menu.open")
```

Up to 50 most-recent breadcrumbs are attached to the next report (a bounded
ring; the oldest are dropped on overflow). Names are scrubbed and must match
`^[A-Za-z][A-Za-z0-9_.:-]{0,127}$`; a name carrying disallowed content is
dropped.

## Fatal reports are never sampled

A fatal crash is reported **every time**, regardless of `sample_every` or a
custom `sampler` — `emit_fatal` (and the dump-forward path) bypass the sampler
entirely. Only `emit` (non-fatal) is sampled, and the default sampler is
**deterministic, not probabilistic**: a per-process counter transmits every
Nth call (10th, 20th, … at the default), so the first N−1 non-fatals of any
process are always dropped. A sampled-out `emit` looks exactly like a sent
one at the call site; supply a custom `sampler` (e.g. `function() return
true end`) to transmit every non-fatal.

## Opting out

Crash reporting is **on by default** — it exists to keep the game working and
needs no first-run decision — with a persisted, per-app opt-out:

```lua
crash.set_enabled(false)        -- persists the opt-out (per app)
local on, reason = crash.is_enabled()
crash.set_enabled(true)         -- back to the default
```

- **Disabling stops collection, not just sending.** While disabled, `emit`,
  `emit_fatal`, `capture_previous`, and `resend_pending` all return
  `false, "crash_disabled"`; no report is prepared, nothing is written to the
  pending sidecar, and the previous-session native dump is left **unread**
  (reading it would consume the engine's one-shot store — it stays available
  for a later enabled launch). The breadcrumb ring is emptied at the flip and
  `record_breadcrumb` refuses new entries while disabled — retained
  breadcrumbs would otherwise attach to the first report after a re-enable.
  The already-persisted pending backlog is
  neither loaded nor re-sent; it stays on disk under its ~7-day TTL — which a
  disabled client still enforces with a maintenance read at every
  `init`/`new` (expired entries are pruned from disk while the opt-out
  holds) — and
  re-sends only if crash reporting is re-enabled within that window.
- **The decision persists across launches** in a small per-app settings
  record (`crash_enabled`), stored alongside the pending sidecar. A new
  client for the same app honors it at `init`/`new` time.
- **A read failure fails closed.** An ABSENT record (a fresh install) applies
  the default — enabled. A record that cannot be READ (a thrown `sys.load`, a
  corrupt file) — or that loads carrying a malformed, non-boolean
  `crash_enabled` — is a different thing: the player may have opted out, so
  the
  client starts **disabled** and sends nothing; `is_enabled()` then returns
  `false, "settings_read_failed"`. A later explicit `set_enabled(...)`
  rewrites the record and recovers the client (a `set_enabled` whose durable
  write FAILED never seeds the in-process fallback, so a fail-closed state
  cannot be reopened by an unpersisted decision).
- **A failed persist is surfaced.** `set_enabled` applies the decision in
  memory for this session either way; when the durable write fails it returns
  `false, "crash_persist_failed"` — call it again to retry, otherwise the
  decision can be lost on restart.
- The opt-out is independent of the analytics consent state: the two planes
  are configured, stored, and gated separately.

## Auto-capture: previous-session native crash dump

**A native engine crash in Defold (SIGSEGV/SIGABRT) is not recoverable in
Lua** — the process is already dead, so there is no in-process hook to run.
Defold instead writes a native crash dump to
disk through its built-in [`crash`](https://defold.com/ref/stable/crash/)
module, which the **next launch** reads.

The Defold auto-capture model is therefore **load-on-next-launch**. Call
`capture_previous()` once, early in `init()`:

```lua
function init(self)
  crash.init({ ... })
  crash.capture_previous() -- forward a prior-session native crash, if any
end
```

`capture_previous()`:

1. Calls `crash.load_previous()` (one-shot — the dump is removed from disk on a
   successful load).
2. Reads the backtrace (`crash.get_backtrace`), module list
   (`crash.get_modules`), signal (`crash.get_signum`), and OS sys-fields, and
   builds a **native** crash event: `instruction_addr` frames + a `modules`
   map. The prepared report is persisted **write-ahead** (see *Durability*
   below) and QUEUED as a fatal report (never sampled) behind any older
   pending backlog.
3. Runs **one serial resend pass** covering the older backlog and the
   just-queued dump, oldest first — crash reports get the first shot at the
   network, before the host typically starts analytics traffic, and one
   report at a time so server backpressure can stop the pass. (When there is
   no new dump, the pass still runs for the pending backlog.)

Return value: `(true, true)` when a dump was found and durably queued for the
pass, `(true, false)` when there was no dump, `(false, err)` on a forward
failure.

### Limits of native dump forwarding

- **No per-frame module attribution.** The engine exposes a flat backtrace and a
  separate module list; frames carry an address but no module reference. The
  server resolves each address against the module map (recording
  `module_missing` where it cannot disambiguate).
- **No debug IDs.** The engine's module list has a name and a load address but no
  debug/build ID, so the module name is sent as the stable reference. Symbolication
  quality depends on the server having matching symbol files.
- **No breadcrumbs from the dead session.** Breadcrumbs recorded before a native
  crash are lost with the process; only the next session's breadcrumbs attach to
  manual reports.
- **A dump with a backtrace but no module map is dropped** — it is not
  symbolicatable and would be an unresolvable report.
- **Platform-dependent.** Capture depends on the native dump writer being
  available on the platform/build. Where it is not, manual `emit` / `emit_fatal`
  still work.

## Durability: the pending-crash sidecar

Every report that reaches dispatch — a live `emit_fatal`, a sampled-in
`emit`, a dump forward alike — is persisted **write-ahead** to a small,
bounded per-app sidecar (a `sys.save` file) **before** its send attempt: the
process may die during the send, the network may be down, and a dump-sourced
report is a consumed one-shot with no other copy. What is stored is the exact
**encoded wire body** (already PII-scrubbed; auth material is never part of
the body), so a later resend is **byte-identical** to the original attempt and
the crash ingest service de-duplicates it by the stable `crash_id` embedded in
the body.

- **Settlement.** An entry is removed as soon as its send is **accepted**
  (2xx — including an accepted-but-suppressed report) or **terminally
  rejected** (a non-retryable 4xx that would fail forever). A retryable
  failure — offline, `429`, `5xx` — leaves it persisted.
- **Resend: one at a time, oldest first.** `capture_previous()` (and a manual
  `resend_pending()`) runs a serial pass: the next report is dispatched only
  from the previous one's settlement, so a `429`/`Retry-After` stops the whole
  pass instead of racing every pending report into backpressure. Delivered
  reports leave the sidecar as the pass advances — an app kill mid-pass loses
  nothing and a partial delivery resumes on the next launch. A server
  `Retry-After` is stored with the sidecar (clamped to one day; a spent or
  absurd stored deadline self-cleans) so the backpressure window survives a
  relaunch; while it holds, the pass defers and the deadline is surfaced via
  `snapshot().resend_deferred_until_ms`. An accepted send clears the window.
- **Bounds.** At most **8 reports**, each at most **64 KB** encoded, at most
  **384 KB** total (Defold documents a 512 KB `sys.save` cap; the budget stays
  well under it). When a bound is exceeded the oldest **non-fatal** reports
  are evicted first; the oldest **fatal** report is evicted only to admit
  another FATAL one — a sidecar full of fatal reports REJECTS a non-fatal
  newcomer outright (it falls to the session-only memory retention) rather
  than displacing a fatal crash, and the report being saved is never the one
  evicted. A report whose body alone exceeds the per-record cap is rejected
  up front without evicting anything. Entries older than about seven days
  are discarded on read (a local retention limit).
- **Durable means durable.** `save` returns a removable token only when the
  entry is confirmed written to the durable store. When the durable write
  fails outright (quota, no `sys` API), the report is retained **in memory
  only** for the session — surfaced via `snapshot().persist_failed` — and an
  in-session resend pass can still retry it, but it does **not** survive a
  process restart. Memory fallback is a degradation, never counted as
  durability.
- **Honest limits.** The write-ahead persist runs on the emitting thread at
  emit time; a native engine crash (SIGSEGV) never reaches Lua at all, so live
  emits cannot cover it — that path is covered by the engine's own dump plus
  the next-launch forward above, whose prepared report is persisted before its
  first send. A death inside the small window between `crash.load_previous()`
  consuming the dump and the write-ahead persist landing loses that report —
  the dump is one-shot by engine design.

## Privacy

Every caller-populated string is PII-scrubbed before the wire (matching the Go
SDK rules): no emails, no `player_` / `user_` / `customer_` / `device_`
raw-identifier prefixes, no IPv4/IPv6 literals, and no JWT-shaped dotted tokens.
A frame `function` is a code symbol whether it comes from the native dump path or
a manual caller's frame, so it is always scrubbed as a symbol: a package-qualified
or dotted name (`game.player.update`, `java.lang.RuntimeException`) survives, while
an embedded email/IP, a digit-bearing raw identifier, or a real token still blanks
it. Free-text fields (an exception reason, raw crash text, a breadcrumb message)
get the full, aggressive content scrub instead. A
`context.session_id` carrying disallowed identifier material rejects the whole
report. The `source` slug is scrubbed like any other identifier. Free-text fields
(such as an exception reason, raw crash text, or a breadcrumb message) also have
the username segment of a user-home path (`/Users/<name>/`, `/home/<name>/`,
`C:\Users\<name>\`) replaced with `<redacted>`, keeping the rest of the file path
useful without leaking the OS account name.

The only crash state that leaves memory is the pending-crash sidecar described
under *Durability* — the exact already-scrubbed wire body of a report whose
delivery has not been confirmed yet (the same bytes that go to the server —
nothing rawer, no credentials), local to the device, bounded in count and
size, discarded after about seven days, and removed as soon as the report is
accepted or terminally rejected — plus the one-boolean settings record
described under *Opting out* (the persisted `crash_enabled` decision, nothing
else). Crash reports carry **no actor identity** —
`session_id` / `anonymous_id` / `user_id` / `device_id`-style keys are
stripped from context and metadata maps before the wire — so the persisted
copy carries none either. While crash reporting is disabled no report is
collected at all, and an unreadable opt-out record disables it fail-closed.
