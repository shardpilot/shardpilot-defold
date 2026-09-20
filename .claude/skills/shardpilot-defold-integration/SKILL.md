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
  durable last-known-good cache and typed getters. No automatic refresh —
  every fetch is an explicit call.
- **Experiments (off by default)**: a server-evaluated variant assignment
  consumer behind `experiments_enabled = true`, which also requires
  `remote_config_url` AND `api_key`. It requires analytics consent `granted`,
  and fails closed (no variant served, getters `nil`) until experiments are
  enabled server-side for the app — so a build with the flag on simply runs
  the control experience. See the README's "Experiments" section and
  `docs/configuration.md`.
- **Crash reporting**: a separate `shardpilot.crash` module posting crash
  report JSON to a dedicated crash ingest endpoint, with PII scrubbing,
  write-ahead pending storage, and deterministic non-fatal sampling.
- **Not provided today**: no automatic remote-config refresh, no packaged
  release ZIP assets (source archives
  only). (Live Lua script-error capture IS available as the opt-in
  `script_error_capture_enabled` crash flag, default off — see the crash
  section.)
- **Pre-launch**: the production ingest domain is not provisioned yet; use
  local/develop endpoints. The SDK is v0 alpha and the API may change before
  v1.

## Install

Version pin (CI-checked): this skill matches shardpilot-defold `v0.10.2`.

This version includes request compression, a 15-second flush default, independent retry pacing, typed progression/ad verbs, and terminal rejection history; these were absent from `v0.10.1`.

Two supported paths:

1. **Vendor the `shardpilot/` directory** into your project. Copy the whole
   directory; it is self-contained Lua source. (This repo's
   `[library] include_dirs = shardpilot` line in `game.project` exists to
   expose the folder to dependency consumers — you do not need it in your own
   game when vendoring.)
2. **Pin a Defold library dependency** to a published tag's source archive:

```ini
[project]
dependencies#0 = https://github.com/shardpilot/shardpilot-defold/archive/refs/tags/v0.10.2.zip
```

`v0.10.2` is the version this skill matches, and it is the same pin the
README's Installation section carries.

The earlier off-main `v0.10.1` tag still declares `0.10.0`; see the [changelog](../../../CHANGELOG.md).

Ordinary tags DO come from the merge of the matching version-bump commit, never
before it, so for those there is a short window right after the merge in which
the URL above does not resolve yet — if it 404s, WAIT for the tag rather than
pinning an earlier one. `v0.10.0` and
the other affected tags still contain internal material that `v0.10.1` exists to
stop distributing, so falling back would download exactly what the patch
removed. Note there
is no packaged ZIP asset attached to any GitHub Release — the tag source
archive is the only hosted dependency URL. Pin a tag rather than tracking
`main` so your build does not shift under you between releases.

Then:

<!-- doc-region: none -- the dependency line, not the integration flow -->
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

⚠ **`shardpilot.init` is NOT the first call. `consent_policy.prepare` is, and
`init` belongs inside its callback.** Requiring the SDK only loads code; `init`
builds the client, which loads the persisted scope record and **mints an
anonymous identifier** — an identity created for a player whose consent regime
has not been established yet. Resolve the policy first, and initialise only
when the decision permits it:

> ⚠ **THIS IS NOT A SNIPPET TO ADAPT — IT IS `examples/minimal/main.script`,
> QUOTED.** Every block below is extracted from that file byte for byte and
> `test/test_documented_regions.lua` fails if one of them drifts. The flow used
> to be written three times — there, in the repository README, and here — and a
> single review round found five findings that were the same flow drifting
> apart. Change the example; the documents follow.
>
> Replace the placeholder values (`workspace-example`, `user-example`, the
> localhost URLs) and the two globals — `host_age_band` is your age step and
> `present_consent_notice` is your screen. Nothing else needs editing to run.

The state the flow keeps, and why each piece of it exists:

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

One context, resolved on every trigger:

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

**The two globals you replace.** The age step comes first and is yours; so is
the screen. The placeholders below answer with the regime's own default, which
is what a player who closes the screen without touching the switch does:

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

