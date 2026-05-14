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
- The queue is bounded and memory-only; there is no durable local queue in v0.
- The SDK does not write files or use browser/local storage equivalents.
- The SDK must not log tokens or full event payloads.
- The SDK must not make provider, model, GitHub, billing, or control-plane
  write calls.
- Do not send raw provider payloads, raw player/customer payloads, diffs,
  patches, code/file/archive content, prompts, completions, or unsanitized
  stack/backtrace payloads.
