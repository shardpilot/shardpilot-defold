# Golden bodies — the resolver's actual bytes

These are not hand-written fixtures. They are the **exact JSON the consent
policy handler emits**, recorded by the resolver's own golden test.

| file | what it is |
|---|---|
| `consent-policy-resolved.json` | `200`, a resolved STRICT plan for a valid request — **the wire bytes**, as the handler writes them |
| `consent-policy-refusal.json` | `400`, a refusal with `reason: "invalid_scope"` — the wire bytes |
| `consent-policy-resolved.indented.json` | the same response in the **review form** the resolver's repository stores |
| `consent-policy-refusal.indented.json` | the same, for the refusal |
| `consent-policy-resolved-advisory.json` | `200`, the same resolved STRICT plan with the optional **advisory part** — the wire bytes |
| `consent-policy-resolved-advisory.indented.json` | the same, in the review form |

**Provenance, and it is a scene rather than a sentence.** The three wire `.json`
files are the bytes the handler writes on the wire. The resolver's own golden
test re-indents each raw response and compares *that* with the file it keeps,
applying the indentation to both sides — so **indentation is the only
transformation** between what goes over the wire and what that repository
stores, and the stored form is what a human reads a diff in.

Both forms are vendored here, and
`test_the_review_forms_compact_to_the_wire_bytes` proves the relation instead
of asking you to believe it: removing insignificant whitespace from each
`.indented.json` — **outside strings only, with no round trip through a JSON
library** — must reproduce the corresponding `.json` byte for byte. Decoding
and re-encoding would prove only that the two files *mean* the same thing,
which is the weaker claim and the one that let this SDK and the resolver
disagree for months. A key reordered, a number respelled or an escape
rewritten fails that scene.

Recorded from the resolver service's own test at commit `d26a56f5284bf233cc0f8caf054ed772961438ca`, from
`internal/httpserver/testdata/consent_policy_resolved_strict.json` (blob
`ba2795a09d6a591e2904b4d23f9aa81bef5b8ce3`) and `consent_policy_refusal_invalid_scope.json` (blob
`ec6eb6c293b1d28f1b250c4a23058570755d04a6`); those are the stored review forms, and the `.indented.json` files
here are copies of them. The resolved body answers the
request `{workspace_key: ws_1, app_key: app_1, environment_key: env_1,
app_version: 1.2.3, store: steam, store_region: null, locale: en-GB,
platform: windows}`; the refusal is the same request with an invalid
`workspace_key`. Clock fixed at `2026-09-20T12:00:00Z` — the only seam, and why
`expires_at` is `12:05:00Z` with `max_age_seconds` `300`. Everything else is
the handler's own output, compared as **bytes** rather than through a struct:
a round trip through the type the handler marshalled from would stay green
through a renamed tag, a re-nesting, or a `null` where an empty array was.

The advisory pair was recorded the same way, from
`internal/httpserver/testdata/consent_policy_resolved_strict_with_advisory.json`
(blob `915ea00fc4cb461f0e9b96299a3e6a91c0167c51`), which the `.indented.json` here copies byte for byte. It
answers the same request with `advisory: true` added, for a workspace admitted
to the advisory, from a connection the resolver located in GB. Its plan is the
resolved plan above, unchanged; the advisory sits beside it and does not alter
it.

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

**Whitespace is not a detail here.** This module scans the RAW TEXT — for
duplicate keys, unknown keys, container types and present-and-null members —
before it decodes anything, and JSON permits insignificant whitespace between
every pair of tokens. Until the review forms were vendored, every golden scene
ran on the compact spelling only, so that scanner had never met a newline or
an indent. A proxy that re-serialises, a future encoder, or a server that
starts pretty-printing would all arrive as whitespace, and a closed validator
that has seen one spelling is one layer of exactly the gap these files exist
for. `test_whitespace_does_not_change_the_answer` feeds the module both forms
and compares the decision field by field, and the key-omission scene runs over
both.

`test_consent_policy.lua` asserts on these files directly. If the contract
moves, the golden scene is what says so.

## Consent notice acceptance

`consent-notice-request.json` and `consent-notice-response.json` are byte-for-byte
copies of the consent-notice contract request/response verified at source head
`00b3ab62f95bf61e935905904599b9a89c576a93`. The request carries literal scope
keys and `kind = "anon"`; the receiving handler uses its default kind mode.
The response retains the captured newline. SHA-256:

- request: `87f337aa10ad76ffcc60424e8f3a996b9b5548df57e62a4decbd13a1e886f233`
- response: `8add729673ccd76ee0baee7352dccff01efebc6387439a56c03c523ed34f2e0b`

The scene runs the real setter and serializer with synthetic identifiers and
controlled time/retry-key sources, matches the complete request bytes, and feeds
the accepted response into the actual receipt acknowledgement path. The source
capture used a synthetic service principal; the local fixture runs in process.

## Non-objection contract

`advisory-non-objection.v1.json` is an exact contract bundle with decoded
request/response golden scenes and an asserted validation profile. SHA-256:
`9463140ce26330158cee663fe2a11ffe1b601b88001c3562802af6c29cdaabe6`.
Its `contract_only` status describes a wire contract, not deployed acceptance.
The SDK snapshot covers the closed host attestation and notice/provenance fields.
Locale validation is the structural BCP 47 subset; the server decides registry
membership. The snapshot is separate from consent and supplies no policy authority.

The private recording scenes also exercise the real client, HTTP transport and
`sys` storage adapter. They compare the complete decoded request with the golden,
validate recorded and replayed ACKs, and keep locale refusal terminal. Retries
retain the same payload, timestamp and key; restored records require a fresh
matching host attestation. Identity, notice, scope, denial, deadline and shutdown
scenes fence stale answers. These scenes do not claim event admission.
