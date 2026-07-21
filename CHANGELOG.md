# Changelog

### Unreleased

<!-- Folded into the next "## vX.Y.Z" heading at release time; kept at a
     deeper heading level so scripts/check_versions.sh keeps reading the
     topmost RELEASED version from the first "## " heading. -->

- **Canonical-actor consent-receipt keying (ADR-0222 §1, ADR-0202 2026-07-20
  amendment).** A consent receipt's actor is now chosen by the event plane's
  canonical-actor rule at decision time: the verified `user_id` ONLY when a
  Mode B `token_provider` backs the session and the host has identified
  (`kind = "user_verified"`); the SDK-managed `anonymous_id` with
  `kind = "anon"` in every other case — a Mode A self-asserted `user_id` is
  never the receipt actor (the publishable key cannot vouch for it, and the
  ingress binds the write to the caller's own anon scope regardless). This
  retires the v0.9.1 user-first snapshot, which took a set `user_id` even in
  Mode A. Delivery selects the dispatch credential PER RECEIPT,
  most-vouching first: the minted Mode B token whenever it vouches for the
  receipt's actor — the current verified user, or the CURRENT anonymous id
  the mint binds as its subject, so a current-anon grant stays deliverable
  in the dual `token_provider` + `api_key` configuration — and the
  publishable `api_key` only for receipts the token cannot vouch for: a
  HISTORIC-anon actor (the key is the one credential that can still carry
  it, with no mint; a historic-anon pure grant takes the documented
  terminal grant 403 — the one-way anon-scope outcome), and every anon
  receipt in pure Mode A. `user_verified` receipts go only under the
  minted Mode B token, never a publishable fallback. A consent 401 is classified by
  the credential the dispatch actually used: a publishable-key 401 is
  terminal even in a dual-credential configuration and no longer invalidates
  the cached Mode B token; a minted-token 401 still re-mints and retries.
- **Kind-carrying consent receipts, emitted by default with an escape
  hatch.** Every receipt persists its actor's identity class
  (`kind ∈ {"anon", "user_verified"}` — the SDK never produces any other
  value, `"user_unverified"` included) and re-sends it verbatim in the
  `/v1/consent` body next to `actor_identifier`. Emission is ON by default;
  the new config `consent_kind_emission_enabled = false` (boolean;
  `invalid_consent_kind_emission_enabled` otherwise) suppresses the WIRE
  field only, as the escape hatch for a deployment whose ingest service
  still strict-decodes the pre-amendment schema
  (`INGEST_CONSENT_KIND_MODE=off` 400-rejects a kind-bearing body as an
  unknown field) — the kind is still chosen, persisted, and used for
  dispatch-credential selection. The outbox load sanitizer holds records to
  the same closed set: entries with a non-allowlisted kind drop fail-safe,
  and legacy pre-kind entries are kept with kind backfilled to `"anon"`
  (the pre-kind ingress bound every client write to the caller's anon
  scope, so anon is the class those receipts were recorded under).
- **Denial-preferring consent-outbox cap eviction.** Overflow at the fixed
  32-entry cap now evicts the oldest PURE-GRANT receipt first; a
  denial-carrying receipt (any false category value — the forced-minor
  reason-bearing denial included) is evicted, oldest first, only when
  everything over the cap carries denials. A recorded denial is the
  compliance-critical write — a lost denial fail-opens the actor
  server-side, while a lost grant only delays pipeline opening and is
  re-writable. Everything else about the cap is unchanged: eviction happens
  only during a successful save, a failed write never evicts, and evictions
  stay counted (`consent_outbox_evicted`) and diagnosed
  (`outbox_overflow`). The grant side of the rule FAILS CLOSED: when
  appending a grant's receipt would overflow the cap with no pre-existing
  pure grant to evict (a denial-full outbox), `set_consent(true)` is
  refused with the distinct `false, "consent_outbox_full"` — the state
  does not flip, nothing is evicted, every denial stays retained — and the
  same grant succeeds once the outbox drains below the cap. This extends
  the floor's fail-closed family (a grant already refuses while a spool
  wipe is owed; it now equally refuses while its receipt cannot be durably
  retained), preserves the dispatch-gate premise (the gate's release
  condition is DISPATCH — a grant receipt evicted before dispatch would
  silently open the local pipeline with no grant row ever reaching the
  server, into strict-mode suppression), and never trades a denial (the
  legal record) for a grant. Denial appends are unchanged: an all-denials
  overflow still evicts the oldest denial — a fresh denial outranks a
  stale one.
- **Verified-keyed receipts park until a session vouches for their actor.**
  A `user_verified`-keyed receipt is dispatchable only while a Mode B
  `token_provider` is configured AND the session's identified user is
  exactly the receipt's actor; in every other session — no `token_provider`
  (a signed-out relaunch under the publishable key alone), no `identify()`
  yet, or a DIFFERENT user signed in — it PARKS instead of dispatching
  wrong or dropping (another actor's token would retry forever on the auth
  mismatch or be terminally rejected; the publishable key would rebind or
  reject the actor). A parked receipt stays retained and durably persisted
  — still counted toward the cap and eviction — is excluded from dispatch
  selection and from the events-plane grant-dispatch gate (a parked grant
  never wedges `flush()` or teardown; the gate's in-flight exemption is
  keyed by `idempotency_key`, since with parking the dispatch head is not
  always the queue front), and delivers verbatim, same `idempotency_key`,
  the moment a Mode B session identifies as its actor again — `identify()`
  is now a consent dispatch point for exactly that — so an undelivered
  verified denial survives signed-out relaunches. Parked-ness is derived at
  load/dispatch from the receipt's kind and actor, never persisted as its
  own field. A parked receipt never blocks a Mode B `set_anonymous_id`
  rotation: the rotation guard counts only consent work bound to the OLD
  anon — anon-keyed retained receipts and an owed durable rewrite — since a
  verified-keyed receipt keys to its user and survives anon changes by
  design (its actor may stay signed out indefinitely, and blocking on it
  would wedge rotation for exactly that long). And the dispatch `identify()`
  unlocks never rides the previous session's credential: an identity CHANGE
  drops the cached Mode B token — and a mint still in flight across the
  change discards its stale result — so the unpark dispatch mints fresh for
  the just-identified session (an actor/subject mismatch on `/v1/consent`
  is terminal and would drop the receipt, a retained withdrawal included).
  The load-time `identity_changed` drop narrows to
  the one configuration where a receipt could never send on any credential:
  anon-keyed entries with a mismatched decision-time anon snapshot in a
  Mode-B-ONLY configuration (with an `api_key` configured, historic-anon
  receipts dispatch under it instead — the historic actor is the correct
  subject of those decisions). The identity re-key enqueue on verified
  login, its durable once-per-decision ledger, and an explicit host API for
  discarding parked receipts are deliberately deferred pending
  godot-package ratification.
