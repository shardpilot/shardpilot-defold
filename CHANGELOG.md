# Changelog

## v0.1.0 — 2026-05-23 — Phase 1 alpha

- Provides a pure Lua Defold library source SDK under `shardpilot/`.
- Includes Defold `game.project` library metadata with `shardpilot` as the include directory.
- Supports singleton and instance APIs for identity, sessions, screen views, custom events, updates, flush, and shutdown.
- Sends app-first batched event payloads to `{ingest_url}/v1/events:batch` without legacy public SDK fields.
- Keeps token and queue state in memory only, with Lua tests and static library checks.
- This is a Phase 1 alpha milestone tied to ADR-0176. It is not a GA or 1.0 release.

## Unreleased

- No unreleased changes.