**Closing a lane is not a player decision.** A lane the policy closes is
stopped with `shutdown()` — never `set_consent(false)` or
`crash.set_enabled(false)`, which record a decision nobody made:

<!-- doc-region: suspend-analytics -->
```lua
-- ⚠ SUSPENDING A LANE IS NOT A PLAYER DECISION, AND MUST NOT BE WRITTEN AS
-- ONE. set_consent(false) records and persists an explicit denial and queues
-- its backend receipt; crash.set_enabled(false) persists an opt_out that
-- outlives the launch. Neither happened here: the POLICY changed, nobody
-- chose anything. shutdown() stops the client, writes no choice, and leaves
-- the player's standing answer intact for the next permissive plan.
local function suspend_analytics(reason)
	if not analytics_running then
		return
	end
	print("shardpilot: analytics suspended (" .. reason .. ")")
	local ok, err = shardpilot.shutdown("policy_" .. reason)
	if not ok then
		print("shardpilot suspend not complete: " .. tostring(err))
	end
	analytics_running = false
end
```

<!-- doc-region: suspend-crash -->
```lua
-- ⚠ shutdown() CAN SAY "NOT YET". A crash POST dispatched in the real runtime
-- completes on a later frame, so while one is in flight shutdown returns
-- false, "pending" — the client is still initialised and still needs pumping.
-- Clearing the flag anyway would lose the retry: final() would skip it, and a
-- later start_crash would init over a client that never finished. So the flag
-- means "a client exists that has not finished shutting down", and it is
-- cleared only when shutdown says so.
local function suspend_crash(reason)
	if not crash_running then
		return
	end
	local ok, err = crash.shutdown()
	if ok then
		print("shardpilot: crash reporting suspended (" .. reason .. ")")
		crash_running = false
	else
		print("shardpilot: crash shutdown pending (" .. tostring(err) .. "); retrying")
	end
end
```

**Opening the analytics lane.** `init` builds the client and mints an
anonymous identifier, so it happens here and not at launch. Under Mode B
`identify` can refuse with `events_pending`; the answer is then not recorded
and nothing starts, and draining and retrying is yours — see the README's
host-requirements list:

