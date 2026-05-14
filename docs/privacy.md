# Privacy And Tokens

ShardPilot Defold SDK v0 keeps tokens and queues in memory only. Client tokens
are memory-only.

- No durable local queue.
- No file writes.
- No browser storage or local storage equivalent.
- No token logging.
- No full event payload logging.
- No anonymous stitching by default.
- No pre-auth publishing by default.
- No provider, model, GitHub, billing, or control-plane write calls.
- No automatic actions.

Do not send raw customer/player payloads, raw provider payloads, tokens,
secrets, diffs, patches, code/file/archive content, prompts, completions, or
unsanitized stack/backtrace payloads.

Use HTTPS for non-local production-like URLs. Public production readiness is not
claimed by this source SDK wave.
