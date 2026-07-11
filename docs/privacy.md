# Privacy And Tokens

ShardPilot Defold SDK v0 keeps tokens in memory only. Client tokens are
memory-only — they are never written to the identity record, the crash-retry
sidecar, or the offline event spool. The live event queue is in-memory; only
undeliverable event envelopes are persisted, to the bounded offline spool
described below (disable with `spool_enabled = false` for a fully
memory-only event path).

Durable storage is namespaced per configured app. The identity record —
the generated UUIDv7 anonymous ID and the analytics consent decision — is
written through
`sys.get_save_file("shardpilot.<workspace_id>.<app_id>", "identity")`
(segments sanitized) with `sys.save`/`sys.load`. The per-app namespace keeps
two games on the same device from sharing an anonymous ID or consent record.
When the Defold `sys` API is unavailable, the record degrades to in-memory
state for the process lifetime.

`set_consent(analytics_granted)` records a tri-state consent decision
{unknown, granted, denied}. The analytics client is **consent-first**: only
an explicit **granted** decision opens the event pipeline.

- **Unknown** (the initial state on a fresh install — and what an unreadable
  identity record resolves to) transmits **nothing**: `track`, `screen_view`,
  and `session_start` return `false, "consent_unknown"` and the event is
  **dropped, not held** — nothing is queued, nothing is written to the
  offline event spool, `flush`/`update`/`persist` are clean no-ops, no
  consent receipt is sent, and runtime samples (`observe_ping_ms`,
  `observe_disconnect`, frame sampling) are dropped at the source so no later
  summary can carry pre-consent activity. There is
  **zero analytics wire traffic** and **no pre-consent data at rest**; a
  storage failure that loses the consent record therefore **fails closed**.
- **Only a launch that starts with a persisted grant loads the offline
  spool.** Any init in a non-granted state — denied, unknown, or an
  unreadable identity record — **purges** the spool record instead: a record
  found without an affirmative grant behind it cannot be proven to have been
  written under one (a pre-consent-first install spooled while "unknown" was
  still open, and an unreadable record may have carried a denial whose purge
  is still owed), so its envelopes are dropped rather than held for a later
  grant.
- **Granted** opens the pipeline for FUTURE events only — events and samples
  dropped while consent was unknown are gone by design.
- **Denied** drops events at enqueue (`false, "consent_denied"`), clears the
  pending queue, discards in-flight batches on completion instead of retrying
  them, and purges the offline spool (see below).

Explicit decisions are reported
fire-and-forget to `POST {ingest_url}/v1/consent` and never ride the event
envelope; a decision made before an auth token is available — or rejected as
unauthorized — is retained (latest decision wins) and retried at the next
dispatch point, and `shutdown` will not tear the client down while a decision
is still waiting on a token. While consent is unknown no receipt exists to
send: the receipt reports an explicit player decision, never the absence of
one.

**Crash reporting is separate from analytics consent.** It is ON by default
(no first-run decision needed) with a persisted per-app opt-out:
`crash.set_enabled(false)` stops collection — not just sending — and is
honored on every later launch (see the crash sidecar section below). If the
persisted opt-out record cannot be **read** (a storage error — as opposed to
cleanly absent on a fresh install), the crash client **fails closed** and
sends nothing until an explicit `set_enabled` decision is persisted again.

- Durable storage is limited to five small, bounded records, all written
  through Defold `sys.save`: the identity record described above, a bounded
  crash-retry sidecar, the crash-reporting settings record (both described
  below), the bounded offline event spool (described below), and the
  remote-config cache (described below). No cookies and no other browser or
  tracking storage.
- All persistence goes through Defold `sys.save` only; on HTML5 builds Defold
  backs `sys.save` with browser storage, still limited to those records.

## Offline event spool

When an event batch cannot be delivered for a transient reason (offline,
rate-limited, or a server error), when undelivered events remain at
`shutdown()`, or when the host calls `persist()`, the event envelopes are
written to a per-app spool so a later launch can re-send them (de-duplicated
by the service on the stable event id). This spool:

- stores only the **event envelopes that were already bound for the wire** —
  the same fields the batch endpoint would have received, nothing extra and
  **never tokens**;
- is **bounded** by both an entry count (`spool_max_events`) and an
  approximate serialized size (`spool_max_bytes`), evicting the oldest
  entries first, so it can never grow without limit;
- is **per-app** (namespaced like the identity record) so two games on one
  device never share a spool;
- **honors consent**: only a launch that starts with a persisted grant loads
  it — ANY non-granted init (denied, unknown, or an unreadable identity
  record) clears it at load without
  sending — the purge runs even when the record cannot be read, so a corrupt
  record is still cleared — and `set_consent(false)` purges it at runtime; a
  denied actor's
  events never linger on disk, and neither do envelopes that cannot be
  proven to have been captured under a grant. Should the durable purge itself fail, the
  failure is reported (`spool_purge_failed`), the spool goes **fail-closed**
  (nothing appended, loaded, or re-sent), and the purge is retried at later
  dispatch points and at the next launch until it lands. Revocation cleanup
  completes **before** a new grant takes effect: `set_consent(true)` is not
  applied while that purge is owed (the persisted decision stays denied), so
  pre-revocation events can never replay under a granted decision;
