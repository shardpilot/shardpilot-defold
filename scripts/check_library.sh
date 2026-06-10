#!/usr/bin/env bash
set -euo pipefail

required_files=(
  README.md
  LICENSE
  NOTICE
  CHANGELOG.md
  SECURITY.md
  game.project
  shardpilot/sdk.lua
  shardpilot/client.lua
  shardpilot/envelope.lua
  shardpilot/queue.lua
  shardpilot/transport.lua
  shardpilot/clock.lua
  shardpilot/id.lua
  shardpilot/platform.lua
  shardpilot/sampling.lua
  shardpilot/storage.lua
  shardpilot/version.lua
  test/harness.collection
  test/harness.script
  test/test_sdk.lua
  examples/minimal/README.md
  examples/minimal/main.script
  docs/configuration.md
  docs/events.md
  docs/privacy.md
  docs/release.md
  scripts/check_library.sh
  scripts/package_release.sh
  .github/workflows/ci.yml
)

for file in "${required_files[@]}"; do
  test -f "$file" || { echo "missing required file: $file" >&2; exit 1; }
done

grep -q '^\[library\]' game.project || { echo "missing [library] section" >&2; exit 1; }
grep -q '^include_dirs = shardpilot$' game.project || { echo "library include_dirs must be shardpilot only" >&2; exit 1; }

if grep -RInE 'native_extension|extension|\.c$|\.cpp$|\.mm$|\.java$|Extender' shardpilot game.project; then
  echo "native extension or Extender reference is not allowed in v0" >&2
  exit 1
fi

if grep -RInE 'project_id|game_id|event_ts_server|event_seq_session|build_version' shardpilot; then
  echo "legacy public SDK field names must not appear in SDK source" >&2
  exit 1
fi

if grep -RInE 'io\.|os\.execute|localStorage|IndexedDB|sessionStorage' shardpilot; then
  echo "durable local storage or file writes are not allowed in SDK source" >&2
  exit 1
fi

if grep -RInE 'sys\.save|sys\.load|sys\.get_save_file' --exclude=storage.lua shardpilot; then
  echo "sys persistence calls are only allowed in shardpilot/storage.lua" >&2
  exit 1
fi

if grep -RInE 'provider_payload|raw_payload|prompt|completion|access_token|github_token|billing' shardpilot examples; then
  echo "forbidden raw/provider/model/token/billing terms found outside boundary docs" >&2
  exit 1
fi

grep -q 'POST {ingest_url}/v1/events:batch' README.md || { echo "README missing wire contract" >&2; exit 1; }
grep -q 'memory-only' docs/privacy.md || { echo "privacy doc missing memory-only boundary" >&2; exit 1; }
grep -q 'does not publish tags, GitHub Releases' docs/release.md || { echo "release doc must state no release publication" >&2; exit 1; }

echo "shardpilot Defold library static check passed"
