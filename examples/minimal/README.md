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

**No authenticated plan means no plan authority.** This SDK build has no
verifier or trusted signing key. Present-null, missing and non-null signatures
all leave the plan unused. The local fallback has unknown operation restrictions
(`nil`), not a known empty set. The example therefore opens no notice or
processing lane, even for an adult willing to grant consent. Unsigned SOFT
responses and unsigned empty block lists do not change that result.

**One reconcile path.** Launch and resume both call the real resolver and
remain closed while restrictions are unknown. The later notice and lifecycle
flow requires established policy authority; this quick start supplies no
independent authority. An integrating host must establish its own policy and
follow the README's host requirements before initializing processing.

## Running it

Drop `main.script` into a Defold collection, point `endpoint`, `ingest_url` and
`remote_config_url` at your own services, and replace
`present_consent_notice` — the placeholder declines immediately, so the example
runs with every plan-dependent lane closed while it cannot authenticate a plan.
