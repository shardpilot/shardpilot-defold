# Security Policy

The ShardPilot Defold SDK is public-preview source software. Do not use it with
production secrets or production customer/player data until a later release wave
explicitly approves production use.

## Reporting

Report suspected vulnerabilities privately through the repository security
advisory flow when available, or contact the maintainers through a private
project channel.

## Boundaries

- Client tokens are memory-only.
- The in-memory event queue is bounded. A bounded, per-app offline event spool
  additionally persists undeliverable event envelopes across restarts; it is
  written only under a persisted analytics consent grant, is loaded at launch
  only from a persisted grant, and is purged fail-closed in every other state.
- Durable storage is limited to six small, bounded, per-app records written
  through Defold `sys.save`: the identity record (anonymous ID + consent
  decision); the offline event spool described above; a bounded outbox that
  retains the SDK's own consent decisions until delivered; the last-known-good
  remote-config cache; the crash opt-out settings record; and a bounded,
  per-app, TTL'd crash-retry sidecar that holds only already-PII-scrubbed
  crash reports (resent then cleared on success). No other file or
  browser/local-storage writes are made.
- The SDK must not log tokens or full event payloads.
- The SDK must not make provider, model, GitHub, billing, or account-management
  write calls.
- Do not send raw provider payloads, raw player/customer payloads, diffs,
  patches, code/file/archive content, prompts, completions, or unsanitized
  stack/backtrace payloads.
