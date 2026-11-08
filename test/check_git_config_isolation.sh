#!/bin/sh
set -eu

pattern='(GIT_CONFIG(_GLOBAL|_SYSTEM|_VALUE_[0-9]+)?|core[.](hooksPath|attributesFile|excludesFile)|include[.]path|commit[.]template)[^[:alnum:]_./-]{0,12}(/dev/null|os[.]devnull)([^[:alnum:]_./-]|$)'
status=0
git grep -nIiE -e "$pattern" --and --not -e '^[[:space:]]*(#|//|/\*|\*)' -- \
  '*.go' '*.py' '*.sh' '*.js' '*.mjs' '*.cjs' '*.ts' '*.yml' '*.yaml' '*.json' '*.toml' Makefile || status=$?
case "$status" in
  0) echo "Git config paths must use private temporary files." >&2; exit 1 ;;
  1) exit 0 ;;
  *) exit "$status" ;;
esac
