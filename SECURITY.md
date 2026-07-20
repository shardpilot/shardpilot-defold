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
  written only while analytics consent is currently granted, is loaded at
  launch only when a persisted grant is on record, and is purged fail-closed
  in every other state. A grant whose identity-record persistence fails can
  spool within that session, but does not survive to a reload: the next
  launch finds no persisted grant and purges the record.
- Durable storage is limited to seven per-app records written through Defold
  `sys.save`, each bounded as noted: the identity record (anonymous ID +
  consent decision — plus the dedicated `spcid_…` experiment subject id once
  the experiment surface is opted into; host-supplied identifiers are
  clamped to 512 bytes at acceptance, keeping the record far under the
  engine's save-file limits);
  the offline event spool described above (entry- and byte-budgeted); an
  outbox that retains the SDK's own consent decisions until delivered,
  bounded to 32 entries (oldest receipts are evicted first when it
  overflows, so repeated undelivered decisions can displace older ones),
  each receipt carrying identifiers already clamped at acceptance, so
  per-entry size no longer scales with oversized host-supplied
  identifiers; the last-known-good remote-config cache
  (size-capped before it is persisted); the experiment-assignment cache
  (served assignment bodies only, scope-stamped, at most 16 records of at
  most 16 KB each; a scope's record is dropped on the flag-off sentinel);
  the crash opt-out settings record (a
  single boolean); and a per-app, TTL'd crash-retry sidecar with fixed
  entry, per-report, and total byte caps, holding only already-PII-scrubbed
  crash reports (resent then cleared on success). No other file or
  browser/local-storage writes are made.
- The SDK must not log tokens or full event payloads.
- The SDK must not make provider, model, GitHub, billing, or account-management
  write calls.
- Do not send raw provider payloads, raw player/customer payloads, diffs,
  patches, code/file/archive content, prompts, completions, or unsanitized
  stack/backtrace payloads.
