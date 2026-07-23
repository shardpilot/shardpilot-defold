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

`set_consent(decision)` records an explicit consent decision — `true`
(granted), `false` (denied), or the string `"denied_forced_minor"` (an
age-gate-forced denial) — over the consent states {unknown, granted, denied,
denied_forced_minor}. The analytics client is **consent-first**: only an
explicit **granted** decision opens the event pipeline.

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
- **The persisted decision belongs to the actor that made it.** A configured
  `anonymous_id` override that replaces a DIFFERENT valid persisted
  anonymous id boots a **fresh identity**: consent starts `unknown`, the
  previous actor's persisted decision is ignored — never applied to the new
  actor, which must decide for itself — the offline spool is purged through
  the standard non-granted init path (a failed purge fails closed under the
  same owed-wipe rule), and the identity rewrite persists the override with
  **no consent state carried over**, so the old decision is not re-recorded
  under the new id. A matching override — or none — restores the persisted
  decision unchanged. The reset is surfaced via the `diagnostics` hook as
  `scope = "consent"`, code `identity_override_changed`. Retained consent
  receipts are unaffected: they document the previous actor's own decisions
  and keep their normal load/delivery rules.
- **Denied** drops events at enqueue (`false, "consent_denied"`), clears the
  pending queue, discards in-flight batches on completion instead of retrying
  them, and purges the offline spool (see below).
- **`denied_forced_minor`** is the band-forced denial the age-gate flow
  persists for under-threshold players. Every analytics gate treats it
  exactly like **denied** — same `consent_denied` refusals, same queue/
  in-flight/spool cleanup, same zero analytics egress on every later launch.
  The one difference is its consent receipt, which carries
  `reason = "denied_forced_minor"` so the server-side per-actor gate can tell
  a band-forced denial from one the player chose. In a forced-minor session
  the **only** analytics-plane request that leaves the device is that receipt
  POST. A later explicit `set_consent` (the age-band-correction path)
  supersedes the state normally. Feature-detect with
  `shardpilot.supports("consent_state_denied_forced_minor")`.

Explicit decisions are reported to `POST {ingest_url}/v1/consent` and never
ride the event envelope. Each decision becomes exactly one receipt —
workspace/app/environment, the actor identifier and its `kind`,
`categories{analytics}`, a `decided_at` stamp, an `idempotency_key`, and
(forced-minor only) the `reason` — retained in the **durable
consent-receipt outbox** (see below) until the server acknowledges it:
receipts survive process death, re-send on later launches, and retry with
backoff until delivered, in decision order.

**The receipt's actor is the canonical actor** (ADR-0222), chosen at
decision time exactly like the event plane binds identity: the verified
`user_id` (`kind = "user_verified"`) only when a Mode B `token_provider`
backs the session and the host has called `identify()`; the SDK-managed
`anonymous_id` (`kind = "anon"`) in every other case. A Mode A
self-asserted `user_id` is never the receipt actor — the publishable key
cannot vouch for it, and the server binds a publishable-key write to the
caller's own anon scope regardless. The `kind` rides the wire body by
default; `consent_kind_emission_enabled = false`
(see `docs/configuration.md`) suppresses the wire field for deployments
whose ingest service still strict-decodes the pre-amendment body — the
kind is still chosen, persisted, and used to pick the dispatch credential.
Credential selection is **most-vouching**: a receipt is sent under the
minted Mode B token whenever that token vouches for the receipt's actor —
the current verified `user_id`, or the current `anonymous_id` the mint
binds as its subject, so a current-anon grant stays deliverable in the
dual `token_provider` + `api_key` configuration — and under the
publishable `api_key` only when the token cannot vouch for it: a
HISTORIC-anon receipt (the key is the one credential that can still carry
it; a historic-anon pure grant takes the documented terminal `403`), and
every anon receipt in pure Mode A. `user_verified` receipts go only under
the minted Mode B token, never a publishable fallback.
`shutdown` tears the client down while receipts are still pending only when
they are safely on disk; otherwise it returns `false, "consent_pending"` so
the host can retry. While consent is unknown no receipt exists to send: the
receipt reports an explicit player decision, never the absence of one.