<!-- doc-region: start-analytics -->
```lua
-- `newly_answered` is true only when a notice has just been completed. A
-- RESTORED answer re-initialises the client and stops there: client.new reads
-- the persisted consent decision back (client.lua:789-805), so calling
-- set_consent again would re-persist a decision nobody made twice and enqueue
-- a second receipt for it — a policy suspension would show up in the consent
-- trail as a player changing their mind.
-- Returns whether the fresh answer was CONSUMED — false means the write is
-- owed and the caller must keep it pending.
local function start_analytics(granted, decision, newly_answered)
	-- ⚠ init CAN FAIL, and a lane marked running on a client that was never
	-- built is a lane final() will try to shut down and update() will try to
	-- drive.
	local started_ok, start_err = shardpilot.init({
		ingest_url = "http://localhost:8080",
		workspace_id = "workspace-example",
		app_id = "app-example",
		environment_id = "develop",
		token_provider = function(callback)
			callback("client-token-placeholder", nil, nil)
		end,
		-- Remote config (optional). A separate endpoint from ingest_url; it
		-- authenticates with the publishable api_key, so enabling it under
		-- Mode B requires the api_key too. See docs/configuration.md.
		remote_config_url = "http://localhost:8081",
		api_key = "sp_ingest_publishable_placeholder",
	})
	if not started_ok then
		print("shardpilot init failed: " .. tostring(start_err))
		return false
	end
	analytics_running = true

	-- ⚠ identify CAN REFUSE. Under Mode B, switching identity while the
	-- previous one still has undelivered events returns false, "events_pending"
	-- (client.lua:2124-2126): those envelopes were unlocked by a credential
	-- minted for the OTHER subject, so sending them after the switch would
	-- misattribute them. Draining them — flush, then re-identify — is the
	-- host's business and this quick start does not do it. What it must not do
	-- is record a consent decision for an identity the client did not accept.
	local identified, identify_err = shardpilot.identify("user-example")
	if not identified then
		print("shardpilot identify refused: " .. tostring(identify_err) ..
			"; flush and re-identify before recording consent (the host's to do)")
		return false
	end

	if not newly_answered then
		-- ⚠ A RESTORED GRANT STILL NEEDS ITS SESSION. The client is new; the
		-- consent decision came back from disk with it, but the session did
		-- not. Starting one without set_consent is the point: the decision is
		-- restored, not re-made.
		if granted then
			shardpilot.session_start()
		end
		return true
	end
	-- Each explicit decision posts a consent receipt kept in a durable outbox
	-- until the server acknowledges it, so a decision made offline still
	-- reaches the backend on a later launch. A DECLINE is recorded the same
	-- way — or set_consent("denied_forced_minor") when your age gate forces it
	-- (feature-detect with
	-- shardpilot.supports("consent_state_denied_forced_minor")).
	-- ⚠ UNDER A SOFT PLAN THE BASIS IS NOTICE AND NON-OBJECTION, WHICH IS NOT
	-- A CLICK. set_consent records a player's explicit decision, so using it
	-- for a non-objection would write down a grant nobody gave. This SDK has no
	-- API for that basis and this quick start does not invent one; the
	-- resolver cannot emit SOFT in this release, and a host that meets one must
	-- record the basis through its own path.
	if not decision.explicit_grant_required then
		print("shardpilot: SOFT regime — record the notice/non-objection basis yourself; " ..
			"set_consent is for an explicit decision")
		return true
	end

	-- ⚠ set_consent CAN FAIL TOO — a full consent outbox, a failed durable
	-- write. Starting the session anyway would emit events under a grant that
	-- was never recorded, which is the one ordering the consent outbox exists
	-- to prevent. The answer stays pending and is retried on the next trigger.
	local recorded, consent_err = shardpilot.set_consent(granted)
	if not recorded then
		print("shardpilot consent not recorded: " .. tostring(consent_err) ..
			"; owed (retrying it is the host's — see the README)")
		return false
	end
	if granted then
		shardpilot.session_start()
	end

	-- Remote config: fetch explicitly (the SDK never fetches on its own).
	-- Getters serve the durable last-known-good snapshot immediately —
	-- including offline and before this fetch completes — and the caller's
	-- default until any configuration is available.
	shardpilot.fetch_remote_config(function(result)
		if not result.ok then
			print("shardpilot remote config unavailable: " .. tostring(result.error))
		end
	end)
	spawn_rate = shardpilot.remote_config_number("spawn_rate", 1.0)
	return true
end
```

**The crash lane is decided separately** and its flag comes from `crash.init`'s
own result, because a `crash_running` that lies makes `final()` shut down a
reporter that was never created:

<!-- doc-region: start-crash -->
```lua
local function start_crash()
	-- A separate module, endpoint, and crash:write key — see docs/crash.md.
	-- init auto-forwards a previous-session native crash dump (set
	-- capture_previous_on_boot = false for the manual flow). ⚠ THE FLAG COMES
	-- FROM THE RESULT: a crash_running that lies makes final() shut down a
	-- reporter that was never created.
	local ok, err = crash.init({
		crash_ingest_url = "http://localhost:8080",
		crash_api_key = "sp_crash_write_placeholder",
		app_id = "app-example",
		crash_source = "game-client",
		-- script_error_capture_enabled = true, -- opt-in Lua error auto-capture
	})
	crash_running = ok and true or false
	if not ok then
		print("shardpilot crash init failed: " .. tostring(err))
	end
end
```

