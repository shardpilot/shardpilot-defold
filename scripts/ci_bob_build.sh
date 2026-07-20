#!/usr/bin/env bash
set -euo pipefail

# Engine-real build gate (CI `bob-build` job): prove that the WORKING TREE
# still packages and builds as a real Defold library dependency — before any
# release tag is cut.
#
#   1. scripts/package_release.sh packages the working tree into the exact
#      ZIP layout a tagged release ships.
#   2. A localhost HTTP server serves that ZIP at the dependency URL that
#      test/bob-harness/game.project declares.
#   3. Defold's command-line builder (bob.jar — pinned and sha256-verified)
#      runs `resolve build` on the harness, so bob fetches the library ZIP
#      like any consumer project would and compiles the shardpilot.* modules
#      that test/bob-harness/main/harness.script requires.
#
# HONESTY: this proves dependency resolution plus build-time compilation
# only. Nothing here starts the engine or checks runtime behavior.
#
# Pins — bump all three together, deliberately (no floating "stable"):
#   DEFOLD_VERSION  human-readable Defold release
#   DEFOLD_SHA1     engine release sha1 (path component of the
#                   d.defold.com archive URL; bob --version reports it)
#   BOB_SHA256      sha256 of bob.jar for that engine sha1
# Defold 1.12.0 and newer require OpenJDK 25 (docs/release.md); ci.yml pins
# Temurin 25 and keys the bob.jar cache on a hash of this script, so a pin
# bump automatically refreshes the cache.
DEFOLD_VERSION="1.13.0"
DEFOLD_SHA1="f735c12192bf95684e6ae1ae27c400b8170fc6d8"
BOB_URL="https://d.defold.com/archive/${DEFOLD_SHA1}/bob/bob.jar"
BOB_SHA256="22e651025834603794ba6873b09924f11412dff66eee0e38aaef8955eb534655"

# Must match dependencies#0 in test/bob-harness/game.project.
HARNESS_PORT=8910
ZIP_NAME="shardpilot-defold-workingtree.zip"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

for tool in java curl python3 zip unzip sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "required tool missing: $tool" >&2
    exit 1
  }
done

# --- bob.jar: cached, always sha256-verified before use --------------------
bob_cache_dir="${BOB_CACHE_DIR:-$repo_root/.ci-cache/bob}"
bob_jar="$bob_cache_dir/bob-${DEFOLD_VERSION}-${DEFOLD_SHA1}.jar"

verify_bob() {
  echo "${BOB_SHA256}  ${bob_jar}" | sha256sum -c - >/dev/null
}

mkdir -p "$bob_cache_dir"
if [[ -f "$bob_jar" ]] && verify_bob; then
  echo "bob.jar ${DEFOLD_VERSION}: cache hit (sha256 verified)"
else
  rm -f "$bob_jar"
  echo "downloading bob.jar ${DEFOLD_VERSION} (${DEFOLD_SHA1})"
  curl -fsSL --retry 3 --retry-delay 5 -o "$bob_jar" "$BOB_URL"
  verify_bob || {
    echo "bob.jar sha256 mismatch — refusing to run an unverified build tool" >&2
    exit 1
  }
  echo "bob.jar ${DEFOLD_VERSION}: downloaded (sha256 verified)"
fi

java -jar "$bob_jar" --version

# --- package the working tree exactly like a release -----------------------
./scripts/package_release.sh workingtree
zip_path="dist/${ZIP_NAME}"
test -f "$zip_path" || {
  echo "package_release.sh did not produce ${zip_path}" >&2
  exit 1
}
# The library contract bob depends on: a game.project with the [library]
# section and the shardpilot modules must be inside the ZIP.
zip_listing="$(unzip -Z1 "$zip_path")"
for entry in game.project shardpilot/sdk.lua shardpilot/crash.lua; do
  grep -qx "$entry" <<<"$zip_listing" || {
    echo "packaged ZIP is missing ${entry}" >&2
    printf '%s\n' "$zip_listing" >&2
    exit 1
  }
done

# --- serve the ZIP where the harness dependency URL expects it -------------
python3 -m http.server "$HARNESS_PORT" --bind 127.0.0.1 --directory dist &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT

dep_url="http://127.0.0.1:${HARNESS_PORT}/${ZIP_NAME}"
curl -fsS --retry 20 --retry-delay 1 --retry-connrefused -o /dev/null "$dep_url" || {
  echo "local dependency server never became ready at ${dep_url}" >&2
  exit 1
}
grep -qx "dependencies#0 = ${dep_url}" test/bob-harness/game.project || {
  echo "test/bob-harness/game.project dependencies#0 does not match ${dep_url}" >&2
  exit 1
}

# --- resolve + build the harness against the working tree ------------------
rm -rf test/bob-harness/.internal test/bob-harness/build
(
  cd test/bob-harness
  java -Xmx2g -jar "$bob_jar" --platform=x86_64-linux --variant=release --archive resolve build
)

# Resolution proof: bob stored the fetched library ZIP under .internal/lib.
resolved_zip="$(find test/bob-harness/.internal/lib -type f -name '*.zip' -print -quit 2>/dev/null || true)"
[[ -n "$resolved_zip" ]] || {
  echo "bob resolve did not fetch the library ZIP into .internal/lib" >&2
  exit 1
}

# Compilation proof: the harness bootstrap chain and the required
# shardpilot.* modules were compiled into the build output.
for built in \
  build/default/main/harness.collectionc \
  build/default/main/harness.scriptc \
  build/default/shardpilot/sdk.luac \
  build/default/shardpilot/crash.luac \
  build/default/shardpilot/remote_config.luac \
  build/default/shardpilot/experiments.luac \
  build/default/game.arcd; do
  test -f "test/bob-harness/${built}" || {
    echo "expected build output missing: test/bob-harness/${built}" >&2
    echo "build tree contents:" >&2
    find test/bob-harness/build -type f >&2 || true
    exit 1
  }
done

echo "bob-build gate passed: working tree resolved and compiled as a Defold library dependency (Defold ${DEFOLD_VERSION}; build-time proof only, no engine runtime)"
