#!/usr/bin/env bash
set -euo pipefail

# Filter candidate paths with Git, then scan their text across lines.
export LC_ALL=C
{ git grep -IilzE -e '/dev/null|os[.]devnull' -- \
  '*.go' '*.py' '*.sh' '*.js' '*.mjs' '*.cjs' '*.ts' '*.yml' '*.yaml' '*.json' '*.toml' Makefile || [ "$?" -eq 1 ]; } |
  xargs -0 perl -Mwarnings=FATAL,io -0777 -e 'while (<<>>) {
    s{^[\t \r\f\x0b]*(?:#|//|/\*|\*)[^\n]*}{X}mg;
    die "Git config paths must use private temporary files ($ARGV).\n"
      if m{(GIT_CONFIG(?:_GLOBAL|_SYSTEM|_VALUE_[0-9]+)?|core[.](?:hooksPath|attributesFile|excludesFile)|include[.]path|commit[.]template)(?:[[:space:]]*[^[:alnum:][:space:]_./-]){0,12}[[:space:]]*(/dev/null|os[.]devnull)([^[:alnum:]_./-]|$)}i;
  }' --