**Receipt delivery is consent-plane traffic, not analytics.** A receipt is
sent — and a retained receipt keeps retrying — even while analytics consent
is denied (either flavor) or unknown: the receipt documents the decision
itself, which is its legal purpose — it is what drives server-side
per-actor suppression and erasure consent rows, so a denial that never
reached the server would be a denial the backend could not honor. This is
the one deliberate exception to "a non-granted state produces zero wire
traffic", it carries no event payload, and an install with no explicit
decision (an empty outbox) still transmits nothing.

**What the server accepts from a publishable key (Mode A).** The ingest
service records **denial** receipts — `set_consent(false)` and the
forced-minor `reason`-bearing denial alike — for the key's own
workspace/app/environment scope. A **grant** receipt (`set_consent(true)`)
posted with the publishable `api_key` is rejected `403` with the distinct
detail code `consent_grant_requires_verified_credential` and, like every
non-transient rejection, is terminally dropped from the outbox: a public
key can safely deny its own actor's analytics but cannot vouch for a
grant, so grants are recorded server-side only through a trusted backend
credential. Consequence to plan for: once a denial is recorded
server-side, a later SDK grant re-opens the **local** pipeline, but the
server keeps suppressing that actor's events (`suppressed_no_consent`)
until a trusted-path grant lands. Client-key consent writes also consume
ingest budget whether accepted or rejected (deliberate anti-flood on a
public credential).

**Crash reporting is separate from analytics consent.** It is ON by default
(no first-run decision needed) with a persisted per-app opt-out:
`crash.set_enabled(false)` stops collection — not just sending — and is
honored on every later launch (see the crash sidecar section below). If the
persisted opt-out record cannot be **read** (a storage error — as opposed to
cleanly absent on a fresh install), the crash client **fails closed** and
sends nothing until an explicit `set_enabled` decision is persisted again.

- Durable storage is limited to six small, bounded records, all written
  through Defold `sys.save`: the identity record described above, a bounded
  crash-retry sidecar, the crash-reporting settings record (both described
  below), the bounded offline event spool, the bounded consent-receipt
  outbox (both described below), and the remote-config cache (described
  below). No cookies and no other browser or tracking storage.
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

## Consent-receipt outbox

Every explicit `set_consent` decision produces one consent receipt for
`POST {ingest_url}/v1/consent`. Until the server acknowledges it, the receipt
is retained in a small per-app durable outbox so an offline or crashed commit
still produces a server-side consent record once connectivity returns. This
outbox:

- stores only **consent receipts** — the decision's category flags, the
  canonical actor identifier the decision was keyed to and its `kind`
  (`"anon"` or `"user_verified"`, see above), the workspace/app/environment
  scope, a `decided_at` timestamp, an `idempotency_key`, (for the
  forced-minor state) the `reason`, and one piece of retention metadata that
  never reaches the wire: the decision-time anonymous id snapshot; **never
  event payloads and never tokens**;
- is **consent-plane only, in both directions**: no analytics data ever
  enters it, and — unlike the event spool — it is **never consent-purged**
  and its delivery is permitted while analytics consent is denied or
  unknown, because the receipt documents the decision itself (that is the
  record's legal purpose: server-side per-actor suppression and erasure rows
  act on it). An empty outbox produces zero traffic — an undecided install
  stays fully dark;
- delivers **serially, in decision order**, so the server applies the
  decision trail exactly as the player produced it;
- is **retried until acknowledged**: transient failures (offline, timeout,
  `429`, `5xx`) keep the receipt and retry at init, on the update/flush
  cadence, and at shutdown, honoring `Retry-After` and otherwise backing off
  exponentially — deliberately **no TTL**. Permanent rejections are dropped
  (surfaced through the `diagnostics` hook) so they cannot wedge the trail;
- is **pruned on success** — an acknowledged receipt leaves the record
  immediately; a re-send that raced an acknowledgment is de-duplicated
  server-side on the receipt's `idempotency_key`;
