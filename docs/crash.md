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
  -- sample_every      = 10,  -- 1-in-N sampling for NON-fatal reports (fatal always sent)
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
| `sample_every` | no | 1-in-N sampling for **non-fatal** reports (default 10). Fatal reports are **never** sampled. |
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
entirely. Only `emit` (non-fatal) is sampled.

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
   builds a **native** crash event: `instruction_addr` frames + a `modules` map.
3. Forwards it as a **fatal** report (never sampled), then releases the dump
   handle.

Return value: `(true, true)` when a dump was found and forwarded, `(true, false)`
when there was no dump, `(false, err)` on a forward failure.

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

Crash state is held in memory only, with one exception: if a previous-session
native crash dump cannot be sent on the next launch because the network is
temporarily unavailable (offline, rate-limited, or a server error), the prepared
report is written to a small, bounded per-app sidecar so it can be resent on a
later launch. The report stored there is already PII-scrubbed (the same scrub
applied before any report leaves the device), the sidecar is bounded (a small
fixed number of entries, each size-capped) and local to the device, and a pending
report older than about seven days is discarded on read (a retention limit). A
sidecar entry is removed as soon as the report is accepted or is terminally
rejected, so it never accumulates.
