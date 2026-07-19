#!/usr/bin/env bash
set -euo pipefail

version="${1:-preview}"
name="shardpilot-defold-${version}.zip"
out_dir="dist"

command -v zip >/dev/null 2>&1 || {
  echo "zip is required to create a future release package" >&2
  exit 1
}

mkdir -p "$out_dir"
rm -f "$out_dir/$name"

zip -r "$out_dir/$name" \
  game.project \
  shardpilot \
  README.md \
  LICENSE \
  NOTICE \
  CHANGELOG.md \
  SECURITY.md \
  docs \
  .claude/skills/shardpilot-defold-integration/SKILL.md

echo "$out_dir/$name"
