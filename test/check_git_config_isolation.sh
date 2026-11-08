#!/usr/bin/env bash
# Detect direct literal assignments. Runner filesystem isolation covers computed paths.
set -euo pipefail

# Filter candidate paths with Git, then scan their text across lines.
export LC_ALL=C
config=$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/git-config-guard.XXXXXXXX")
trap 'rm -f -- "$config"' EXIT
export GIT_CONFIG_GLOBAL="$config" GIT_CONFIG_NOSYSTEM=1
{ git grep -ailzE -e '/dev/null|os[.]devnull' -- \
  '*.go' '*.py' '*.sh' '*.js' '*.mjs' '*.cjs' '*.ts' '*.yml' '*.yaml' '*.json' '*.toml' Makefile || [ "$?" -eq 1 ]; } |
  xargs -0 perl -Mwarnings=FATAL,io -0777 -e 'while (<<>>) {
    next if index($_, "\0") >= 0;
    die "Git config paths must use private temporary files ($ARGV).\n"
      if m{(GIT_CONFIG(?:_GLOBAL|_SYSTEM|_VALUE_[0-9]+)?|core[.](?:hooksPath|attributesFile|excludesFile)|include[.]path|commit[.]template)(?:[[:space:]]*[^[:alnum:][:space:]_./-]){0,12}[[:space:]]*(/dev/null|os[.]devnull)([^[:alnum:]_./-]|$)}i;
  }' --