- **Experiment-assignment consumer (ADR-0259 SDK leg), dark behind
  `experiments_enabled` (default `false`).** New module
  `shardpilot/experiments.lua`: fetches the server-evaluated assignment from
  `GET {remote_config_url}/api/v1/runtime/experiments/assignment`
  (control-plane host, publishable-key bearer — the same credential as the
  remote-config fetch), serves the assigned variant through
  `shardpilot.fetch_experiment_assignment(experiment_key, [attributes],
  callback)` / `experiment_variant(key)` / `experiment_payload(key)`, and
  keeps a scope-stamped durable last-known-good cache (corrupt = miss).
  While the flag is off — the default — ZERO experiment code paths execute:
  no subject-id mint, no fetch, no revalidation timer, no exposure emit, no
  new persistence keys; the public calls answer
  `experiments_not_configured` / nil. Enablement for real traffic is
  governed by the platform's flag-flip registry preconditions; the endpoint
  itself answers 403 until the platform flips it, which this client treats
  fail-closed like any unauthorized answer.
- **SDK-managed experiment subject id.** Assignment fetches identify the
  subject with an SDK-minted id (`spcid_` + 32 lowercase hex — a UUIDv7
  with the dashes removed) persisted in the durable identity record. There
  is deliberately NO host override path: no config field is read for it and
  no setter exists. It is minted lazily at first need, validated against
  the wire grammar on load, re-minted only on storage loss/corruption
  (fresh-install re-bucketing semantics), carried forward across
  identity-record rewrites even while the flag is off, and egresses ONLY as
  the assignment fetch's `subject_key` — never in analytics events, props,
  or envelope identity. It is distinct from `anonymous_id`; the
  remote-config fetch identity is unchanged this wave.
