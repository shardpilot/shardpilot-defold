#!/usr/bin/env bash
set -euo pipefail

# Verifies that the in-tree version declarations agree:
#   1. shardpilot/version.lua  — M.VERSION = "X.Y.Z"
#   2. game.project            — version = X.Y.Z
#   3. CHANGELOG.md            — topmost "## vX.Y.Z — ..." heading
#   4. README.md               — the "- **Version `X.Y.Z`.**" Status line
#   5. README.md               — the "the latest tag is `vX.Y.Z`:" mention
#   6. README.md               — the pinned dependency URL (.../archive/refs/tags/vX.Y.Z.zip)
#
# Default mode is a per-commit CI gate and deliberately does NOT look at git
# tags: between releases the tree is legitimately ahead of the latest tag.
#
# Release mode (opt-in, for the release runbook — not CI):
#   ./scripts/check_versions.sh --release
# additionally asserts that tag v<version> exists and points at HEAD.
# Requires tags to be fetched (a plain shallow CI checkout has none).

release_mode=0
if [[ "${1:-}" == "--release" ]]; then
  release_mode=1
elif [[ $# -gt 0 ]]; then
  echo "usage: $0 [--release]" >&2
  exit 2
fi

lua_version="$(sed -nE 's/^M\.VERSION = "([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' shardpilot/version.lua)"
[[ -n "$lua_version" ]] || { echo "could not parse M.VERSION from shardpilot/version.lua" >&2; exit 1; }

project_version="$(sed -nE 's/^version = ([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' game.project)"
[[ -n "$project_version" ]] || { echo "could not parse version from game.project" >&2; exit 1; }

changelog_version="$(grep -m 1 -E '^## ' CHANGELOG.md | sed -nE 's/^## v([0-9]+\.[0-9]+\.[0-9]+)( —.*)?$/\1/p')"
[[ -n "$changelog_version" ]] || { echo "topmost CHANGELOG.md heading is not '## vX.Y.Z — ...'" >&2; exit 1; }

readme_status_version="$(sed -nE 's/^- \*\*Version `([0-9]+\.[0-9]+\.[0-9]+)`\.\*\*.*$/\1/p' README.md)"
[[ -n "$readme_status_version" ]] || { echo "README.md Status line is not '- **Version \`X.Y.Z\`.**'" >&2; exit 1; }

readme_latest_tag_version="$(sed -nE 's/^.*the latest tag is `v([0-9]+\.[0-9]+\.[0-9]+)`:.*$/\1/p' README.md)"
[[ -n "$readme_latest_tag_version" ]] || { echo "README.md latest-tag mention is not '... the latest tag is \`vX.Y.Z\`:'" >&2; exit 1; }

readme_dependency_version="$(sed -nE 's|^dependencies#0 = https://github\.com/shardpilot/shardpilot-defold/archive/refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)\.zip$|\1|p' README.md)"
[[ -n "$readme_dependency_version" ]] || { echo "README.md dependency URL is not 'dependencies#0 = .../archive/refs/tags/vX.Y.Z.zip'" >&2; exit 1; }

if [[ "$lua_version" != "$project_version" || "$lua_version" != "$changelog_version" \
   || "$lua_version" != "$readme_status_version" || "$lua_version" != "$readme_latest_tag_version" \
   || "$lua_version" != "$readme_dependency_version" ]]; then
  {
    echo "version mismatch:"
    echo "  shardpilot/version.lua M.VERSION = $lua_version"
    echo "  game.project version             = $project_version"
    echo "  CHANGELOG.md topmost heading     = v$changelog_version"
    echo "  README.md Status line            = $readme_status_version"
    echo "  README.md latest-tag mention     = v$readme_latest_tag_version"
    echo "  README.md dependency URL tag     = v$readme_dependency_version"
  } >&2
  exit 1
fi

if [[ "$release_mode" == "1" ]]; then
  tag="v$lua_version"
  git rev-parse -q --verify "refs/tags/$tag" >/dev/null || {
    echo "release check: tag $tag does not exist (fetch tags first: git fetch --tags)" >&2
    exit 1
  }
  tag_commit="$(git rev-list -n 1 "$tag")"
  head_commit="$(git rev-parse HEAD)"
  if [[ "$tag_commit" != "$head_commit" ]]; then
    echo "release check: tag $tag points at $tag_commit, not HEAD $head_commit" >&2
    exit 1
  fi
  echo "shardpilot Defold version consistency check passed ($lua_version, tag $tag at HEAD)"
else
  echo "shardpilot Defold version consistency check passed ($lua_version)"
fi
