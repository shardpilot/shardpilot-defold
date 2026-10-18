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
  plane-wide authority and synthetic exemptions during pending declarations.