- is **bounded** (32 receipts) with **denial-preferring eviction**: overflow
  evicts the oldest pure-GRANT receipt first, and a denial-carrying receipt
  is evicted (oldest first) only when everything over the cap carries
  denials — a recorded denial is the compliance-critical write (a lost
  denial fail-opens the actor server-side), while a lost grant only delays
  pipeline opening and is re-writable — so the record can never grow
  without limit. The grant side of the same rule **fails closed**: when
  appending a grant's receipt would overflow the cap with no pure grant
  available to evict (a denial-full outbox), `set_consent(true)` is
  refused with `false, "consent_outbox_full"` — the state does not
  flip, nothing is evicted, every denial stays — and succeeds once the
  outbox drains below the cap; a denial append still applies (an
  all-denials overflow evicts the oldest denial in favor of the fresh
  one);
- is **fail-safe against corruption**: a malformed entry on disk is dropped
  at load — never sent, never a crash, never a blocker for well-formed
  receipts (an entry with a non-allowlisted `kind` counts as malformed; a
  legacy pre-kind entry is kept with `kind` backfilled to `"anon"`);
- **parks `user_verified` receipts while the current session cannot vouch
  for their actor** — no `token_provider` configured (a signed-out relaunch
  under the publishable key alone), no `identify()` yet, or a different
  user signed in (another actor's minted token could never deliver the
  receipt): a parked receipt is retained and persisted — still counted
  toward the cap — but excluded from dispatch and from the events-plane
  grant gate (it never wedges `flush()` or teardown, and never blocks a
  Mode B `set_anonymous_id` rotation — only anon-keyed receipts and an
  owed durable rewrite do, since a verified receipt keys to its user, not
  the anon), and delivers verbatim, same `idempotency_key`, the moment a
  Mode B session identifies as its actor again (`identify()` is a consent
  dispatch point) — always under a token minted for the vouching session:
  an identity change drops the cached Mode B token and fences any mint
  still in flight, so an unparked receipt never rides a credential minted
  for a previous session — so an undelivered verified denial survives
  signed-out relaunches;
- is **cleared on an identity change only when the receipt could never
  send**: in a Mode-B-ONLY configuration (no publishable `api_key`),
  anon-keyed receipts whose decision-time anonymous id no longer matches
  the client's are dropped at load (diagnosed as `identity_changed`) rather
  than replayed into a guaranteed auth rejection that would wedge the
  trail; with an `api_key` configured (Mode A, or Mode B + `api_key`),
  historic-anon receipts re-send under the publishable key unchanged — the
  historic actor is the correct subject of those decisions — and
  `user_verified` receipts are never dropped this way (they park, above);
- **surfaces a failed durable append**: when the write fails while the
  receipt is still undelivered, `set_consent` returns
  `false, "consent_outbox_persist_failed"` (the decision itself applied and
  delivery still proceeds and retries) — the write is retried at every
  dispatch point, including `persist()` even with the event spool disabled;
- is **per-app** (namespaced like the identity record) and goes through
  Defold `sys.save` only (browser storage on HTML5), degrading to in-memory
  retention for the process lifetime outside Defold — in that degraded mode
  `shutdown()` keeps refusing to tear down (`consent_pending`) while a
  receipt is undelivered, because nothing durable would survive the exit.
  After teardown the client dispatches nothing: a receipt still in flight
  settles its local bookkeeping, and the remaining durable receipts re-send
  on the next launch instead of chaining more requests.

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
  across our SDKs;
- carries **targeting attributes only under an explicit grant** (the one
  personal-data-shaped exception, dark by default): with the ADR-0310 opt-in
  (`remote_config_attributes_enabled = true`) the attributes the game stores
  via `set_remote_config_attributes` ride the fetch as query parameters so
  server-side delivery rules can target this client — and they ride ONLY
  while the consent state read at dispatch time is granted. Unknown consent
  and both denied states (the forced-minor denial included) keep the fetch
  attribute-less — byte-identical to the no-opt-in URL — and serve the
  untargeted defaults, so "no grant = zero attribute bytes egressed" holds
  while configuration delivery itself stays consent-neutral. The cache scope
  deliberately excludes the attribute set (one record per scope, targeted or
  not): a cached body may reflect the previously sent attributes until the
  next successful fetch; and
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
