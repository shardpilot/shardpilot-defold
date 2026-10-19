# Contributor instructions

- Keep SDK code compatible with Lua 5.1 and LuaJIT.
- Keep dispatch deadlines effective on asynchronous and synchronous HTTP bridges.
  Check time again after acquiring a token. Retain unsent events and answer each
  bounded flush callback once.
- For delivery changes, run every `test/test_*.lua` suite under Lua 5.1, LuaJIT
  and Lua 5.4, plus the library, version and public-surface checks in `scripts/`.
- Update the README, configuration guide and changelog when delivery behavior changes.
- Client teardown must fence remote-config responses before cache writes or callbacks.
- Reserve app storage ownership before persistence. Release it on completed teardown,
  failed construction and collection; keep external-writer freshness tests effective.
- Preserve host-call order through experiment retries. Key fences must retain
  plane-wide authority; older per-key refusals, closures and age-gated installs
  must preserve synthetic exemptions during pending declarations.
- A later adult declaration fences the experiment's older fetches; its own
  `age_ineligible` answer still withdraws.
- Bounded flushes own exact call-built summary IDs, including terminal refusals.
- Emit withdrawal diagnostics after state changes; host hooks can fetch or close.
- Closing clients keep experiment housekeeping but start no assignment revalidation,
  including mismatch corrections and grammar retries; do not remint while closing.
- Adopt all cap retirements before diagnostics, even when durable history is evicted.
- Apply mismatch correction compares the occurrence's version, variant and assignment key.
- Schedule cap-history pruning for newly adopted keys; retain unchanged live keys.
- System-information probes must request ignore_secure; preserve protected fallbacks.
- Retry spent withdrawal-debt clears after purge; new debt cancels old clear authority.
- Failed deadline-only spool rewrites stay owed at flush, persist and shutdown.
