# Minimal Defold Example

The example is [`main.script`](main.script). It is the executable statement of
the integration path, it is loaded and run by the repository's own test suite,
and it is what the README's quick start mirrors — so read it rather than a
copy, because a copy is what goes stale.

It uses placeholder IDs and tokens only.

## What it demonstrates, and why the shape is the shape

**Policy first.** `consent_policy.prepare` is the first integration call.
Requiring the SDK is not the barrier — that only loads code; `shardpilot.init`
is, because it builds the client, which loads the persisted scope record and
mints an anonymous identifier. Nothing is initialised until a decision exists.

**One reconcile path.** A consent regime is not decided once at launch. The
plan expires, the notice text changes, the policy is revoked, the app comes
back after a week — every one of those is the same question, so there is one
`reconcile(fresh)` and every trigger calls it: the answer coming back from the
notice, resume, the plan's own `valid_for_seconds` deadline, and a changed
`consent_text_version` or `presented_language`.

**It closes on the policy's authority and opens on the player's.** A lane the
new decision permits still needs an answer; a resume that could open a lane
would be a grant issued by a focus event.

**Suspension is not a decision.** A lane the policy closes is stopped with
`shutdown()`, never with `set_consent(false)` or `crash.set_enabled(false)` —
those record and persist a player's choice, and nobody chose anything. The
player's standing answer survives a suspension and is discarded only when the
notice text or language changes.

**The lanes are orthogonal.** Analytics being closed does not close the crash
lane, and a permitted crash lane does not open analytics. Crash reporting is ON
by default in this SDK, which is why an unconditional `crash.init` is how a
closed lane gets opened by accident.

## Running it

Drop `main.script` into a Defold collection, point `endpoint`, `ingest_url` and
`remote_config_url` at your own services, and replace
`present_consent_notice` — the placeholder declines immediately, so the example
runs and is closed by default.
