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
- The event queue is bounded and memory-only; there is no durable local event
  queue in v0.
- Durable storage is limited to two small records written through Defold
  `sys.save`: the per-app identity record (anonymous ID + consent), and a
  bounded, per-app, TTL'd crash-retry sidecar that holds only an
  already-PII-scrubbed previous-session crash report (resent then cleared on
  success). No other file or browser/local-storage writes are made.
- The SDK must not log tokens or full event payloads.
- The SDK must not make provider, model, GitHub, billing, or account-management
  write calls.
- Do not send raw provider payloads, raw player/customer payloads, diffs,
  patches, code/file/archive content, prompts, completions, or unsanitized
  stack/backtrace payloads.
