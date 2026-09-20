# Golden bodies — the resolver's actual bytes

These are not hand-written fixtures. They are the **exact JSON the consent
policy handler emits**, recorded by the resolver's own golden test.

| file | what it is |
|---|---|
| `consent-policy-resolved.json` | `200`, a resolved STRICT plan for a valid request |
| `consent-policy-refusal.json` | `400`, a refusal with `reason: "invalid_scope"` |

**Provenance.** Recorded by the resolver service's own test at commit
`5f64aca`, from `internal/httpserver/testdata/consent_policy_resolved_strict.json`
and `consent_policy_refusal_invalid_scope.json`. The resolved body answers the
request `{workspace_id: ws_1, app_id: app_1, environment_id: env_1,
app_version: 1.2.3, store: steam, store_region: null, locale: en-GB,
platform: windows}`; the refusal is the same request with an invalid
`workspace_id`. Clock fixed at `2026-09-20T12:00:00Z` — the only seam, and why
`expires_at` is `12:05:00Z` with `max_age_seconds` `300`. Everything else is
the handler's own output, compared as **bytes** rather than through a struct:
a round trip through the type the handler marshalled from would stay green
through a renamed tag, a re-nesting, or a `null` where an empty array was.

**Why they exist.** This SDK and that resolver were written from the same prose
and never parsed each other's bytes: the module validated a *flat* plan with
upper-case values while the server answers a *nested* one in lower case, so
every real response was refused as unreadable. A schema in two places is a
schema in neither — these bytes are the one place both sides can be wrong
against.

**Four differences worth naming**, because they are what this SDK had wrong:

1. `flags` is **nested**, and its vocabulary is lower case — `off`, `denied`,
   `minimised`.
2. `operation_blocks` lives **inside** `flags`, and is `[]` — never null,
   never absent.
3. `"signature": null` is present on **every** response, refusals included. A
   closed validator must accept the key with a null value rather than treat it
   as absent.
4. A refusal **does** carry `scope`, as three empty strings, so every key is
   present on every response and the required set is total. What tells a
   refusal from a plan is the presence of `reason`.

`test_consent_policy.lua` asserts on these files directly. If the contract
moves, the golden scene is what says so.