- is **cleared on acknowledgment** — entries are removed as soon as the
  server accepts their batch, or on a permanent rejection (never retried); a
  failed removal rewrite keeps them marked and retries until storage
  recovers;
- may store a server-requested **backpressure deadline** (a `429`
  `Retry-After` timestamp — no other metadata) so a relaunch does not hammer
  a server that asked for space;
- is **cleared on an identity change under Mode B auth** — envelopes whose
  anonymous ID no longer matches the client's are dropped at load rather than
  re-sent;
- **discards a corrupted record** and starts clean rather than erroring into
  game code;
- goes through Defold `sys.save` only (browser storage on HTML5); and
- can be **disabled** with `spool_enabled = false` — disabling also deletes
  any previously persisted spool record at the next init.

## Crash-retry sidecar

If a previous-session crash report cannot be sent on the next launch because the
network is temporarily unavailable (offline, rate-limited, or a server error),
the prepared report is written to a small, per-app sidecar so it can be resent on
a later launch. This sidecar:

- stores only an **already PII-scrubbed** crash report (the same scrub applied
  before any report leaves the device);
- is **bounded** (a small fixed number of entries, each size-capped) so a
  persistently failing send can never grow the file without limit;
- is **per-app** (namespaced like the identity record) so two games on one
  device never share a queue;
- is **TTL-bounded**: a pending report older than about seven days is discarded
  on read rather than resent;
- is **local to the device** and goes through Defold `sys.save` only (browser
  storage on HTML5);
- is **cleared on success** — an entry is removed as soon as its report is
  accepted or terminally rejected, so it never accumulates; and
- **honors the opt-out**: while crash reporting is disabled, no entry is
  written (reports are not collected at all, not merely unsent — breadcrumbs
  included) and the
  existing backlog is neither loaded nor re-sent — it stays where it is,
  bounded by the ~7-day TTL, which a disabled client still enforces with a
  maintenance read at init (expired entries are pruned from disk even while
  the opt-out holds). Entries captured earlier under an enabled state
  re-send only if crash reporting is re-enabled while they are still within
  the TTL.

## Crash-reporting settings record

Crash reporting is ON by default and needs no first-run decision; an explicit
`crash.set_enabled(false)` persists the opt-out. This record:

- stores only the **boolean opt-out decision** (`crash_enabled`) — no
  identifiers, no payloads, no tokens;
- is **per-app** (namespaced like the pending-crash sidecar) so two games on
  one device never share an opt-out;
- is **fail-closed on read failure**: an absent record on a fresh install
  applies the default (enabled), but a record that cannot be READ (a storage
  error or corruption) — or that loads with a malformed, non-boolean
  decision — disables crash reporting entirely — nothing is
  collected or sent — until a later `set_enabled` call persists a readable
  decision again; and
- goes through Defold `sys.save` only (browser storage on HTML5), degrading
  to in-memory state for the process lifetime outside Defold.

## Remote-config cache

When remote config is enabled (`remote_config_url`), the last successfully
served configuration is kept in one durable per-app record so a restart or an
offline launch still gets the previously fetched values. This cache:

- stores only the **served configuration body and its ETag** — data the server
  sent TO the device — plus the (workspace, environment, client, url) scope
  string it was fetched for and a fetched-at timestamp; **never tokens**, and
  no analytics payload of any kind;
- is **per-app** (namespaced like the identity record) and additionally
  **scope-checked**: a record written for any other workspace, environment,
  client id, or endpoint is never served and is overwritten by the next
  successful fetch;
- is **one bounded record**, overwritten in place — it cannot accumulate;
- is **not consent-gated**: the fetch delivers configuration and carries no
  analytics payload (the anonymous client id in the URL only scopes which
  configuration to serve, e.g. for per-client rollout percentages), so a
  denied analytics consent does not block it or clear the cache — consistent
  across our SDKs; and
- is **never served after an unauthorized fetch outcome**: a `401`/`403`
  fails closed instead of serving the cached snapshot, so a revoked key
  cannot keep supplying configuration.
- No token logging.
- No full event payload logging.
- No anonymous stitching by default.
- No pre-auth publishing by default.
- No provider, model, GitHub, billing, or account-management write calls.
- No automatic actions.

Do not send raw customer/player payloads, raw provider payloads, tokens,
secrets, diffs, patches, code/file/archive content, prompts, completions, or
unsanitized stack/backtrace payloads.

Use HTTPS for non-local production-like URLs. Public production readiness is not
claimed by this source SDK wave.
