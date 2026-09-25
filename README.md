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
- Point `ingest_url` at a ShardPilot ingest endpoint you have been given, or at
  a local stack you run yourself. Which endpoints are available today is stated
  under Configuration below and in [`docs/configuration.md`](docs/configuration.md);
  read that before configuring a hosted deployment.
- **Version `0.10.3`.** `game.project`, `shardpilot/version.lua`, and the top
  [`CHANGELOG.md`](CHANGELOG.md) entry all report `v0.10.3`; the `v0.10.3` tag
  is created by the owner after the version-bump merge (pending until then).

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
  `session_end([reason])` → `app.session_ended` (the next event after an end
  opens a new session; **Unreleased:** a background stay of
  `session_timeout_seconds` or longer ends the session at the resume, when the
  host forwards its window events to `on_window_event` — see
  [Offline durability](#offline-durability-event-spool)), `screen_view(name)` → `app.screen_view`, the typed
  progression verbs
  *(new in `v0.10.2`)*
  `track_level_start(level_id, attempt)` → `level_start`,
  `track_level_complete(level_id, attempt, duration_ms[, score])` →
  `level_complete` and `track_level_fail(level_id, attempt, duration_ms[,
  fail_reason])` → `level_fail`, the typed ad verb
  *(new in `v0.10.2`)*
  `track_ad_impression_revenue(impression_id, network, revenue_micros,
  currency[, revenue_precision, ad_unit, ad_format, placement])` →
  `ad_impression_revenue`, plus arbitrary `track(name, props)`.
- **Unreleased session helpers:** `session_end([reason])` is available on both
  a client and the module singleton. It ends only an open session; `shutdown()`
  uses `app_final` regardless of a legacy reason argument. See
  [session end reasons](docs/events.md#session-end-reasons) for defaults and
  background expiry.
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
published tag's source archive — after owner tagging, the latest tag is `v0.10.3`:

```ini
[project]
dependencies#0 = https://github.com/shardpilot/shardpilot-defold/archive/refs/tags/v0.10.3.zip
```

Note that no packaged release ZIP asset is attached to any GitHub Release yet —
the tag source archive above is the only hosted dependency URL. Tags are
normally created from the merge of the matching version-bump commit, so
immediately after that merge lands there is a short window in which the URL
404s.

**If it 404s, wait — do not pin an earlier tag.** `v0.10.1` is the deletion-only
patch that removes the two internal agent skills. Measured across every tag:
`v0.8.0`, `v0.8.1`, `v0.9.0`, `v0.9.1` and `v0.10.0` carry all eight of those
files through this same dependency URL, and `v0.6.0` and `v0.7.0` carry two of
them. `v0.5.0` and earlier predate the files entirely — but they also predate
most of what this README documents. This paragraph used to say "pin the previous
tag until the new one is published", which after `v0.10.1` pointed at exactly
the artifact being withdrawn.

The historical `v0.10.1` tag lacks request compression, the 15-second flush default, independent retry pacing, typed progression/ad verbs, and terminal rejection history. These are included in `v0.10.2`.

Then require the modules. **The policy module is the one the startup path
begins with** — see the quick start below and
[Consent regime](#consent-regime):

<!-- doc-region: none -- the two-line shape of the whole integration, not the flow itself -->
```lua
local consent_policy = require "shardpilot.consent_policy" -- resolve FIRST
local shardpilot = require "shardpilot.sdk"                -- init inside its callback
```

## Quick start

For a command-line sender using the checked-in SDK, see the
[headless evidence sender](examples/evidence-sender/README.md). With its environment
configured, run `.venv-evidence-sender/bin/python examples/evidence-sender/send.py`.

Minimal Defold script (see [`examples/minimal/`](examples/minimal)):

> **Policy first.** `consent_policy.prepare` is the first integration call and
> `shardpilot.init` runs **inside its callback**. Requiring the SDK is not the
> barrier — that only loads code; `init` is, because it builds the client,
> which loads the persisted scope record and mints an anonymous identifier.
> Calling it before the decision would create an identity for a player whose
> consent regime had not been established yet. A decision is **not** consent:
> it says which regime applies and whether the optional lane stays closed
> whatever the player answers — you still have to ask them. When the resolver
> is unreachable or answers something this build will not accept, the callback
> receives the strict fallback (`plan_used = false`), which tightens and never
> relaxes.
>
> ⚠ **`STRICT_OPT_IN` MEANS "ASK, DEFAULT OFF" — NOT "DO NOT ASK".** The
> resolver answers `STRICT_OPT_IN` to every request in this release. A host
> that reads that as silence never asks anyone and never starts analytics, for
> every player, forever — which is not the strict regime, it is no product. The
> regime decides the **default of the question** and the **basis the answer is
> recorded under**, never whether the question exists: `STRICT` and `UNKNOWN`
> put the choice with the switch **off** and open the optional lane only on an
> explicit grant; `SOFT_OPT_OUT` puts a prominent purpose notice with the
> switch **on** and one tap to turn it off. **Every fallback is strict** — ask
> with the default off under your own notice text, and a grant given under a
> fallback is a valid strict grant. That is also why flooding the policy route
> degrades nothing: strict still collects from the players who say yes.
>
> **Branch on the decision** — `analytics_choice_default` is the state of the
> switch when your screen opens; `explicit_grant_required` says whether a click
> is what opens the lane; `crash_profile` decides the crash lane on its own,
> and crash reporting is ON by default, so an unconditional `crash.init` is how
> a closed lane gets opened; `server_analytics` gates only your backend's lane.
>
> ⚠ **The values are the resolver's, and the plan is nested.** `flags` carries
> `crash_profile`, `server_analytics`, `child_rules` and `operation_blocks`;
> the vocabularies are lower-case (`off`, `minimal_diagnostics_for_minors`,
> `denied`, `minimised`). This SDK read a flat plan with upper-case values
> until it was checked against the resolver's actual bytes — and refused every
> real response as unreadable. The contract of record is the resolver's
> published `ConsentPolicyPlan` schema; `test/golden/` holds its output.
>
> **And resolve again on every named trigger** — after the player answers, on
> resume, at `valid_for_seconds`, and when the notice text or language changes
> — then make the running lanes match the fresh answer. A lane that is now
> closed is **suspended with `shutdown()`, never with `set_consent(false)` or
> `crash.set_enabled(false)`**: those record a player's decision, and nobody
> decided anything — the policy changed. See [Consent regime](#consent-regime).

> ⚠ **QUOTED FROM `examples/minimal/main.script`, NOT RETYPED FROM IT.** The
> blocks below are extracted byte for byte and
> `test/test_documented_regions.lua` fails when one of them drifts. This flow
> used to live in three places — the example, this section, and the packaged
> skill — and one review round found five findings that were the three copies
> disagreeing: an ordering fixed in one and not the others, retry state removed
> from one and left in another, a fallback rejected here that the example
> accepts. There is one copy now.
>
> The helpers this section does not quote — `suspend_analytics`,
> `suspend_crash`, `start_analytics`, `start_crash` — are in the example, and
> the packaged skill under `.claude/skills/` carries the whole file.

The state, and what each piece of it is for:

<!-- doc-region: state -->
```lua
-- ⚠ POLICY FIRST, AND ONE RECONCILE PATH FOR THE WHOLE LIFECYCLE. A consent
-- regime is not decided once at launch: the plan expires, the notice text
-- changes, the policy is revoked, the app comes back after a week. Every one
-- of those is the same question — resolve the policy again, then make the
-- running lanes match the answer — so there is exactly one function that does
-- it, and every trigger calls it.
--
-- The requires below are not the barrier — requiring shardpilot.sdk loads code
-- and creates nothing (sdk.lua:1-4). init() is: it builds the client, which
-- loads the persisted scope record and mints an anonymous identifier
-- (client.lua:763-787).
local consent_policy = require "shardpilot.consent_policy"
local platform = require "shardpilot.platform"
local shardpilot = require "shardpilot.sdk"
local crash = require "shardpilot.crash"

-- ⚠ "RUNNING" MEANS AN INITIALISED CLIENT EXISTS THAT HAS NOT BEEN SHUT DOWN.
-- It is lifecycle state, not a consent state, and final() reads it to know
-- what is still owed a shutdown.
local analytics_running = false
local crash_running = false

-- The player's standing answer, and the notice text it was given against. It
-- SURVIVES a suspension — a plan expiring is not a reason to ask again — and
-- is discarded only when the text or language changes, because then the answer
-- was given to a notice this player never saw.
local answered = nil
local notice_open = false
-- ⚠ THE SCREEN CAN BE OVERTAKEN. A notice is the one place in this flow where
-- an unbounded amount of real time passes with the player somewhere else, and
-- the world can change under it — most sharply when the host's age step
-- corrects the band to minor or unknown. The counter below rises when that
-- happens; an answer arriving from a screen opened under an older one is not
-- stored, because it belongs to a question this flow is no longer asking.
local notice_generation = 0

-- The plan's own deadline, in seconds on the clock below. Cache expiry
-- protects the next lookup and stops nothing that is already running.
local elapsed = 0
local revalidate_at = nil

-- ⚠ A VERDICT WITH NO LIFE IS NOT RUNNABLE, and scheduling by it directly is a
-- spin. max_age_seconds = 0 means "do not reuse this": it authorises the one
-- answer and nothing after it, so valid_for_seconds is 0 and there is no
-- window in which a lane could run. Re-resolving every frame is a flood
-- against the resolver dressed up as diligence, so the retry is bounded and
-- backs off.
local MIN_REVALIDATE_SECONDS = 30
local MAX_REVALIDATE_SECONDS = 300
local revalidate_backoff = MIN_REVALIDATE_SECONDS

-- ⚠ THE RETRY MACHINERY IS DELIBERATELY NOT HERE. A quick start that carried
-- a Mode B identify-retry state machine drew a finding in four consecutive
-- review rounds — every fix added state and the next round found the next
-- interleaving. What a production host owes is listed in the README under
-- "host requirements"; what this file shows is the straight path, which is
-- what a quick start is for.

-- Where this example parks a remote-config value; your game reads it wherever
-- it needs the tuned number.
local spawn_rate = 1.0
```

One context, resolved on every trigger, because several copies is how they
drift apart:

<!-- doc-region: policy-context -->
```lua
-- The policy context, in one place, because it is resolved on every trigger
-- and several copies is how they drift apart.
local function policy_context()
	return {
		endpoint = "http://localhost:8082",
		workspace_id = "workspace-example",
		app_id = "app-example",
		environment_id = "develop",
		app_version = "1.0.0",
		locale = "en",
		platform = platform.detect(),
	}
end
```

**The age step is yours and it comes first.** An unknown or minor band means
minimised handling: the analytics question is not put at all, and the crash
lane stays shut whatever the plan's `crash_profile` says.

<!-- doc-region: host-age-band -->
```lua
-- ⚠ YOUR AGE STEP GOES HERE, AND IT COMES FIRST. The policy endpoint is
-- public and credential-free, so it can never establish anyone's age; the band
-- is the host's own, and an unknown or minor band means minimised handling —
-- the analytics question is NOT put and nothing optional starts. Returning nil
-- means "unknown", which is what a quick start with no age step honestly is.
function host_age_band()
	return nil
end
```

**The screen is yours too.** The placeholder answers with the regime's own
default — off under `STRICT_OPT_IN`, on under `SOFT_OPT_OUT` — which is what a
player who closes it without touching the switch does. It answers from
`update()` rather than synchronously, because a real screen does.

<!-- doc-region: present-notice -->
```lua
-- ⚠ YOUR CONSENT UI GOES HERE. It is a GLOBAL so you can replace it with your
-- own screen — and so this repository's suite can drive both answers, which is
-- the only way the granted path is ever exercised.
--
-- Until you replace it, it answers with the REGIME'S OWN DEFAULT, which is
-- what a player who closes the screen without touching the switch does: off
-- under STRICT, on under SOFT. It also answers LATER, from update(), because a
-- real screen does — and an example whose notice answers synchronously gets
-- "nothing before the player's final choice" for free without exercising it.
local pending_notice = nil
function present_consent_notice(decision, callback)
	pending_notice = function()
		callback(decision.analytics_choice_default == consent_policy.CHOICE_DEFAULT_ON)
	end
end
```

**One reconcile path for the whole lifecycle.** Given a fresh decision, make
the running lanes match it: it CLOSES on its own authority and OPENS only on
the player's. Read it once and the rest of this section is commentary.

<!-- doc-region: reconcile -->
```lua
local reconcile

local function resolve_and_reconcile()
	consent_policy.prepare(policy_context(), reconcile)
end

-- ⚠ THE ONE PATH. Given a FRESH decision, make the running lanes match it.
-- It CLOSES on its own authority and OPENS only on the player's: a lane the
-- new decision permits still needs an answer, and a resume that could open a
-- lane would be a grant issued by a focus event.
reconcile = function(fresh)
	print("shardpilot consent regime: " .. tostring(fresh.regime) ..
		(fresh.plan_used and "" or " (strict fallback: " .. tostring(fresh.reason) .. ")"))

	-- (a) The notice the standing answer was given against. A different text
	-- version or language means the running grant belongs to a notice this
	-- player never saw, so it stops and the notice is presented again.
	-- ⚠ ONLY A PLAN CAN CHANGE THE NOTICE. A strict fallback carries no
	-- consent_text_version at all, so comparing against it read every outage as
	-- "the text changed" and threw away an answer the player really did give. A
	-- fallback still CLOSES — that is (b) below — it just does not erase the
	-- standing answer.
	if fresh.plan_used and answered
		and (fresh.consent_text_version ~= answered.text_version
			or fresh.presented_language ~= answered.language) then
		suspend_analytics("consent_text_changed")
		-- ⚠ AND THE CRASH LANE GOES WITH IT. The notice the player read is what
		-- the session rests on; a crash reporter left running under text nobody
		-- saw is the same defect as an analytics client left running under it.
		-- It restarts only after the new answer, through the pending-choice
		-- gate in (e).
		suspend_crash("consent_text_changed")
		answered = nil
	end

	-- (b) Whatever this decision closes, closes now.
	-- ⚠ A LANE THE PLAYER NEVER OPENED IS NOT ONE TO CLOSE HERE. The regime no
	-- longer closes the analytics lane by itself: what closes it is the age
	-- step below, or the player's own answer, or a suspension for one of the
	-- named triggers.
	--
	-- ⚠ BUT A REGIME THAT NOW REQUIRES AN EXPLICIT GRANT DOES CLOSE ONE GIVEN
	-- WITHOUT ONE. A non-objection recorded under SOFT is not an explicit
	-- grant, so when STRICT arrives the standing answer no longer satisfies the
	-- regime: the lane stops and the question is put again, with the default
	-- the new plan carries.
	-- No plan_used gate here, unlike the notice-text rule below: a FALLBACK is
	-- the strict regime, and it requires an explicit grant just as a strict
	-- plan does. A grant given explicitly survives a fallback; a non-objection
	-- does not.
	if answered and fresh.explicit_grant_required and not answered.grant_required then
		suspend_analytics("explicit_grant_now_required")
		answered = nil
	end
	if fresh.crash_profile ~= consent_policy.CRASH_MINIMAL then
		suspend_crash("crash_profile_off")
	end

	-- (c) The plan's own life. A fallback carries no validity and schedules
	-- nothing: it established nothing that could expire.
	if fresh.valid_for_seconds and fresh.valid_for_seconds <= 0 then
		print("shardpilot: the verdict has no validity window; no lane started")
		suspend_analytics("no_validity_window")
		suspend_crash("no_validity_window")
		revalidate_at = elapsed + revalidate_backoff
		revalidate_backoff = math.min(revalidate_backoff * 2, MAX_REVALIDATE_SECONDS)
		return
	end
	revalidate_backoff = MIN_REVALIDATE_SECONDS
	revalidate_at = fresh.valid_for_seconds and (elapsed + fresh.valid_for_seconds) or nil

	-- (c2) OPERATION BLOCKS CLOSE EVERYTHING, BECAUSE THIS QUICK START CANNOT
	-- READ THEM. They are restrictions no consent choice lifts — transfer, age
	-- and capacity, localisation, safety — and mapping a block NAME to the
	-- client action it restricts needs a vocabulary this file would have to
	-- invent. The module parses them and puts them on the decision; a quick
	-- start that then ignored them would let a player's grant open a lane the
	-- plan had just closed, which is the permissive default in its worst
	-- place. So: while the list is non-empty, NO lane opens — no question, no
	-- analytics, no crash — and the reason says which.
	--
	-- A production host does the mapping and refuses the restricted actions;
	-- an unmapped name closes everything, exactly as here. See the README's
	-- host requirements. In this release the resolver always sends [].
	if fresh.operation_blocks and #fresh.operation_blocks > 0 then
		print("shardpilot: the plan carries " .. #fresh.operation_blocks
			.. " operation block(s) this quick start cannot map ("
			.. table.concat(fresh.operation_blocks, ", ") .. "); no lane opened")
		suspend_analytics("operation_blocks")
		suspend_crash("operation_blocks")
		return
	end

	-- (d) The ANALYTICS lane.
	--
	-- ⚠ THE REGIME DECIDES THE DEFAULT OF THE QUESTION, NOT WHETHER IT IS
	-- ASKED. STRICT means ask with the switch OFF and start only on an
	-- explicit grant; SOFT means a prominent purpose notice with the switch ON
	-- and one tap to turn it off. An earlier cut of this example read STRICT as
	-- "nothing to ask" — and since the resolver answers STRICT to every request
	-- in this release, a host copying it would never ask anyone and never start
	-- analytics, for every player, forever.
	--
	-- The AGE step comes first and is the host's own: an unknown or minor band
	-- means minimised handling, so the question is not put at all.
	local band = host_age_band()
	local minimised = band == nil or band == "minor"
	if minimised then
		print("shardpilot: age band unknown or minor; minimised handling, no analytics question")
		suspend_analytics("minimised_handling")
		-- ⚠ AND THE CRASH LANE CLOSES WITH IT, HERE AND AT (e) BELOW. The
		-- comment at (e) claimed an unknown or minor band kept the lane shut
		-- while the code did nothing of the kind: `band` was local to this
		-- block and (e) was reached by fall-through, so a plan carrying
		-- crash_profile "minimal_diagnostics_for_minors" opened a crash
		-- reporter on a MINOR. That profile is a release-2 path needing a
		-- reviewed child flow this quick start does not have.
		suspend_crash("minimised_handling")
		-- ⚠ AND THE FRESH ANSWER DOES NOT SURVIVE THIS BRANCH. Suspending a
		-- lane leaves `answered` standing on purpose — a plan expiring is no
		-- reason to ask again — but an answer given moments ago under a band
		-- that has since been corrected is a different thing: keeping it meant
		-- that when the band later read eligible again, start_analytics
		-- recorded that grant WITHOUT PRESENTING A NOTICE. One screen, one
		-- answer, a correction in between, and a consent receipt written for a
		-- player who was never asked a second time.
		--
		-- WHICH STATE IS KEPT AND WHY: a standing decision that was already
		-- ESTABLISHED AND RECORDED survives (fresh_answer is nil once the
		-- receipt landed), because it belongs to a notice the player did see
		-- and a write that completed. Only the unrecorded, in-flight answer is
		-- discarded — and a notice still open is voided, so the answer that
		-- arrives from it is not stored either.
		if answered and answered.fresh_answer then
			answered = nil
		end
		if notice_open then
			notice_open = false
			notice_generation = notice_generation + 1
		end
	elseif not analytics_running then
		if answered then
			if start_analytics(answered.granted, fresh, answered.fresh_answer == true) then
				answered.fresh_answer = nil
			end
		elseif not notice_open then
			notice_open = true
			local generation = notice_generation
			present_consent_notice(fresh, function(granted)
				if generation ~= notice_generation then
					-- The band was corrected while this screen was open. The
					-- answer belongs to a question no longer being asked, and
					-- storing it is how it gets recorded later without asking.
					print("shardpilot: consent answer discarded; the age band changed "
						.. "while the notice was open")
					return
				end
				notice_open = false
				answered = {
					text_version = fresh.consent_text_version,
					language = fresh.presented_language,
					granted = granted,
					-- The BASIS the answer was given under. A non-objection
					-- does not satisfy a regime that requires an explicit
					-- grant, so the two are not interchangeable later.
					grant_required = fresh.explicit_grant_required,
					fresh_answer = true,
				}
				-- ⚠ RE-RESOLVE BEFORE ACTING ON THE ANSWER, AND INVALIDATE
				-- FIRST. The player was reading the screen; the plan may have
				-- expired or the policy may have been revoked meanwhile — and
				-- without the invalidation this resolution is answered by the
				-- private cache entry the LAUNCH wrote, which is the very
				-- decision being checked for staleness. It has to reach the
				-- resolver to mean anything.
				consent_policy.invalidate()
				resolve_and_reconcile()
			end)
			return
		else
			return
		end
	end

	-- (e) The CRASH lane, decided separately — the analytics answer does not
	-- close it, and a permitted crash profile does not open analytics. It is
	-- reached only once no choice is pending: the crash reporter is a capture
	-- hook, and the first-run guarantee is that none exists before the player's
	-- final choice.
	--
	-- ⚠ crash_profile "off" MEANS "THE RESOLVER OFFERS NO APPROVED CRASH
	-- PROFILE IN THIS RELEASE" — it is what every request is answered with
	-- today. It does NOT amend a host's own separately reviewed crash gate:
	-- a host that has one (its own basis, its own opt-out, minors forced off)
	-- keeps it running unchanged. A host WITHOUT one keeps the lane closed
	-- under "off", which is what this quick start does, because a quick start
	-- has no reviewed gate. Either way an unknown or minor band keeps it shut —
	-- `minimised` is that band, read above and tested here so the sentence is
	-- the code rather than a promise about it.
	if fresh.crash_profile == consent_policy.CRASH_MINIMAL and not crash_running
		and not minimised then
		start_crash()
	end

	-- The SERVER-SIDE analytics lane is a BASIS, not a toggle, and this example
	-- sends nothing on it. If your backend does, gate it on
	-- fresh.server_analytics, whose only value in this release is "denied".
	-- The objection route is manual — the rights page or the privacy address —
	-- and nothing in this SDK can record or satisfy it.
	if fresh.server_analytics == consent_policy.SERVER_ANALYTICS_DENIED then
		print("shardpilot: server-side analytics denied")
	end

	-- ⚠ THE NOTICE IS THE RESOLVER'S WORDS, CARRIED VERBATIM. It says what
	-- kind of answer this is; show or log it as your contract requires, and do
	-- not summarise it.
	if fresh.notice then
		print("shardpilot policy notice: " .. fresh.notice)
	end
end
```

For multiple independent clients, use the instance API instead of the
singleton:

<!-- doc-region: none -- the module surface, not the integration flow -->
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
| `remote_config_attributes_enabled` | `false` (dark) | Opt-in: fetches carry the attributes stored via `set_remote_config_attributes` as query parameters — only while consent is **granted** (unknown/denied fetch attribute-less). Requires `remote_config_url` — see [Remote config](#remote-config) |
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
| `rejection_capacity` | `64` *(new in `v0.10.2`)* | Retained per-event rejection entries (positive integer); see [Batch verdicts](#batch-verdicts). |
| `buffer_size` | `1000` | Max queued events (≥1); cross-SDK canonical default |
| `flush_interval_seconds` | `15` (was `1`) *(new in `v0.10.2`)* | How long a **partial** batch waits before publishing (>0). Not a heartbeat — an empty queue publishes nothing. A full `batch_size` publishes immediately and `flush()` on demand; retry pacing runs on its own clock and does not follow this value *(new in `v0.10.2`)*. |
| `session_timeout_seconds` | `30` **Unreleased** | A background stay this long or longer (>0, finite) ends the session at the resume, stamped at the moment the stay reached it (`reason = "idle_timeout"`), and starts the next session. Needs the host to forward window events to `on_window_event`. |
| `publish_timeout_seconds` | `2` | Per-request timeout (>0) |
| `request_compression_enabled` | `true` *(new in `v0.10.2`)* | Compress analytics batch bodies over 1 KiB with `Content-Encoding: deflate` (RFC 1950 zlib — see [Request compression](#request-compression)). Sub-threshold bodies go uncompressed: zlib framing makes a single-event batch bigger, not smaller. No-op on engine versions without the `zlib` module. |
| `token_refresh_lead_ms` | `60000` | Refresh lead before token expiry (≥0) |
| `spool_enabled` | `true` | Durable offline event spool ([details](#offline-durability-event-spool)); `false` also clears a previously persisted record at init |
| `spool_max_events` | `500` | Max spooled entries (≥1); oldest evicted first |
| `spool_max_bytes` | `262144` | Approx. spool size budget (1024–393216); oldest evicted first |
| `schema_revision` | built-in revision | Schema-set revision declared on batch ingest (`X-ShardPilot-Schema-Revision` request header); a string overrides the value, `false`/`""` stops declaring ([details](docs/configuration.md#schema-revision-declaration)) |

> `ingest.shardpilot.com` is a **planned** public domain and is not provisioned.
> Use local/develop endpoints until a release explicitly publishes production
> infrastructure. See [`docs/configuration.md`](docs/configuration.md).

## Batch verdicts

A `202` batch response is a transport completion, not confirmation that every event was accepted. The SDK retains each rejected event's ID, status, code, and message in an in-memory rejection ring (default 64 entries, configurable, oldest evicted first), while the rejection counter remains cumulative. A configured logger or observer handles diagnostics; otherwise the default channel warns for the first ten rejected events, then once per previously unseen code, retaining at most 64 code keys to bound both memory and session output. Logging limits never suppress the ring. Terminal rejections leave the retry spool and are not resent; accepted siblings settle once. Where a flush result is available, inspect its rejected count and retained entries even when transport completion succeeded. Use the public ring accessor for automatic publishes too. The ring is diagnostic history for this client instance, not durable storage or a retry queue; restarting the client clears it.

For the [ingest batch contract](https://docs.shardpilot.com/api/ingest/#batch-verdicts),
read `client:get_rejections()` or the initialized singleton's
`shardpilot.get_rejections()`. They return oldest-first copies containing
`event_id`, `status`, `code`, and `message`. Set `rejection_capacity` to a
finite positive integer (default `64`); invalid values fail initialization with
`invalid_rejection_capacity`. This surface is new in `v0.10.2`.

Defold keeps its Boolean `flush()` contract: `true` means transport work has
settled, even when a parsed `202` contains rejections. `snapshot().rejected`
counts the server's cumulative rejected totals; `last_event_issue` retains the
latest non-accepted status and code. The ring also records automatic publishes.
Only per-event `rejected` entries enter it; whole-batch errors and other statuses
continue through their existing counters and diagnostics. Configure
`diagnostics = function(issue) ... end` to replace the default `print` warnings.
Even if this hook mutates its issue or throws, the retained copy survives.

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
`platform`, `app_version`, `app_build`, and optional `props` and `context`.
Empty or absent event properties are omitted from new envelopes, so their wire
shape does not depend on how the host JSON encoder treats an empty Lua table.
Non-empty properties keep their values, including nested arrays.

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

  The table describes `persist()` **only when the spool is enabled**. With
  `spool_enabled = false`, `persist()` returns `false, "spool_disabled"`
  before it looks at experiment debt at all, so neither row can be returned —
  a host waiting for `experiments_pending` there would wait forever. The
  assignment-cache sync still runs first in that mode, so a spool-less
  configuration converges its cache; it is only the *reporting* that stops at
  `spool_disabled`. `shutdown()` is unaffected and keeps reporting both
  codes.

  Exposure debt also holds the **Mode B anonymous-id rotation**:
  `set_anonymous_id` refuses with `events_pending` while an experiment
  exposure is still owed, alongside the queue and spool conditions it already
  checked. Flushing the ordinary queue is not always enough — an exposure can
  stay owed behind earlier queue pressure — so a host that rotates identity
  must drain and retry rather than assume one flush cleared the way.

  One rotation refusal does **not** clear by draining:
  `set_anonymous_id` returns `false, "consent_evidence_unreadable"` when the
  retained consent-receipt trail on disk exists and could not be read, so a
  stored grant is being withheld for this session. That trail may hold a
  refusal by the CURRENT anonymous id, and rotating would carry the withheld
  grant onto a new one — where a healed trail's old-id receipts are treated
  as another actor's and dropped, reopening analytics against a refusal that
  was never resolved. Recovery is a **fresh decision**: call `set_consent`
  with the choice the user makes now, which supersedes whatever could not be
  read and releases the rotation. Flushing, waiting and retrying will not
  clear it — nothing is pending to drain. Re-asserting the id already in
  force is a no-op and is never refused.
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

**Recommended: forward your window events.** The SDK never installs global
listeners itself — on mobile an iconified app can be killed without `final()`
ever running. Defold keeps a **single** window listener (`window.set_listener`
replaces any previously set one), so add the call inside your existing
listener rather than registering a new one:

<!-- doc-region: none -- the Defold window listener, quoted from the engine API rather than from the example -->
```lua
window.set_listener(function(self, event, data)
  -- ... your existing resize/focus/iconify handling ...
  shardpilot.on_window_event(event)
end)
```

**Unreleased.** `on_window_event` does what `persist()` does on a background
signal (and returns its result), and it drives the automatic session boundary:

- **Which events count.** On mobile and web, focus lost and gained. On desktop,
  only iconify and deiconify: a focus loss there is alt-tab, and the game keeps
  running. The engine exports the iconify constant as `WINDOW_EVENT_ICONFIED`,
  while its documentation spells `WINDOW_EVENT_ICONIFIED`; either is accepted.
  Other events are ignored.
- **The boundary.** A background signal records a pause of the open session.
  On the foreground signal, a stay of `session_timeout_seconds` (30 s) or
  longer ends that session with `reason = "idle_timeout"`. The end is stamped
  at pause + timeout, never before the session's own last event. The next
  session starts at once. Host activity that arrives past the deadline, before
  the foreground signal, runs the boundary first. Below the timeout, nothing
  happens. The startup focus gain is nothing.
- **A session that opens in the background is paused from its own start.**
  That covers the next session after a boundary run by host activity, a
  `session_start()`, and a session the next event opens. A second stay of
  `session_timeout_seconds` or longer therefore ends it too, stamped
  `session_timeout_seconds` after it opened and never before its own last
  event. A session started by the foreground signal is not paused.
- **Nothing after the deadline belongs to the paused session.** Frames and
  network samples observed after it, while still in the background, are
  dropped, and its perf summary's duration ends at the end instant.
- **What it never does.** A session you ended or replaced during the stay is
  not ended by it. `session_end()` or `shutdown()` over an expired pause gives
  that single end, and opens no session only to end it. A `session_start()`
  over an expired pause ends the timed-out session first, then starts the one
  next session. With consent not granted, it closes the session locally and
  sends nothing.
- **Elapsed time** is the larger of wall time and the summed `update(dt)`, so
  a backward clock correction is covered while frames run (a minimised desktop
  game).
- ⚠ **Limit: a backward clock correction during a mobile stay.** No frames
  run while a mobile app is suspended, and pure Lua reaches no monotonic clock.
  So a backward wall-clock correction during a mobile background stay can hide
  an expired boundary, and the two sessions merge.
- ⚠ **Limit: a kill in the background.** An app killed in the background sends
  no end. Its session ends at its last event.

Events persisted this way are removed from the spool as soon as their normal
delivery is acknowledged, so the snapshot costs nothing when the app keeps
running.


## Request compression

*(New in `v0.10.2`; `v0.10.1` sends every body uncompressed.)*

Analytics batch bodies over 1 KiB are compressed with
`Content-Encoding: deflate`. A batch body is the same envelope keys repeated
per event — close to the best case deflate has — so a full batch comes down to
a few percent of its size. Bodies under the threshold are sent as-is, because
zlib framing costs 6 bytes before the deflate stream's own overhead and makes a
single-event batch bigger rather than smaller.

**Why `deflate` and not `gzip`, when the other ShardPilot SDKs send gzip.** The
engine's `zlib` module produces RFC 1950 zlib framing and nothing else. Framing
gzip by hand needs a CRC32 over the whole uncompressed batch, and there is
nothing to borrow — zlib's own trailer is Adler-32, a different checksum — so
it would mean a pure-Lua CRC32 over tens of kilobytes on the flush path: a
frame hitch traded for the bytes this feature exists to save. The ingest server
reads RFC 1950 on the `deflate` coding for exactly this reason. It is the same
lane, the same body cap, and the same refusal codes as the gzip SDKs.

Three things worth knowing:

- **The ingest body cap applies to the UNCOMPRESSED body.** Compression buys
  throughput, not headroom — keep sizing against `batch_size` as before.
- **A deployment that cannot read the coding never costs you events.** It
  answers `400` with detail code `unsupported_content_encoding`; the client
  stops compressing for the rest of the session and **keeps** the batch,
  re-sending it uncompressed on the next tick. An encoding refusal is the one
  ordinary 400 this SDK does not treat as terminal, because the next attempt
  sends different bytes. The match is on that detail code and never on the bare
  400 — an unrelated validation failure must not change your transport, nor
  start retaining batches the server rejected permanently.
- **Engine versions without `zlib` simply do not compress.** The module is
  feature-detected; its absence is an ordinary uncompressed publish, never an
  error.

Set `request_compression_enabled = false` to opt out entirely.

## Remote config

<!-- doc-region: none -- the remote-config API, which the flow only parks a value from -->
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
- **Targeting attributes (dark opt-in) are the one
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

<!-- doc-region: none -- the configuration table, whose fields this section documents one by one -->
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

<!-- doc-region: none -- the experiments API, which the minimal example does not use -->
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

-- Record a host-defined outcome. `outcome_value` must be a FINITE number
-- (NaN and infinities are rejected -- JSON cannot carry them).
-- Returns ok, err.
shardpilot.track_outcome("menu_layout", "purchase_value", 4.99)
```

| Call | Returns | Failure codes you can branch on |
|---|---|---|
| `fetch_experiment_assignment(key, [attributes], callback)` | `true` = dispatched, or `false, err` = refused before dispatch; the assignment arrives through `callback` unless `shutdown()` cancels it first | pre-dispatch: `not_initialized`, `shutdown`, `experiments_not_configured`, `experiment_key_required`, `consent_unknown`, `consent_denied`, `http_unavailable`, `json_unavailable`. In the callback's `result.error`: `unauthorized`, `not_found`, `bad_request`, `malformed_response`, `stale_subject`, `superseded`, `consent_unknown`, `consent_denied`, `consent_changed`, `http_0`, `transient_408`, `transient_429`, `transient_<5xx>`, and `http_<status>` for anything unclassified |
| `experiment_variant(key)` | variant key `string`, or `nil` | — (never fails) |
| `experiment_payload(key)` | the variant payload (a copy), or `nil` | — (never fails) |
| `track_exposure(key)` | `ok, err` | `not_initialized`, `shutdown`, `experiments_not_configured`, `experiment_key_required`, `no_assignment`, `consent_unknown`, `consent_denied`, `exposure_no_subject_fact_key`, `queue_full` |
| `track_outcome(key, outcome_key, outcome_value)` | `ok, err` | the `track_exposure` codes plus `invalid_outcome_key` (non-empty string required) and `invalid_outcome_value` (a **finite** number required — `NaN` and `±inf` are rejected) |

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
  batch → spool → consent gates). When the assigned variant is first applied
  the SDK emits an `experiment_exposure` for you; `track_exposure` emits an
  extra one on demand, and `track_outcome` records host-defined numeric
  outcomes.

  **Treat exposure delivery as best-effort, and the `diagnostics` hook as the
  place you learn otherwise.** Facts carry a deterministic `event_id`, so the
  server counts retries of the same fact once. **Unreleased:** a consent denial
  closes the session; after re-grant, retained assignments re-arm into the
  fresh session and use its distinct exposure ID. Those are separate facts,
  not duplicate sends of the pre-denial exposure. Under sustained queue
  pressure the SDK sheds owed exposures rather than growing without bound.
  Automatic exposure failures surface on the hook as
  `status = "exposure_skipped"` with a `code` naming the reason. Watch it if
  the measured population matters to you.

  Two specific gaps worth knowing by name, because neither is an error from
  your point of view:

  - An applied treatment emits **no** exposure at all when the assignment
    carries no server-supplied attribution key — a synthetic-unit answer, for
    instance. The variant still applies; only the measurement is skipped,
    because the SDK-minted subject id must never reach the analytics plane.
    Reported as `code = "no_subject_fact_key"` on the hook. The distinct
    `exposure_no_subject_fact_key` value is the `err` returned from an
    explicit `track_exposure` / `track_outcome` call — monitoring only that
    one misses every automatic skip.
  - The platform currently rejects these fact names from game-embedded
    publishable keys by design, so an emitted exposure is expected to come
    back as a per-event reject until that producer lane opens. Surfaced
    through the same hook and otherwise tolerated silently.

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

## Consent regime

`shardpilot/consent_policy.lua` answers one question before the SDK exists:
**which consent regime applies to this player**. It is a standalone module —
it imports nothing from this SDK, so preparing a regime cannot mint an
identifier, load a spool or install a capture hook.

<!-- doc-region: none -- the consent-policy module surface, listed field by field below -->
```lua
local consent_policy = require "shardpilot.consent_policy"

consent_policy.prepare(context, function(decision) ... end)
```

`context` is validated locally before anything is sent, and a value outside
its closed vocabulary **costs no request**: `endpoint` (the same URL rule
`ingest_url` and `crash_ingest_url` obey — **https anywhere, plain http only
for a loopback host**, no userinfo, query, fragment or path), `workspace_id`, `app_id`, `environment_id`,
`app_version`, `locale`, `platform` (use `platform.detect()`), and optionally
`store` and `age_band` — which is accepted, sent as given, and **ignored by
the resolver in this release**. `store_region` is **not accepted** in this release: a
non-null value carries a country claim, and refusing it here is what stops it
travelling.

The callback receives **exactly one decision, exactly once**:

| Field | Meaning |
|---|---|
| `regime` | `STRICT_OPT_IN`, `SOFT_OPT_OUT` or `UNKNOWN` |
| `crash_profile` | `off` or `minimal_diagnostics_for_minors` |
| `server_analytics` | `denied` — the only value this release's contract names |
| `child_rules` | `minimised` — the same |
| `notice` | The resolver's own words about what kind of answer this is. Show or log it verbatim; the SDK does not interpret it |
| `band_vocabulary` / `band_vocabulary_version` | The age scale the resolver **declares it speaks** — a constant, not an echo. Delivered verbatim and compared with nothing: in this release the resolver does not read your `age_band` at all, and says so by naming `age_band` among the unavailable `signals_used`. Your own age step governs the age-first flow |
| `analytics_choice_default` | `off` for `STRICT_OPT_IN`, `UNKNOWN` and **every fallback**; `on` only for a used `SOFT_OPT_OUT` plan. This is the state of the switch when your screen opens — not whether to open one |
| `explicit_grant_required` | `true` for strict, unknown and every fallback: the optional lane starts **only** after the player's explicit grant, and an untouched or declined choice starts nothing. `false` only for a used SOFT plan, whose basis is notice and non-objection — recorded as such, never as a click |
| `plan_used` | `false` means the strict fallback was taken; `reason` says why |
| `operation_blocks` | The operation restrictions the host must enforce. **Unreleased:** always a list, retaining the last accepted plan's set on fallback; `[]` when none is known |
| `operation_blocks_source` | **Unreleased:** `plan` for an accepted plan, including a cache hit; `preserved` for a fallback retaining that plan's set (even `[]`); `none` when no plan is known for this context |
| `valid_for_seconds` | How long this verdict is good for — the shortest of the cache ceiling, the plan's `expires_at` and its `max_age_seconds`. **Schedule your own re-resolution by it:** cache expiry protects the next lookup and stops nothing that is already running. `nil` on a fallback, which established nothing that could expire |

**The conservative rule.** A plan that is missing, unreadable, out of scope,
**expired**, or carrying anything outside its bounded vocabulary resolves to
`STRICT_OPT_IN` with optional processing closed. An error or an offline state
can preserve or add restrictions; it can never relax one, and it can never
reuse a cached permissive result.

**Operation-block retention (Unreleased; not in v0.10.3).** The module remembers
the complete block list from the last accepted plan for the active context,
independently of the response cache and its lifetime. Every newer accepted
plan replaces that list, including with `[]`; a refusal, timeout, malformed
response or rejected signature preserves it. Ordinary `invalidate()` also
preserves it. This is retained restriction state, not permission to process.
Plans still require `signature: null`; this change adds no signature verification.

Selecting a different **validated** context clears the remembered list and
fences earlier requests. The context includes workspace, app, environment,
app version, locale, platform, store, endpoint and both age-band fields.
Returning to a previous context starts fresh; the module keeps no history of
inactive contexts. An invalid context gets `[]` and does not change the active
context. Each returned list is a copy, so a caller cannot edit retained state.
**A module reload or process restart followed by an outage starts with `[]`.**

**Caching** is in memory, for this session only, never written to disk, and
scoped to the *whole* context — a different app, environment or endpoint is
re-resolved rather than served the previous one's answer. An entry never
outlives the shorter of five minutes, the plan's own `expires_at` and its
`max_age_seconds`.

⚠ **And a permissive decision is never cached at all.** Anything that opens a
lane — a `SOFT_OPT_OUT` regime, a `MINIMAL` crash profile, an `ELIGIBLE`
server-analytics basis, or a lifted objection requirement — is used for the
`prepare` call that fetched it and is not stored. Every later `prepare` for
that context goes to the wire, and a request that fails, times out or finds no
network answers **strict**. Only a fully closed decision may be reused within
its lifetime, because reusing "closed" can never open anything. This is the
only way *"an offline state can tighten but never relax"* can actually hold:
the presence of `http.request` says nothing about connectivity, and Defold
offers no reliable online signal, so there is no moment at which the SDK could
know a stored permission is still true. The cost is **one request per
`prepare` while the regime is permissive** — and `prepare` is called at start,
on resume and at expiry, not per frame. Today it costs nothing at all, because
the resolver's initial release emits only strict plans.

### The age step, and the two things it decides

⚠ **The age step comes first, and it is yours.** The policy endpoint is public
and credential-free by construction, so it can never establish anyone's age —
the SDK never sees a trusted one. An **unknown or minor** band means minimised
handling: the analytics question is **not put**, nothing optional starts, and
the crash lane stays closed. An eligible band from your own age step leads to
the choice, with the default the decision carries.

`flags.child_rules` is delivered verbatim and is `minimised` on every response
in this release. Read it as what it is: the public bootstrap cannot establish
age, so the minimised-mode prohibitions — no advertising identifiers, no
profiling, no experiments, no third-party optional sharing — stand for
**everyone** in this release, while the first-party analytics choice is
governed by your age step and the regime's default.

`flags.crash_profile` is `off` on every response too, and that means **the
resolver offers no approved crash profile in this release** — not that crash
reporting must stop. A host with its own separately reviewed crash gate (its
own basis, its own opt-out, minors forced off) keeps that gate running
unchanged; generic policy flags do not amend it. A host **without** one keeps
the crash lane closed under `off`, which is what the minimal example does,
because a quick start has no reviewed gate. Either way, an unknown or minor
band keeps it shut.

### What the minimal example does not do — host requirements

[`examples/minimal/main.script`](examples/minimal) is a **quick start**, not a
production integration. Three lifecycle obligations are deliberately left to
the host, because they belong to an application's own teardown discipline
rather than to a twenty-line illustration. A production integration must
implement all three.

- **Retry `crash.shutdown()` until it succeeds before treating a `CRASH_OFF`
  closure as enforced.** It returns `false, "pending"` while a crash POST is in
  flight, and the host must keep pumping `http.update` and retrying; until it
  returns true the reporter is still live, so the lane is not actually closed.
  The example keeps the state and retries at teardown, which is enough to show
  the shape and not enough to guarantee the closure.
- **Keep `analytics_running` until `shardpilot.shutdown()` returns true, retry
  it, and never `init()` over a live client.** The analytics client has the
  same pending posture, and a re-`init` while one is still settling produces
  two clients over one spool.
- **A cached decision can outlive its window if the wall clock steps
  backwards.** Only fully closed decisions are cached, so the worst this does
  is keep a *closed* answer alive longer than its plan — the safe direction —
  and the SDK no longer guards against it. A host that needs the window to be
  exact should re-resolve on its own schedule rather than trusting
  `valid_for_seconds` across a clock change.
- **Check notice compatibility BEFORE paying an owed consent write.** A failed
  `set_consent` leaves a debt; if the next decision carries a different
  `consent_text_version` or `presented_language`, paying that debt records the
  **old** answer against text the player never saw. Discard the debt with the
  answer and present the notice again. (The minimal example applies the same
  invariant at `examples/minimal/main.script:276`, where a plan whose text
  version **or** language has moved discards the stored answer rather than
  reusing it.)
- **Map every `operation_blocks` name to the action it restricts, and refuse
  that action.** These are restrictions no consent choice lifts, so a grant
  does not open what a block closed. An **unmapped** name closes everything —
  no question, no analytics, no crash — which is what the minimal example does
  for every name, because a quick start has no vocabulary to map them with. In
  this release the resolver always sends `[]`.
- **Own the Mode B identity and consent retries.** The quick start does not
  carry them, deliberately — it shows the straight path. A production host
  must: mark the client as existing **before** calling `identify`, so a later
  resolution never builds a second one over the first; drain and retry
  `identify` on the **existing** client after `events_pending`; create consent
  debt only for a **fresh** answer, never for a restored grant, which goes
  through the session-start path instead.
- **Retry an owed `session_start` after a grant is recorded.** A grant whose
  receipt landed but whose `session_start` did not leaves the lane open with
  no session behind it; the example does not track that debt, and a production
  integration must retry the start or record that it never happened.
- **Retry or surface a failed background snapshot.** `persist()` on focus loss
  can fail — a full or unwritable spool — and the example neither retries it
  nor reports it, so events it was meant to save are lost silently on a kill.
- **Retry a pending grant only against a fresh decision that still permits
  analytics and still matches the answered notice.** Retrying an owed
  `set_consent` is entirely the host's responsibility; the quick start reports
  the refused write and performs no retry. Before retrying, a production
  integration must confirm that the newest decision still
  opens the lane and still carries the `consent_text_version` and
  `presented_language` the player answered, or a write owed under one policy
  lands under another.
- **Fence superseded same-context resolutions in the host.** The module
  refuses a response from an older dispatch for the same context, so a stale
  *policy* cannot deliver — but the host's own callbacks are not fenced: two
  reconcile paths in flight can still apply out of order. A production
  integration keeps a resolution generation and ignores any callback that is
  not the newest.
- **Back off after a transient strict fallback while foregrounded.** A
  fallback carries no `valid_for_seconds`, so nothing is scheduled and the
  next resolution waits for an unrelated trigger. A host that wants to recover
  from a brief outage needs its own bounded, backed-off retry.
- **Fence asynchronous callbacks and remove the window listener in
  `final()`.** A policy resolution or a notice answer that arrives after
  teardown will happily start a lane on a torn-down script; the host needs a
  generation or a disposed flag that every callback checks, and must clear the
  listener it installed.

`consent_policy.invalidate()` is what the host calls on the named
re-resolution triggers — launch and resume, a network or permitted storefront
change, an age correction, a language or text change, a workspace or app
change, a policy revocation, and before the first optional admission. A
request already in flight when it fires can no longer answer.
In the Unreleased implementation, invalidation preserves known operation
blocks; only a newer accepted plan, a validated context change or module
reload/process restart can replace or forget them as described above.

**Plan text is read before it is decoded.** Defold's `json.decode` returns a
plain table for both `{}` and `[]` and marks neither, so the container type is
erased by the decode — an object supplied where the schema says a list would
read as an empty list. The raw response is therefore scanned first, with a
JSON-aware walk that unescapes each key before comparing it (a literal search
is bypassed by `"operation\u005fblocks"`) and skips every value whole, so a
key of the same name nested in another object is not mistaken for the
top-level one.

> `SOFT_OPT_OUT` parses but is **not reachable today**: every row of the
> jurisdiction matrix is pending counsel confirmation, so the resolver's
> initial release has no path that emits it.

## Privacy & consent

- **Tokens are memory-only.** Auth material is never written to disk. The live
  event queue is in-memory; only undeliverable event envelopes are persisted,
  to the bounded offline spool
  ([above](#offline-durability-event-spool)) — set `spool_enabled = false` for
  a fully memory-only event path.
- **Durable storage is nine small bounded records** per configured app — the
  last three only ever created by the features that own them (a consent
  denial, and a run with `experiments_enabled` on): the
  identity record (anonymous ID + consent decision; plus, when a decision has
  superseded a consent trail this device could not read, **the timestamp of that
  decision, which kind of act it was** — `"decision"` for a choice the player
  made, `"receipt"` for an earlier choice recovered from an undelivered receipt —
  **and that decision's per-install sequence number**, which orders two such acts
  that share a second; retained so a consent record can say where it came from; plus, once a run with
  `experiments_enabled` has minted one, the SDK-minted experiment subject id,
  which every later identity rewrite carries forward **even on launches with
  the flag off**; so clearing only the two experiment records below does not
  remove every persisted experiment identifier), the offline event spool
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
  survives a crash mid-purge; no analytics payload — it carries the denial and,
  when that denial superseded an unreadable consent trail, the same provenance
  pair the identity record holds, so the fact is not lost if the identity write
  is what failed), and — created only by a
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
  offline spool. **Unreleased:** denial also closes the current session locally
  and discards its pending background deadline. After a re-grant, the next
  resume or tracked activity announces a distinct session; no end is emitted
  for the denied interval. `"denied_forced_minor"` — the persisted decision for
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
| `shardpilot/consent_policy.lua` | Consent-regime preparation before SDK init; imports nothing from this SDK |
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
| `test/` | Lua test harness: every `test/test_*.lua`, which is also exactly what CI runs + Defold collection/script |
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
