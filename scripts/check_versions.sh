#!/usr/bin/env bash
set -euo pipefail

# Verifies that the in-tree version declarations agree:
#   1. shardpilot/version.lua  — M.VERSION = "X.Y.Z"
#   2. game.project            — version = X.Y.Z
#   3. CHANGELOG.md            — topmost "## vX.Y.Z — ..." heading
#   4. README.md               — the "- **Version `X.Y.Z`.**" Status bullet, including its
#                                 "all report `vX.Y.Z`; the `vX.Y.Z` tag" continuation line
#   5. README.md               — the "the latest tag is `vX.Y.Z`:" mention
#   6. README.md               — the pinned dependency URL (.../archive/refs/tags/vX.Y.Z.zip)
#   7. docs/release.md         — the "(currently `vX.Y.Z` for both)" current-release mention
#   8. .claude/skills/shardpilot-defold-integration/SKILL.md
#                              — the "Version pin (CI-checked): ... `vX.Y.Z`." labeled pin line
#   9. .claude/skills/shardpilot-defold-integration/SKILL.md
#                              — the pinned dependency URL (.../archive/refs/tags/vX.Y.Z.zip)
#
# Default mode is a per-commit CI gate for in-tree MUTUAL CONSISTENCY: every
# declaration above must name the same version; git tags are deliberately not
# consulted. Published-artifact claims are held to that same version because
# of this repo's release convention (see docs/release.md): the commit that
# moves M.VERSION is the release commit — every published tag points at the
# very commit that bumped M.VERSION, all in-tree claims move together in that
# commit, and the tag is created from it in the same motion. A flow that
# bumps M.VERSION ahead of tagging does not exist here; introducing one must
# revisit this gate in the same PR.
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

readme_status_report_version="$(sed -nE 's/^.*entry all report `v([0-9]+\.[0-9]+\.[0-9]+)`; the `v[0-9]+\.[0-9]+\.[0-9]+` tag$/\1/p' README.md)"
[[ -n "$readme_status_report_version" ]] || { echo "README.md Status continuation is not '... entry all report \`vX.Y.Z\`; the \`vX.Y.Z\` tag'" >&2; exit 1; }

readme_status_tag_version="$(sed -nE 's/^.*entry all report `v[0-9]+\.[0-9]+\.[0-9]+`; the `v([0-9]+\.[0-9]+\.[0-9]+)` tag$/\1/p' README.md)"
[[ -n "$readme_status_tag_version" ]] || { echo "README.md Status continuation is not '... entry all report \`vX.Y.Z\`; the \`vX.Y.Z\` tag'" >&2; exit 1; }

readme_latest_tag_version="$(sed -nE 's/^.*the latest tag is `v([0-9]+\.[0-9]+\.[0-9]+)`:.*$/\1/p' README.md)"
[[ -n "$readme_latest_tag_version" ]] || { echo "README.md latest-tag mention is not '... the latest tag is \`vX.Y.Z\`:'" >&2; exit 1; }

readme_dependency_version="$(sed -nE 's|^dependencies#0 = https://github\.com/shardpilot/shardpilot-defold/archive/refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)\.zip$|\1|p' README.md)"
[[ -n "$readme_dependency_version" ]] || { echo "README.md dependency URL is not 'dependencies#0 = .../archive/refs/tags/vX.Y.Z.zip'" >&2; exit 1; }

release_doc_version="$(sed -nE 's/^.*\(currently `v([0-9]+\.[0-9]+\.[0-9]+)` for both\).*$/\1/p' docs/release.md)"
[[ -n "$release_doc_version" ]] || { echo "docs/release.md current-release mention is not '... (currently \`vX.Y.Z\` for both)'" >&2; exit 1; }

# The integration skill's version-pin claims. Only the labeled pin line and the
# pinned dependency URL are matched — the skill's surrounding tag-lag prose is
# deliberately NOT part of either pattern.
skill_md=".claude/skills/shardpilot-defold-integration/SKILL.md"

skill_pin_version="$(sed -nE 's/^Version pin \(CI-checked\): this skill matches shardpilot-defold `v([0-9]+\.[0-9]+\.[0-9]+)`\.$/\1/p' "$skill_md")"
[[ -n "$skill_pin_version" ]] || { echo "$skill_md pin line is not 'Version pin (CI-checked): this skill matches shardpilot-defold \`vX.Y.Z\`.'" >&2; exit 1; }

skill_dependency_version="$(sed -nE 's|^dependencies#0 = https://github\.com/shardpilot/shardpilot-defold/archive/refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)\.zip$|\1|p' "$skill_md")"
[[ -n "$skill_dependency_version" ]] || { echo "$skill_md dependency URL is not 'dependencies#0 = .../archive/refs/tags/vX.Y.Z.zip'" >&2; exit 1; }

if [[ "$lua_version" != "$project_version" || "$lua_version" != "$changelog_version" \
   || "$lua_version" != "$readme_status_version" || "$lua_version" != "$readme_status_report_version" \
   || "$lua_version" != "$readme_status_tag_version" || "$lua_version" != "$readme_latest_tag_version" \
   || "$lua_version" != "$readme_dependency_version" || "$lua_version" != "$release_doc_version" \
   || "$lua_version" != "$skill_pin_version" || "$lua_version" != "$skill_dependency_version" ]]; then
  {
    echo "version mismatch:"
    echo "  shardpilot/version.lua M.VERSION = $lua_version"
    echo "  game.project version             = $project_version"
    echo "  CHANGELOG.md topmost heading     = v$changelog_version"
    echo "  README.md Status line            = $readme_status_version"
    echo "  README.md Status 'all report'    = v$readme_status_report_version"
    echo "  README.md Status tag mention     = v$readme_status_tag_version"
    echo "  README.md latest-tag mention     = v$readme_latest_tag_version"
    echo "  README.md dependency URL tag     = v$readme_dependency_version"
    echo "  docs/release.md current release  = v$release_doc_version"
    echo "  SKILL.md version pin             = v$skill_pin_version"
    echo "  SKILL.md dependency URL tag      = v$skill_dependency_version"
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
