# Golden bodies — the resolver's actual bytes

These are not hand-written fixtures. They are the **exact JSON the consent
policy handler emits**, produced by running the server's own constructors.

| file | what it is |
|---|---|
| `consent-policy-resolved.json` | `consentpolicy.Resolve(...)` for a valid request |
| `consent-policy-refusal.json` | `consentpolicy.StrictFallback(...)` with `reason = "policy_unavailable"` |

**Provenance.** Produced from the consent-policy resolver's own plan
constructors at commit `38488c48c463c1aaeed9b3c2d4a0125124a990cf`, marshalled
by the same JSON encoder its HTTP handler uses. Clock fixed at
`2026-09-20T12:00:00Z`, which is why `expires_at` is `12:05:00Z` and
`max_age_seconds` is `300`. Regenerating them needs access to that service's
source; the commit identifier is what pins which version these bytes are.

**Why they exist.** This SDK and that resolver were written from the same prose
and never parsed each other's bytes: the module validated a *flat* plan while
the server answers a *nested* one, so every real response was refused as
unreadable. A schema in two places is a schema in neither — these bytes are the
one place both sides can be wrong against.

`test_consent_policy.lua` asserts on them directly. If the contract moves, the
golden scene is what says so.