- **Assignment-plane semantics.** Stickiness is entirely the server's
  deterministic hash (the SDK never re-buckets locally; the cache is a
  latency/offline device). The three not-assigned shapes — reason absent
  (deterministic traffic-gate miss), `targeting_unmatched`, `kill_switch` —
  all drop the cached assignment, a kill additionally guaranteeing no
  exposure is emitted for it. 401/403 fail CLOSED: nothing is served for
  the outcome, in-memory serving stops and revalidation halts until re-init
  or a later authorized fetch; the durable record is retained (remote-config
  parity) except under the server's real-subjects kill sentinel, which
  drops it together with its subject-fact key. 404 is permanent per
  experiment (treated as not-assigned, never served stale). 503 (the
  endpoint's kill-state-unavailable answer), 429, other 5xx, offline and
  timeouts are transient: the last-known-good assignment is served with the
  error surfaced, `Retry-After` is honored on 429 AND 5xx, and the
  revalidation cadence backs off exponentially otherwise. Targeting
  attributes ride the fixed server vocabulary (`geo`, `app_version`,
  `device_type`, `install_date`, `user_segment`) plus `custom_attribute_*`
  (suffix 1-64 chars); values are trimmed and bounded to 512 bytes, at most
  64 attributes ride one fetch (sorted-key order), and names outside the
  vocabulary are never sent.
- **Periodic revalidation (the SDK-side kill-switch reach).** Cached
  assignments are re-fetched — batched per tick, one GET per entry, each
  re-sending its last host-supplied attributes — every 300 s with ±10%
  jitter while the SDK runs, consent is granted, and at least one
  assignment is cached. Kill latency is bounded by this cadence and stated
  honestly: an offline client keeps its last-known-good variant
  indefinitely. A parked revalidation never blocks `shutdown()`.
- **Consent integration (granted-only plane).** Assignment fetches, cached
  serving, revalidation, and the subject-id mint all require analytics
  consent `granted`: under `unknown` or either denial flavor — the
  forced-minor state in particular — the consumer produces ZERO experiment
  traffic on both planes, refuses fetches with the standard distinct codes
  (`consent_unknown` / `consent_denied`), and the getters serve nil. The
  durable cache record is retained unserved through a downgrade (the
  remote-config fail-closed posture: never destroy the record, never serve
  it either) and a later re-grant serves it again. Experiments therefore
  require analytics consent by design — deliberately stricter than the
  remote-config fetch, which stays consent-free.
- **Exposure/outcome fact lane (ships dark with the same flag).**
  `experiment_exposure` rides the normal analytics pipeline (queue → batch
  → spool → consent gates) at most once per (experiment, version, subject)
  per session, emitted when the assigned variant is first applied — a fresh
  fetch resolution, or the first granted tick serving a cache-restored
  assignment — with a deterministic `event_id` so at-least-once retries and
  same-session double emissions collapse server-side as duplicates. The
  emission timing and id derivation are a PROPOSED SDK convention pending
  platform ratification. `shardpilot.track_exposure(key)` re-arms
  explicitly (a distinct deterministic id per arm);
  `shardpilot.track_outcome(key, outcome_key, outcome_value)` records
  host-defined outcomes as distinct facts. Facts carry the server-minted
  subject-fact key VERBATIM as the `assignment_key` prop for
  client_id-unit assignments (the raw subject id is structurally rejected
  there) and omit `user_id` per the facts contract, keeping the standard
  `anonymous_id` as the envelope identity. NOTE: the analytics service
  currently rejects these event names from game-embedded publishable keys
  by design; until the platform's producer-lane decision lands, an emitted
  exposure is expected to come back as a per-event reject, surfaced through
  diagnostics and tolerated silently otherwise — that server-side block is
  load-bearing and stays authoritative.
- Feature-detect with `shardpilot.supports("experiments_assignment")`. New
  behavioral suite `test/test_experiments.lua` joins the CI interpreter
  matrix, and the engine-real bob-build harness now requires
  `shardpilot.experiments` so the module is compiled by the library build.

- **CI gained an engine-real `bob-build` leg** (fleet-audit gap: the
  contract core was interpreter-tested only, with no proof the tree still
  works as an actual Defold library). On every PR and push to `main`,
  `scripts/ci_bob_build.sh` packages the WORKING TREE with
  `scripts/package_release.sh`, serves that ZIP over localhost as the
  dependency URL of a minimal committed consumer project
  (`test/bob-harness/`, whose main script requires `shardpilot.sdk`,
  `shardpilot.crash`, and `shardpilot.remote_config`), and runs Defold's
  command-line builder on it (`java -jar bob.jar resolve build`,
  x86_64-linux, release variant with archive) — so packaging or
  library-contract breakage is caught before a tag is cut, not after.
  Bob is deterministic and supply-chain-pinned: Defold 1.13.0 by engine
  sha1 with a sha256-verified `bob.jar` download (cached in CI, re-verified
  on every run) on Temurin 25. Scope honesty: this leg proves dependency
  resolution plus build-time compilation only — it does not start the
  engine or exercise runtime behavior, which remains covered by the
  interpreter test legs.

## v0.9.1 — 2026-07-19 — early alpha

- **Host-supplied identifiers are clamped to 512 bytes at acceptance**
  (GAP-075 code follow-up to the save-file-limit caveats documented in #30).
  `identify(user_id)` and `set_anonymous_id(id)` reject identifiers over 512
  bytes exactly like empty/non-string input (`invalid_user_id` /
  `invalid_anonymous_id`, previous identity retained), and an out-of-bounds
  config `anonymous_id`/`user_id` — or a legacy oversized persisted anonymous
  ID — is ignored in favor of the stored or freshly generated identity.
  Oversized input is rejected, never truncated: truncation could collide
  distinct identities. Identifiers are persisted verbatim in the identity
  record and in every retained consent receipt (`actor_identifier` plus the
  decision-time `anonymous_id` snapshot), and the 32-entry consent outbox
  deliberately has no byte budget or failed-write eviction — so before the
  clamp a few oversized identifiers could push those records past Defold's
  ~512 KB `sys.save` cap, persistently failing the outbox write and wedging
  `shutdown()` in `consent_pending`. With the clamp the worst-case outbox
  stays around ~46 KB and identity-record writes stay far under the cap.
  Records written before the clamp existed self-heal at load: an oversized
  persisted anonymous ID is replaced by a fresh identity, and outbox
  receipts carrying oversized identifiers are dropped by the load-time
  sanitizer (fail-safe, like any other malformed entry — such a receipt can
  never be durably rewritten alongside new decisions), so a previously
  wedged install becomes writable again on upgrade.

## v0.9.0 — 2026-07-18 — early alpha

- **Batch ingest now declares the SDK's schema-set revision** (GAP-036,
  client half of the analytics-service schema-revision handshake). Every
  `POST {ingest_url}/v1/events:batch` request carries an
  `X-ShardPilot-Schema-Revision` request header with the revision of the
  analytics-service envelope-schema set this SDK build was provisioned
  against (new module `shardpilot/schema_revision.lua`; the value is a
  public content digest of the service's embedded schema files — not a
  secret — and is re-synced whenever the service's schema set changes).
  The header rides ONLY the events-batch route: the consent, crash, and
  remote-config requests never carry it, and it rides only on batches that
  already passed the consent gate (consent-first semantics unchanged).
  While the server-side handshake mode is `off` (today's default in every
  environment) the header is provably ignored, so emission is inert until
  the service arms `log`/`enforce`. New config knob `schema_revision`:
  default (nil) declares the built-in revision, a non-empty string
  overrides the declared value, `false` or `""` stops declaring — an
  undeclared batch always passes the server's check, in every mode.
  Feature-detect with `shardpilot.supports("schema_revision_declaration")`.
- **`schema_revision_mismatch` 409s are terminal for the batch.** When an
  armed (`enforce`) ingest service rejects a batch with a `409` whose
  `error.code` is `"schema_revision_mismatch"`, the batch takes the
  existing terminal-failure path — dropped, never retried (the server
  sends no `Retry-After`; a retry from the same build can never succeed),
  never retained or spooled for a later launch — and a clear log line
  names the declared revision, the revision the service serves (read from
  the response header when present), and the fix (re-sync the constant or
  set `schema_revision = false`). Discrimination is by `error.code`, never
  by the bare `409` status: the other ingest 409 codes keep their existing
  handling.

## v0.8.1 — 2026-07-18 — early alpha

- **`Retry-After` is now honored on 5xx responses, not only 429** (SDK
  strict-consent audit follow-up). The transport parsed the `Retry-After`
  header on every response but passed it to the client only in the 429
  branch; a retryable 5xx fell back to the client's own full-jitter
  exponential backoff. The analytics service's strict-consent
  mode-unknown/consent-store-outage lane (GAP-041) answers a whole-batch
  `503` with `Retry-After: 5`, so post-outage recovery is now paced by the
  server's hint — the deferral (and its persisted spool deadline, 24h
  clamp) works exactly as it already did for 429, on both the events plane
  and the consent-receipt outbox. No behavior change for responses without
  the header.
- **Receipt-before-batch flush ordering pinned** (audit item 3a). Within one
  flush cycle the consent-receipt outbox was already handed to the transport
  strictly before the event batch at every dispatch point
  (init/update/flush/shutdown); this ordering is now documented as
  load-bearing and pinned by a regression test. On a strict-enforce
  workspace (GAP-041) it shrinks the window in which a post-grant batch
  reaches the server before the grant's `/v1/consent` row exists and is
  terminally suppressed. Sequencing only — the batch never waits on the
  receipt's acknowledgment.
- **Event batches are held until every retained analytics GRANT receipt has
  been handed to the transport.** A grant parked in a server-requested
  Retry-After window or the client's own jittered backoff, queued behind
  another receipt in the serial outbox, or awaiting its first
  post-relaunch dispatch has not been handed over yet — publishing events
  meanwhile would invert the receipt-before-batch ordering, and on a
  strict-enforce workspace those post-grant events reach the server before
  the grant row exists and are terminally suppressed. The gate releases on
  DISPATCH, never acknowledgment: a grant in flight lets the batch follow
  with the receipt's response still pending, an empty event pipeline is
  never gated (a durably retained receipt alone cannot block shutdown
  teardown), and a relaunch needs no persisted window — the retained grant
  re-dispatches at init ahead of any batch the fresh process can publish.

## v0.8.0 — 2026-07-13 — early alpha

- **`buffer_size` default raised from `200` to `1000`** — the cross-SDK
  canonical in-memory queue capacity (architecture-audit finding SP-059).
  The Go, Unity, and Unreal SDKs and the platform docs all default the
  bounded event queue to 1000; the Defold SDK now matches, so a burst that
  used to drop at 200 queued events is retained like on every other
  ShardPilot SDK. Explicitly configured `buffer_size` values are unaffected,
  and the queue stays memory-only. The offline spool caps
  (`spool_max_events = 500`, `spool_max_bytes = 262144`) are deliberately
  NOT raised to the Unity/Unreal 2000/1 MiB values: Defold's save-file API
  caps a persisted record at 512 KB, so the spool budget stays clamped at
  384 KB max with the same ~524-bytes-per-event ratio the other SDKs use —
  a documented per-platform adaptation, not drift. As before, a shutdown
  remnant larger than the spool caps surfaces honestly (`spool_evicted`,
  `shutdown()` returning `false` while undelivered events remain).

## v0.7.0 — 2026-07-11 — early alpha

- **Durable consent-receipt outbox: receipts now survive process death and
  retry until acknowledged.** Every explicit `set_consent` decision becomes
  exactly one receipt (the `POST {ingest_url}/v1/consent` payload snapshotted
  at decision time, with its own `idempotency_key`), appended to a new small
  per-app durable record (`consent-outbox`) and delivered **serially, in
  decision order** — so a grant made right after a denial can never settle on
  the server as deny-after-grant. Previously the receipt was retained
  in memory only (lost with the process), only for the no-token-yet and
  Mode B 401 cases, and only the LATEST undelivered decision was kept; any
  other transport failure — a 500, a network error, an offline commit —
  silently lost the receipt. Now:
  - **Delivery failures never throw into game code and never give up on
    transient errors**: a retryable outcome (offline, timeout, `429`, `5xx`,
    a Mode B 401) keeps the receipt at the head of the outbox and retries at
    every dispatch point — init, the update-driven flush cadence, explicit
    `flush()`, and `shutdown()` — honoring a `Retry-After` and otherwise
    backing off exponentially with jitter, on a **consent-plane deferral
    independent of the events plane's** (a denial clears the publish deferral
    but must not unthrottle receipt retries). A successful delivery prunes
    the receipt from the durable record immediately; a failed prune rewrite
    is retried and, if the app dies first, the next launch's re-send is
    de-duplicated server-side on the receipt's `idempotency_key`.
  - **Terminal outcomes are pruned, not replayed forever**: a permanent `4xx`
    — including a Mode A 401, whose static publishable key cannot change —
    drops the receipt (surfaced through the `diagnostics` hook, scope
    `consent`) so the receipts queued behind it still deliver. Under Mode B
    auth, receipts retained under a previous anonymous id are likewise
    dropped at load (`identity_changed`, mirroring the event spool's rule):
    each entry stores its decision-time anon snapshot as retention metadata
    (never sent on the wire), and a token minted for the new identity could
    only replay them into a guaranteed rejection that wedges the trail.
    Mode A re-sends historic actors unchanged.
  - **A failed durable append is surfaced, not silent**: while the receipt is
    still undelivered without a durable copy, `set_consent` returns
    `false, "consent_outbox_persist_failed"` — the decision itself applied
    and delivery still proceeds; the write retries at every dispatch point,
    including `persist()` even when the event spool is disabled
    (`spool_enabled = false`), since the outbox is independent of event
    spooling. A receipt already acknowledged by a synchronous delivery needs
    no durability and reports success.
  - **The outbox is consent-plane ONLY**: it never carries event envelopes,
    and it is **never consent-purged** — unlike the offline event spool, it
    loads and delivers on denied and unknown launches alike, because a
    receipt documents the decision itself (that is its legal purpose; see
    `docs/privacy.md`). An empty outbox still costs a fresh consent-first
    install nothing: no token is minted and zero requests leave the device.
  - **Bounded, no TTL**: at most 32 receipts, oldest evicted first (the
    newest decisions are the operative ones; evictions of undelivered
    receipts are counted in `consent_outbox_evicted` and diagnosed as
    `outbox_overflow`). Only the cap evicts — a FAILED durable write never
    does: it fails the save, the receipts stay in the in-memory mirror
    (still delivering), and the write is retried at every dispatch point, so
    a transient storage failure can never silently drop a receipt while
    reporting success. There is deliberately no age limit — an undelivered
    receipt is retried until acknowledged. A malformed record on disk is
    fail-safe: garbled entries are dropped at load, never sent, never a
    crash, and never a blocker for the well-formed receipts around them.
  - **`shutdown()` no longer waits on a durably retained receipt**: like the
    event spool, a receipt that is safely on disk re-sends on the next
    launch, so teardown completes — and a receipt still in flight at
    teardown settles its own bookkeeping without chaining further requests
    (a torn-down client dispatches nothing). The
    `false, "consent_pending"` contract remains when the receipt could NOT
    be durably captured (no save-file API on the host, or the durable write
    itself failing — tracked and retried via
    `consent_outbox_persist_failed`), and an owed post-delivery prune
    rewrite counts as pending too: a Mode B `set_anonymous_id` rotation
    waits for it (`events_pending`), or the stale on-disk receipt would
    reload at the next launch and replay an old actor under a token minted
    for the new one.
  - New snapshot counters: `consent_outbox_evicted`,
    `consent_outbox_persist_failed`. Durable storage grows from five to
    **six** small bounded per-app records.
- **New consent decision `set_consent("denied_forced_minor")`** — the
  age-gate-forced denial state the consent & age-gate UX spec's minor mode
  requires (its AC-8). Analytics-wise it is IDENTICAL to `denied`: events
  drop at enqueue with `consent_denied`, the queue clears, in-flight batches
  are discarded, the durable spool purges fail-closed, samplers reset, and a
  launch that starts with the persisted state purges the spool and transmits
  nothing. The one difference is the receipt: it carries
  `reason = "denied_forced_minor"`, so the backend per-actor gate can tell a
  band-forced denial from a chosen one. In a forced-minor session the sole
  analytics-plane request on the wire is that receipt POST (covered by a
  dedicated AC-8 test). The state is superseded like any other: a later
  `set_consent(true)`/`set_consent(false)` (the spec's band-correction path)
  applies normally and posts a fresh, reason-less receipt. Any other string
  is still rejected with `invalid_consent`; the `set_consent` parameter is
  now documented as `decision` (`true` | `false` | `"denied_forced_minor"`).
- **New capability discovery: `shardpilot.supports(capability)`** — usable
  before `init()`, returns `true` for `"consent_receipt_outbox"` and
  `"consent_state_denied_forced_minor"`, and `false` for anything unknown on
  older and newer SDKs alike, so a game can feature-detect call shapes that
  are not new functions (the way `crash.set_enabled` presence can be
  checked).
- README/docs updated for the receipt-outbox semantics (`README.md`,
  `docs/privacy.md` — new "Consent-receipt outbox" record section — and
  `docs/events.md`), and release references bumped (version `0.7.0`; latest
  published tag `v0.6.0`).

## v0.6.0 — 2026-07-11 — early alpha

- **BREAKING: consent-first analytics — "unknown" no longer transmits.** The
  analytics pipeline now opens only under an explicit granted decision.
  Previously the default `unknown` consent state was fully open (only an
  explicit denial blocked); now, while consent is `unknown` — a fresh install,
  or an identity record that cannot be read — `track()`, `screen_view()`, and
  `session_start()` return the new distinct error `false, "consent_unknown"`
  and the event is **dropped, not held**: nothing is queued, nothing is
  written to the durable offline spool, `flush()`/`update()`/`persist()` are
  clean no-ops, summary events are not enqueued, no consent receipt is sent,
  and there is **zero analytics wire traffic**. Runtime samples follow the
  same rule: `observe_ping_ms` / `observe_disconnect` / frame sampling are
  dropped at the source while the pipeline is closed, and a denial resets the
  samplers — a `perf_summary`/`network_summary` emitted after a grant can
  never carry pre-consent or denied-period activity. Because dropped means
  dropped,
  no pre-consent data ever exists at rest; `set_consent(true)` opens the
  pipeline for FUTURE events only. Integrations must now call
  `set_consent(true)` (wired to their consent UX) before any events flow — the
  quick start, both README examples, and docs show the sequence.
  - **Only a launch that starts with a persisted grant loads the offline
    spool.** Any init in a non-granted state — denied, unknown, or an
    unreadable identity record — purges the record instead of holding it: a
    spool without an affirmative grant behind it cannot be proven to have
    been written under one (a v0.5 install spooled while `unknown` was still
    open, and an unreadable identity record may have carried a denial whose
    purge is still owed), so its envelopes are dropped rather than re-sent
    under a later grant. The purge fails closed (`spool_purge_pending`) and
    is retried at later dispatch points and at every later non-granted
    launch. `session_end()` and
    `shutdown()` complete their local teardown while consent is unknown with
    the same suppressed-wire posture the denied state already had.
  - A consent-state read failure now **fails closed**, for the wire and for
    data at rest alike: an unreadable identity record resolves to `unknown`,
    which transmits nothing (previously it resolved to `unknown` and
    transmitted everything) and — via the purge rule above — clears the
    offline spool, so possibly pre-revocation envelopes never outlive a lost
    denial.
  - `denied` semantics are unchanged: events drop at enqueue with
    `consent_denied`, the queue clears, in-flight batches are discarded on
    completion, the spool purges fail-closed, and explicit decisions are
    still reported to `POST {ingest_url}/v1/consent` (no receipt is ever sent
    for the undecided state).
  - Remote config remains deliberately **not** consent-gated (configuration
    delivery carries no analytics payload) — unchanged.

- **BREAKING(-ish): crash reporting gains a persisted client-side opt-out and
  fails closed on an unreadable state.** Crash reporting stays **ON by
  default** — it needs no first-run decision — but the crash plane previously
  had no client-side gate at all (suppression was server-side only). New
  facade + instance API:
  - `crash.set_enabled(false)` persists a per-app opt-out (a new one-boolean
    `crash_enabled` settings record stored alongside the pending sidecar) and
    stops **collection**, not just sending: `emit`, `emit_fatal`,
    `capture_previous`, and `resend_pending` all return
    `false, "crash_disabled"`, no report is prepared or written to the
    pending sidecar, the pending backlog is neither loaded nor re-sent (it
    ages out under its ~7-day TTL — enforced by a maintenance read at every
    `init`/`new` even while disabled, so an opted-out install cannot keep
    already-scrubbed crash bodies on disk past the TTL), and the
    previous-session native dump is
    left **unread** — the engine's one-shot store is not consumed, so the
    dump survives for a later enabled launch. The breadcrumb ring is emptied
    at the flip and `record_breadcrumb` refuses new entries while disabled,
    so a report emitted after a re-enable can never carry opt-out-period
    activity. The gate also holds mid-pass:
    a disable landing while a serial resend pass is in flight stops the pass
    before its next dispatch.
  - `crash.is_enabled()` returns the state plus a reason
    (`"opt_out"` / `"settings_read_failed"` / `"not_initialized"`) while
    disabled.
  - **Fail closed on read failure:** an ABSENT settings record (fresh
    install) applies the default — enabled; a record that cannot be READ (a
    thrown `sys.load`, a corrupt file) — or that loads carrying a malformed,
    non-boolean `crash_enabled` — starts the client **disabled** and
    nothing is collected or sent until an explicit `set_enabled(...)`
    persists a readable decision again. `storage.lua` now distinguishes
    absent from failed reads for this record instead of swallowing both into
    "absent", and the in-process settings fallback is seeded only by writes
    that actually persisted — a failed `set_enabled(true)` can never reopen
    a fail-closed client at a later same-process init.
  - A failed durable write at `set_enabled` returns
    `false, "crash_persist_failed"` while the in-memory decision still
    applies for the session (call again to retry), mirroring
    `consent_persist_failed`.
  - The crash opt-out is independent of the analytics consent state: the two
    planes are configured, stored, and gated separately (crash reports carry
    no actor identity and are PII-scrubbed before anything touches disk or
    the wire).

- README release references updated for the bump (version `0.6.0`, latest
  published tag `v0.5.0`), and the instance-API example gained the required
  `set_consent(true)` call alongside the quick start.
- Durable storage grows from four to **five** small bounded per-app records:
  the new crash-reporting settings record joins the identity record, offline
  event spool, pending-crash sidecar, and remote-config cache. Documented in
  `docs/privacy.md` / `docs/crash.md` (new "Opting out" section), and the
  consent-first contract in the README, `docs/events.md`, and
  `docs/configuration.md`.
- This is an early alpha pre-release. The API is unstable and may change before v1.

## v0.5.0 — 2026-07-06 — early alpha

- **Remote config fetch with a durable last-known-good cache and typed
  getters.** A new `remote_config_url` config field enables
  `fetch_remote_config(callback)` — an explicit, game-triggered
  `GET {remote_config_url}/config/v1/{workspace_id}/{environment_id}/{client_id}`
  authenticated with the publishable `api_key` (`client_id` = the persisted
  anonymous ID) — plus typed getters
  (`remote_config_string/number/boolean/value/values/version`) that never
  fail and serve the caller's default until configuration is available.
  `remote_config_version()` reads the `version` from the response wrapper
  only — it is response metadata, never taken from the configuration map.
  - **ETag revalidation and offline fallback.** A `200` serves fresh values
    and overwrites the one bounded per-app cache record; later fetches
    revalidate with `If-None-Match`, and a `304` — or any transient failure
    (offline, `408`, `429`, `5xx`, malformed body) — serves the cached
    snapshot with `from_cache = true`. A `304` also renews the record's
    freshness stamp, in memory and (best-effort) in the durable record: the
    endpoint just confirmed the body as current, so the record outranks
    same-scope records stamped while the request was in flight — though it
    never displaces a fresher record carrying a different body (a `304`
    validates at server handling time, not delivery time). The snapshot
    survives restarts, so an offline launch still gets the last served
    configuration. Responses arriving out of order (two fetches in flight)
    can never roll a newer configuration back or sneak values in after a
    newer fail-closed outcome; a response for an identity rotated away
    mid-flight is dropped; freshness stamps stay monotonic across backward
    wall-clock jumps, so a record being installed can never rank below the
    records it supersedes; and a failed cache write keeps the freshest
    served configuration as the in-process fallback while clearing the
    durable record it superseded (never a fresher one another same-app
    client persisted meanwhile), so neither this process nor a restart can
    revive rolled-back values.
  - **Fail-closed on `401`/`403`; permanent errors never serve the cache.**
    An unauthorized fetch reports `unauthorized` and never serves the cached
    snapshot (a revoked or wrong key must not keep supplying configuration);
    the cache record itself is left untouched for a later authorized
    revalidation. Any other non-transient status (`404`, an unexpected
    redirect, other `4xx`) fails the same way instead of reporting stale
    values as a healthy fetch.
  - **Scope-checked cache.** The record is stamped with the (workspace,
    environment, client, url) scope it was fetched for; any other scope —
    including a rotated anonymous ID — treats it as a miss and overwrites it
    on the next successful fetch.
  - **Auth carve-out.** The remote-config endpoint accepts the publishable
    `api_key` only, so enabling remote config under Mode B requires the
    `api_key` too (`remote_config_api_key_required`) — the one configuration
    where both credentials are valid together (the minted token keeps the
    ingest Bearer; the `api_key` authenticates only the config fetch).
  - Not consent-gated (configuration delivery carries no analytics payload),
    no automatic refresh (every fetch is an explicit call), no experiment
    assignment or exposure events.

- **Write-ahead crash-report durability with byte-identical resend.** Crash
  delivery is no longer fire-once for live reports: EVERY report that reaches
  dispatch — a live `emit_fatal`, a sampled-in `emit`, a previous-session dump
  forward alike — is persisted to the bounded per-app pending sidecar
  **before** its send attempt, holding the exact encoded wire body. An entry
  settles (is removed) only when the server accepts it (2xx, including an
  accepted-but-suppressed report) or rejects it terminally (non-retryable
  4xx); a retryable failure — offline, `429`, `5xx` — keeps it durable, and a
  later launch re-sends the SAME bytes, de-duplicated server-side by the
  stable `crash_id` embedded in the body.
  - **Serial resend with backpressure that survives relaunches.** The resend
    pass (run first by `capture_previous()`, or manually via
    `resend_pending()`) dispatches strictly one report at a time, oldest
    first; a retryable failure stops the whole pass, and a server
    `429 Retry-After` window is stored with the sidecar (clamped to one day,
    spent/absurd values self-clean) so a relaunch inside the window keeps
    waiting it out — surfaced via `snapshot().resend_deferred_until_ms`. An
    accepted send clears the window; a kill mid-pass loses nothing and the
    pass resumes where it left off.
  - **Bounds with fatal-first retention.** At most 8 reports / 64 KB per
    encoded body / 384 KB total (well under the documented 512 KB `sys.save`
    cap). Over a bound, the oldest **non-fatal** reports are evicted before
    any fatal one — a burst of handled errors can never displace a pending
    fatal crash — and the report being saved is never the one evicted. An
    oversized single body is rejected up front without evicting anything;
    entries older than ~7 days are discarded on read.
  - **Durability stays honest.** A failed durable write returns no token and
    falls back to an in-session, memory-only retention (surfaced via
    `snapshot().persist_failed`) that an in-session pass can retry but a
    restart loses; pending entries written by an older build (prepared-report
    tables) are still adopted, re-sent, and settled. New snapshot counters:
    `persisted` / `persist_failed`.


- **Durable offline event spool with resend on next launch.** The analytics
  event queue was memory-only: an app kill lost the unflushed tail, and offline
  play silently dropped events. Undeliverable event envelopes are now persisted
  to a per-app spool and re-sent on a later launch. Envelopes are spooled and
  re-sent **verbatim** — the `event_id`/`event_ts` stamped at `track()` time are
  never rebuilt — so the ingest service de-duplicates a re-send that raced an
  original delivery, and re-sends are safe.
  - **What gets spooled:** a batch whose publish failed for a transient reason
    (network unreachable, timeout, `429`, `5xx` — the same classification that
    already retains a batch for in-process retry, including a Mode B `401`,
    which is retried with a fresh token; a Mode A `401` is terminal and is
    never spooled); the undelivered remnant (queue + in-flight batch) at
    `shutdown()`; and an explicit `persist()` snapshot (see below). Permanent
    `4xx` rejects are **never** spooled — they would fail forever.
  - **Resend:** on init the spool is loaded and re-sent through the normal
    publish machinery — chunked to `batch_size`, before fresh events, honoring
    the same token/consent/`Retry-After`/backoff gates. Entries leave the
    record only after the server acknowledged their batch (2xx) — ack-based
    removal keyed by `event_id`. A permanent `4xx` on a spooled batch also
    removes it (surfaced via the `diagnostics` hook, scope `"spool"`); a
    transient failure keeps it for the next launch. A failed removal rewrite
    keeps the entries marked settled and retries on the flush cadence until
    storage recovers. A `429` `Retry-After` received while a batch is spooled
    is stored with the record (`retry_after_until_ms`): a relaunch inside the
    window waits out the remainder before re-sending, bounded by the same
    24-hour clamp as the in-process deferral. The caps are re-applied to a
    previously persisted record at load, so lowered budgets trim an old
    record (oldest first).
  - **`shutdown()` semantics:** when the final flush cannot deliver and the
    remnant is durably spooled, `shutdown()` now completes the teardown and
    returns `true` (the events are safe on disk; a host retry loop is no
    longer needed for them). Durable capture is strict: on a runtime without
    the save-file API (memory-only fallback), or when the caps evicted part of
    the remnant being captured itself, `shutdown()` keeps the old contract and
    returns `false, err` — and so does a **permanent** rejection during the
    final flush, which drops the batch and leaves nothing to spool (the
    failure surfaces instead of a vacuous clean teardown; a repeated
    `shutdown()` call completes normally since the queue is already clean).
    It still returns `false, "consent_pending"` while
    a consent decision awaits a token — consent receipts are not spooled. With
    `spool_enabled = false` the previous contract is unchanged.
  - **New `persist()`** (instance + singleton): snapshots every undelivered
    event into the spool without sending or tearing down — call it from a
    window focus-lost/iconify listener (the SDK never installs global
    listeners itself; see the README recipe — note the runtime keeps a single
    window listener, so add the branch to your existing one). Later
    acknowledged delivery removes the snapshot entries. Reports
    `false, "spool_persist_failed"` when the snapshot was not durably and
    fully captured (same strictness as `shutdown()`).
  - **Consent & identity:** a persisted "denied" decision clears the spool at
    load without sending — the purge runs unconditionally, so a record that
    cannot even be read is still cleared; `set_consent(false)` at runtime
    also purges it.
    Denied actors never have events on disk. If the durable purge itself
    fails, `set_consent(false)` returns `false, "spool_purge_failed"` and the
    spool goes fail-closed (nothing appended, loaded, or re-sent) while the
    purge is retried automatically at later dispatch points and at the next
    launch; a failed init-time purge (persisted denial or disabled spool)
    behaves the same. Revocation cleanup completes before a new grant takes
    effect: `set_consent(true)` retries an owed purge first and is not
    applied while it keeps failing (`false, "spool_purge_failed"`; the
    persisted decision stays denied), so a relaunch can never replay the
    pre-revocation record under a granted decision. Under Mode B auth, an init-time
    `anonymous_id` override drops spooled envelopes carrying the previous
    identity at load — the minted token binds the current identity, so
    re-sending them would be rejected — surfaced via `diagnostics`
    (scope `"spool"`, code `identity_changed`); Mode A re-sends
    historic-identity envelopes unchanged.
  - **Bounds:** new config knobs `spool_enabled` (default `true`),
    `spool_max_events` (default `500`), and `spool_max_bytes` (default
    `262144`, max `393216` — headroom under the documented 512 KB save-file
    cap). Over a cap the OLDEST entries are evicted first. The byte bound uses
    the JSON-encoded length when the runtime provides an encoder, else a
    conservative per-field estimate. Setting `spool_enabled = false` also
    deletes any previously persisted spool record at the next init.
  - **Safety:** a corrupted or garbled spool record is discarded and the
    client starts clean — the spool never errors into game code. The spool
    stores only the envelope tables that were already bound for the wire —
    never tokens — under the same per-app namespace as the identity record
    (file `"spool"`), with the same in-memory fallback outside Defold. This is
    consistent across our SDKs.
- `snapshot()` gains `spooled`, `spool_resent`, `spool_evicted`, and
  `spool_persist_failed` counters.
- Mode B anonymous-ID rotation now also waits for pending spooled work
  (`events_pending`), since spooled envelopes carry their historic
  `anonymous_id` snapshot.
- This is an early alpha pre-release. The API is unstable and may change before v1.

## v0.4.0 — 2026-07-06 — early alpha

- Adds **crash reporting** as a separate `require "shardpilot.crash"`
  module. Crash reports
  are sent — one per crash — to a **dedicated** crash ingest endpoint
  `POST {crash_ingest_url}/api/v1/crashes/ingest` with a `crash:write` API key as
  the `Bearer`, carrying the crash report JSON body. A crash is
  **never** wrapped as a `mobile_crash` analytics event on `/v1/events:batch`. The
  crash client has its own config (`crash_ingest_url`, `crash_api_key`, `app_id`,
  `crash_source`, `sample_every`, …), independent of the analytics client.
- Stamps the component-slug **`source`** on every crash report,
  configured via `crash_source` (mirroring how the analytics `source` is
  configured), defaulting to empty/bare-app, and validated as the slug
  `^[a-z0-9][a-z0-9-]{0,62}$` (≤63 chars) before the wire. A per-report `source`
  overrides the configured default.
- **Fatal crashes are never sampled.** `emit_fatal` (and the dump-forward path)
  bypass the sampler entirely; only non-fatal `emit` is subject to `sample_every`
  / a custom `sampler`.
- **Surfaces the ingest response and server backpressure.** `snapshot()` now reports
  `suppressed` (crashes the server accepted but did NOT store because the actor withheld
  consent — counted apart from `accepted`), `last_warning` (the most recent non-fatal
  server processing notice), and `last_retry_after` (the most recent server-instructed
  `Retry-After`, in whole seconds, from a `429`/`503` — previously the `503` value was
  dropped); the diagnostics hook also receives `retry_after`. The response body was
  previously discarded; it is now parsed best-effort (a `2xx` with an unparseable body is
  still an accepted crash) and only when the runtime exposes `json.decode`.
- **PII scrubbing:** every caller-populated
  string is stripped of emails, `player_`/`user_`/`customer_`/`device_`
  raw-identifier prefixes (both a bare id like `user_4242` and one embedded in
  free-form text like `failed for user_4242`, while ordinary prose such as
  `user_id is null` is preserved), IPv4/IPv6 literals, and JWT-shaped dotted
  tokens. A
  frame `function` from the trusted native-dump path is scrubbed as a code symbol
  (a package-qualified name survives; an embedded email/IP still blanks it); a
  manual caller's frame `function` gets the full content scrub. The native crash
  **trace text** (`raw_text`) is scrubbed as code (it is full of scoped/dotted
  symbols like `Player::Update` and `java.lang.RuntimeException`), so a frame-less
  fatal reported only as a trace is not blanked over a code symbol and dropped — a
  real email/IP/token inside it is still removed. The app
  version/build are scrubbed with a version-aware rule so a dotted version such as
  `1.2.3.4` is kept rather than mistaken for an IP, and the operator-set `app_id`
  is treated as product scope (a slug like `user_app`/`customer_portal` is kept,
  not mistaken for a raw actor id). A
  `context.session_id` carrying disallowed identifier material rejects the whole
  report. Free-text fields also have the username segment of a user-home path
  (`/Users/<name>/`, `/home/<name>/`, `C:\Users\<name>\`) replaced with
  `<redacted>`, preserving the rest of the path. Crash state is held **in memory**,
  except a small bounded per-app sidecar that retains a previous-session dump
  report when its send fails for a temporary (retryable) reason, so it can be
  resent on a later launch; that entry is cleared on success or terminal rejection.
- **Auto-capture** of a previous-session **native** crash via Defold's built-in
  `crash` module: `crash.capture_previous()` reads `crash.load_previous()` on next
  launch and forwards a native crash event (`instruction_addr` frames + a module
  map, signal-derived exception type, OS sys-fields) as a fatal report. Because a
  native engine crash is unrecoverable in Lua, the model is
  **load-on-next-launch**; limits (no per-frame module attribution, no debug IDs,
  no breadcrumbs from the dead session, platform dependence) are documented in
  [`docs/crash.md`](docs/crash.md). Because the native dump is one-shot
  (consumed when it is read), a previous-session report whose send fails for a
  **temporary** reason (offline, rate-limited, or a server error) is persisted to a
  small per-app sidecar and resent on the next `capture_previous()` rather than
  being lost; the queue is bounded (count + size) and a terminal rejection is not
  retried. The sidecar uses the same guarded persistence as the identity record,
  so a host without durable storage falls back to in-memory for the process.
- Adds a manual emit API (`emit`, `emit_fatal`), a breadcrumb ring
  (`record_breadcrumb`, bounded to 50), a `diagnostics` hook + `snapshot()` for
  per-report outcomes, and both singleton and instance (`crash.new`) APIs.
- **Config is validated up front** at `crash.init` / `crash.new`: an `app_id` that
  carries PII/secret content, or a `platform` that is neither configured nor
  auto-detectable on the current runtime, fails initialization with a clear error
  (`invalid_app_id`, `platform_required`) instead of returning a client whose every
  later report would be dropped.
- This is an early alpha pre-release. The API is unstable and may change before v1.

## v0.3.0 — 2026-07-06 — early alpha

- Dual-mode ingest auth. The SDK now supports BOTH:
  - Mode B (existing): an async `token_provider` that yields a per-tenant
    ingest JWT (refresh, expiry-lead, 401-retry, in-flight race guard).
  - Mode A (new): a non-secret publishable `api_key` (the `sp_ingest_...`
    key, safe to embed client-side) used directly as the `Bearer` credential
    with no token round-trip. Configure `api_key` instead of `token_provider`.
  Mode is selected by presence: a configured `token_provider` takes effect
  (Mode B); otherwise the `api_key` is the standing Bearer (Mode A). Exactly
  one auth source is required — configuring both is rejected with
  `auth_mode_conflict`, configuring neither with `auth_required`.
- `anonymous_id` is ALWAYS sent on the wire for every source (client and
  service) in both auth modes; the server requires it.
- `track()` now lazily opens a session (synthesizing `session_id`) for
  non-backend sources, so events tracked before `session_start()` carry the
  `session_id` the server requires instead of being whole-batch rejected.
- Adds `get_anonymous_id()` (instance + singleton) so the host can read the
  persisted anonymous ID and hand it to its own backend at JWT-mint time. The
  SDK guarantees consistency — it sends, on the wire, the same anonymous ID it
  returns — but does not itself verify the backend's `bind_anon`.
- This is an early alpha pre-release. The API is unstable and may change before v1.

## v0.2.0 — 2026-07-06 — early alpha

- BREAKING: built-in helpers emit canonical wire event names. `session_start()`
  emits `app.session_started` and `screen_view(...)` emits `app.screen_view`.
  Helper API names are unchanged.
- Generates a UUIDv7 anonymous ID on first init and persists it through
  `sys.get_save_file("shardpilot.<workspace_id>.<app_id>", "identity")`
  (segments sanitized) with `sys.save`/`sys.load`, degrading gracefully to
  in-memory state when the Defold `sys` API is unavailable. The record is
  namespaced per configured app so two games on the same device never share
  an anonymous ID or consent decision.
- Adds `set_consent(analytics_granted)` with tri-state consent
  {unknown, granted, denied} persisted next to the anonymous ID. Denied drops
  events at enqueue, clears the pending queue, and discards in-flight batches
  on completion instead of retrying them. Explicit decisions are reported
  fire-and-forget to `POST {ingest_url}/v1/consent` over the same
  authenticated transport as the events batch; a decision made before an auth
  token is available is retained and sent at the next dispatch point.
- Parses the per-event status array in a `202` events-batch response
  (`{ accepted, rejected, duplicates, events:[{event_id, status, code, message}] }`)
  instead of assuming a `202` means full per-event success. Aggregate counters
  are kept on the snapshot and each non-accepted outcome
  (`observed`, `duplicate`, `rejected`, `suppressed_no_consent`) is surfaced
  through the new optional `diagnostics` config hook and `snapshot()`
  (`observed`, `suppressed`, `last_event_issue`), so integrators learn when
  their events are unregistered, blocked, or consent-suppressed. A `duplicate`
  is terminal and is never re-sent.
- Honors `429` backpressure: reads the `Retry-After` response header (whole
  seconds) and defers the next publish attempt by at least that long
  (clamped to a sane upper bound), retaining the batch. When the header is
  absent on a transient failure, falls back to exponential backoff with full
  jitter; a successful publish resets the backoff. A `401` still refreshes the
  token and retries immediately.
- Parses the `{ error: { code, message, details:[{field, code, message}] } }`
  envelope on a non-2xx response and surfaces `error.code` plus the detail
  codes via the `diagnostics` hook and `last_error`, instead of reporting only
  the bare HTTP status. No token material is included in the surfaced issue.
- This is an early alpha pre-release. The API is unstable and may change before v1.

## v0.1.1 — 2026-05-23 — early alpha

- Documentation re-cut. CHANGELOG and README cleaned up; library surface unchanged from v0.1.0.
- Defold dependency URL updated to recommend the v0.1.1 archive.
- This is an early alpha pre-release. The API is unstable and may change before v1.

## v0.1.0 — 2026-05-23 — early alpha

- Provides a pure Lua Defold library source SDK under `shardpilot/`.
- Includes Defold `game.project` library metadata with `shardpilot` as the include directory.
- Supports singleton and instance APIs for identity, sessions, screen views, custom events, updates, flush, and shutdown.
- Sends app-first batched event payloads to `{ingest_url}/v1/events:batch` without legacy public SDK fields.
- Keeps token and queue state in memory only, with Lua tests and static library checks.
- This is an early alpha pre-release. The API is unstable and may change before v1.