**The one reconcile path.** Every trigger resolves the policy again and then
makes the running lanes match the answer. It closes on its own authority and
opens only on the player's:

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
	elseif not analytics_running then
		if answered then
			if start_analytics(answered.granted, fresh, answered.fresh_answer == true) then
				answered.fresh_answer = nil
			end
		elseif not notice_open then
			notice_open = true
			present_consent_notice(fresh, function(granted)
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

**The lifecycle that drives it:**

<!-- doc-region: lifecycle -->
```lua
function init(self)
	resolve_and_reconcile()

	-- The window listener is installed HERE rather than inside a lane, because
	-- resume must be observed whether or not a lane was ever started: a closed
	-- lane needs nothing, but an open one has to be closeable. NOTE: Defold
	-- keeps a single window listener (window.set_listener replaces any
	-- previously set one), so put these branches inside your game's existing
	-- listener.
	if window and window.set_listener then
		window.set_listener(function(self, event, data)
			-- ... your existing resize/focus/iconify handling ...
			if event == window.WINDOW_EVENT_ICONFIED or event == window.WINDOW_EVENT_FOCUS_LOST then
				-- Snapshot undelivered events to the durable spool: on mobile
				-- an iconified app can be killed without final() ever running.
				if analytics_running then
					shardpilot.persist()
				end
			elseif event == window.WINDOW_EVENT_FOCUS_GAINED then
				-- Resume is a named re-resolution trigger, and the cache must
				-- not answer it: the whole point is that time has passed.
				consent_policy.invalidate()
				resolve_and_reconcile()
			end
		end)
	end
end

function update(self, dt)
	elapsed = elapsed + (dt or 0)

	if pending_notice then
		local deliver = pending_notice
		pending_notice = nil
		deliver()
	end

	-- ⚠ THE PLAN'S OWN DEADLINE, AND THE LANES STOP FIRST. A running lane was
	-- authorised by a plan that has now run out; it does not get to keep
	-- running while the replacement is fetched, or "expired" would mean
	-- nothing until the next unrelated trigger.
	if revalidate_at and elapsed >= revalidate_at then
		revalidate_at = nil
		suspend_analytics("plan_expired")
		suspend_crash("plan_expired")
		consent_policy.invalidate()
		resolve_and_reconcile()
	end

	if analytics_running then
		shardpilot.update(dt) -- drives flush timer + frame sampling
	end
end

function final(self)
	-- The two lanes shut down separately, because they start separately.
	if crash_running then
		local crash_ok, crash_err = crash.shutdown()
		if not crash_ok then
			print("shardpilot crash shutdown not complete: " .. tostring(crash_err))
		end
		crash_running = false
	end
	if analytics_running then
		-- shutdown() starts a final flush. Events it cannot deliver are written
		-- to the durable offline spool and re-sent on the next launch, so
		-- shutdown returns true even when the network is down. An undelivered
		-- consent receipt is handled the same way — durably retained in the
		-- consent outbox, it re-sends next launch — so shutdown returns
		-- false, "consent_pending" only when the receipt could NOT be durably
		-- captured (retry shutdown then); with spool_enabled = false it
		-- returns false, err whenever events remain undelivered.
		local ok, err = shardpilot.shutdown("app_final")
		if not ok then
			print("shardpilot shutdown not complete: " .. tostring(err))
		end
		analytics_running = false
	end
end
```

A decision is **not** consent: it says which regime applies and whether the
optional lane is closed whatever the player answers. `decision.crash_profile`
decides the crash lane **separately** — crash reporting is ON by default, so an
unconditional `crash.init` is how a closed lane gets opened — and
`decision.valid_for_seconds` is how long the verdict is good for; re-resolve by
it, and on resume, and when `consent_text_version` or `presented_language`
changes. A lane the policy later closes is stopped with `shutdown()`, **never**
with `set_consent(false)` or `crash.set_enabled(false)`: those record a
player's decision, and a policy change is not one. See the repository README's
**Consent regime** section and `examples/minimal/main.script`.

The configuration itself:

<!-- doc-region: none -- the configuration table, whose fields are documented under it -->
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
`batch_size = 25` (1–100), `buffer_size = 1000`,
`flush_interval_seconds = 15` (partial batches wait; empty queues send nothing),
full batches publish immediately, `flush()` runs on demand, and retries use their own clock,
`publish_timeout_seconds = 2`, `spool_enabled = true`,
`spool_max_events = 500`, `spool_max_bytes = 262144` (max 393216),
`request_compression_enabled = true`.

**Batch bodies over 1 KiB are compressed**, with `Content-Encoding: deflate`
(RFC 1950 zlib) rather than gzip: the engine's `zlib` module produces that
framing and nothing else, and framing gzip by hand would mean a pure-Lua CRC32
over every batch on the flush path — a frame hitch traded for the bytes this
buys. Three things follow when you integrate:

- **The ingest body cap applies to the UNCOMPRESSED body.** Compression buys
  throughput, not headroom — keep sizing against `batch_size` as before.
- **You do not need to coordinate the rollout.** A deployment that cannot read
  the coding answers `400` with detail code `unsupported_content_encoding`; the
  client stops compressing for the session and re-sends the same batch
  uncompressed on the next tick, so the events land.
- **Engine builds without `zlib` simply do not compress.** The module is
  feature-detected; its absence is an ordinary uncompressed publish, never an
  error.

Set `request_compression_enabled = false` to opt out.

Wire the frame loop and teardown:

<!-- doc-region: none -- the one-line lifecycle reminder; the real lifecycle is the extracted region above -->
```lua
function update(self, dt) shardpilot.update(dt) end  -- drives flush timer + frame sampling
function final(self)      shardpilot.shutdown("app_final") end
```

Identity: a UUIDv7 `anonymous_id` is generated and persisted per app on first
init; `shardpilot.identify(user_id)` upgrades attribution. Identifiers are
capped at 512 bytes — oversized values are **rejected**
(`invalid_user_id` / `invalid_anonymous_id`), never truncated. The optional
`diagnostics` hook is the SDK's push-side observability surface: it receives
issue tables with `scope = "event" | "batch" | "consent" | "spool"`, plus
`"experiments"` once `experiments_enabled` is on — that scope carries the
skipped-exposure and failed-cache-persist conditions, so an integration that
switches exhaustively on the list must include it or discard exactly the
diagnostics that reveal a measurement gap.

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
  `"consent_state_denied_forced_minor"`, `"schema_revision_declaration"`,
  `"experiments_assignment"`. Gate new call shapes on it — including the
  experiment surface, whose config field an older SDK would silently ignore:

<!-- doc-region: none -- the feature-detection API, outside the quick-start flow -->
```lua
if shardpilot.supports("consent_state_denied_forced_minor") then
  shardpilot.set_consent("denied_forced_minor")
else
  shardpilot.set_consent(false)
end

-- Same guard before the experiment surface: an older pinned SDK ignores
-- experiments_enabled silently and has none of these five calls.
if shardpilot.supports("experiments_assignment") then
  shardpilot.fetch_experiment_assignment("menu_layout", function(result) end)
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

<!-- doc-region: none -- the consent API surface, listed call by call -->
```lua
shardpilot.set_consent(true)                    -- prerequisite: nothing flows before this
shardpilot.session_start()                      -- emits app.session_started
shardpilot.screen_view("menu")                  -- emits app.screen_view
shardpilot.track("play_cta_click", { cta_source = "main_menu" })
shardpilot.observe_ping_ms(42)                  -- feeds network_summary
```

- The event-enqueue helpers (`track`, `screen_view`, `session_start`) return
  `ok, err`. `track` failure codes: `consent_unknown`, `consent_denied`,
  `event_name_required`, `identity_required`, `invalid_props`,
  `invalid_context`, `queue_full`, `shutdown`.
- The typed progression verbs *(new in `v0.10.2`)* —
  `sdk.track_level_start(level_id, attempt[,
  props])`, `sdk.track_level_complete(level_id, attempt, duration_ms[, score][,
  props])`, `sdk.track_level_fail(level_id, attempt, duration_ms[, fail_reason][,
  props])` — emit the canonical `level_start` / `level_complete` / `level_fail`
  and validate the schema's bounds before anything is queued. Their own codes,
  on top of `track`'s: `level_id_required`, `invalid_attempt` (an integral
  number in 1..65535 — `2.5` is refused; `2.0` is the integer 2, because Lua
  5.1 has one number type), `invalid_duration` and `invalid_score`
  (integral, 0..4294967295),
  `invalid_fail_reason`, and `source_not_client` — these schemas are
  client-source only. An absent `score` or empty `fail_reason` is omitted from
  the wire even when `props` carries that key.
- The typed ad verb *(new in `v0.10.2`)*
  `sdk.track_ad_impression_revenue(impression_id, network,
  revenue_micros, currency[, revenue_precision, ad_unit, ad_format,
  placement])` emits `ad_impression_revenue`. It takes NO props table — that
  schema forbids undeclared keys — and revenue rides as an integer in
  millionths of a currency unit. Its own codes: `invalid_impression_id`,
  `invalid_network`, `invalid_revenue_micros`, `invalid_currency`, one per
  optional field, and `source_not_client`. Beyond the SDK's own gate the
  ingest applies the workspace's `ad_revenue` consent posture and can
  suppress the event per event inside an ACCEPTED batch with
  `suppressed_ad_revenue_consent`; this SDK cannot see that grant. The observer calls
  (`observe_ping_ms`, `observe_disconnect`) return **nothing** — they feed the
  samplers only while consent is granted and are silent no-ops otherwise; do
  not wrap them in `ok, err` handling.
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

<!-- doc-region: none -- the remote-config API, which the flow only parks a value from -->
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

Targeting attributes are a dark opt-in and — unlike the fetch —
granted-consent-only: `remote_config_attributes_enabled = true` plus
`shardpilot.set_remote_config_attributes({ geo = "US", … })` makes fetches
carry the experiment attribute vocabulary (`geo`, `app_version`,
`device_type`, `install_date`, `user_segment`, `custom_attribute_<name>`;
≤512-byte values, 64-attribute cap, sorted; out-of-vocabulary names dropped,
never sent) as query parameters for server-side delivery rules. Attributes
ride ONLY while consent is granted — unknown or denied consent (forced-minor
included) fetches attribute-less and serves the untargeted defaults. Default
`false`: the fetch URL stays byte-identical to the attribute-less path and
the setter is inert. The flag requires `remote_config_url`
(`remote_config_attributes_requires_remote_config_url` otherwise).

## Crash reporting

Crash reporting is a **separate module with separate init and credentials** —
crashes are never wrapped as analytics events, and analytics consent does not
gate them.

<!-- doc-region: none -- the crash module surface, documented separately from the flow -->
```lua
local crash = require "shardpilot.crash"
crash.init({
  crash_ingest_url = "<YOUR-CRASH-INGEST-BASE-URL>", -- base URL only; route appended by the SDK
  crash_api_key    = "<YOUR-CRASH-WRITE-KEY>",       -- crash:write scope
  app_id           = "<YOUR-APP-ID>",
  app_version      = "1.2.3",
  -- platform = "windows", -- auto-detected in-engine; REQUIRED explicitly
  --                       -- outside Defold, or init fails platform_required
  -- script_error_capture_enabled = true, -- opt-in Lua script-error auto-capture (dark by default)
})
-- crash.init auto-forwards last session's native dump;
-- set capture_previous_on_boot = false to call crash.capture_previous() manually instead.
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
- **Opt-in Lua script-error auto-capture** (`script_error_capture_enabled =
  true`, default **off**): the SDK installs a `sys.set_error_handler` handler
  forwarding each unhandled script error as a fatal `lua_error` report
  (message → reason, traceback → `raw_text`), capped at 10 per session and
  gated on the opt-out. Defold has ONE process-wide handler slot — opting in
  replaces a game-installed handler; keep it off and call `crash.emit_fatal`
  from your own handler if you need both.
- **Engine-module symbol identity**: the `dmengine` module's `debug_id` is
  synthesized as `dmengine-<version_sha1>` from `sys.get_engine_info()`, so
  uploading Defold's published per-release engine symbols under that debug id
  makes engine frames resolve; other modules stay name-keyed (the engine
  exposes no debug ids for them).

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

1. **Policy first**: `consent_policy.prepare(context, cb)` calls back exactly
   once. ⚠ `STRICT_OPT_IN` — which is what the resolver emits today — means
   **ask with the switch off**, not "do not ask": read
   `decision.analytics_choice_default` for the switch's state and
   `decision.explicit_grant_required` for whether a click is what opens the
   lane. Your age step comes first; an unknown or minor band means the
   question is not put and `init` is not reached at all.
2. **Init**: inside that callback, `shardpilot.init(cfg)` returns `true`. A
   `false, err` here is a config mistake; the `err` code names the field.
3. **Consent-first sanity**: before any grant, `shardpilot.track("t")` returns
   `false, "consent_unknown"` — if it returns `true`, you are not on the
   consent-first pipeline you think you are.
4. **Grant**: `shardpilot.set_consent(true)` returns `true`.
5. **Emit a test event**: `shardpilot.track("integration_test", { ok = true })`
   returns `true` (enqueued).
6. **Deliver**: keep calling `shardpilot.update(dt)` from your script's
   `update` (or call `shardpilot.flush()`); HTTP is async, so completion lands
   on a later frame. `flush()` returning `false, "pending"` (batch in flight)
   or `false, "consent_receipt_pending"` (grant receipt awaiting handoff) is
   normal mid-cycle; `true` means the pipeline is drained.
7. **Confirm acceptance** via `local s = shardpilot.snapshot()` (a copy of the
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
8. **Remote config** (if configured): `fetch_remote_config(cb)` calls back
   with `result.ok = true` and your published `values`; a second fetch
   typically serves the ETag-revalidated cache (`from_cache = true`).
9. **Crash plane** (if configured): `crash.emit_fatal({ exception = { type =
   "lua_error", reason = "integration test" }, threads = { { id = "main",
   crashed = true, frames = { { ["function"] = "test.verify" } } } } })`
   returns `true`; then `crash.snapshot()` shows `emitted` ≥ 1 and, after the
   async callback, `accepted` ≥ 1 (`suppressed` counts reports the server
   accepted but did not store; `last_error`/`last_issue` name failures).
   Outside the Defold engine, set `platform` explicitly in `crash.init` first
   — auto-detection fails there and `crash.init` returns
   `platform_required`.
10. **Offline durability**: go offline, `track` a granted event, then make it
   durable **before** killing the app — a kill right after `track` alone
   loses the event, because `track` only queues it in memory. Either call
   `persist()` (or run `shutdown()`), or keep pumping `update` until the
   failed offline publish spools the batch (`snapshot().spooled` ≥ 1). Then
   kill, relaunch, come back online — `snapshot()` shows `spool_resent` ≥ 1
   and the event arrives with its original `event_id`.
11. **Shutdown**: `shardpilot.shutdown("app_final")` returns `true` (or
    retry it while pumping `update`; see the shutdown notes above).

## Known limitations (2026-07-19 audit)

Stated plainly so integrations do not trip on them:

- **No engine-real CI leg**: CI runs the test suite under host Lua
  interpreters (Lua 5.1 and LuaJIT as the gating legs, matching Defold's
  embedded runtime, plus Lua 5.4 host-only). No CI job builds the SDK inside
  the Defold engine/bob toolchain — the in-engine build check is a manual
  release step, so validate your integrated game in the engine yourself.
- **Lua script-error auto-capture is OPT-IN and replaces the handler slot**:
  live Lua errors report only when `script_error_capture_enabled = true`
  (default off), and opting in installs the SDK's `sys.set_error_handler`
  handler into Defold's single process-wide slot — keep the flag off and
  call `crash.emit_fatal` from your own handler if you need both.
- **Pre-launch platform**: no production ingest domain is provisioned; the
  hosted docs site is not live yet. Use local/develop endpoints and the
  in-repo `docs/` as the reference.
