#!/usr/bin/env bash
# Choose the lane B ratchet's comparison base for one CI event.
#
# ⚠ THIS EXISTS BECAUSE THE CHOICE WAS WRONG FOUR TIMES IN THREE LINES OF YAML.
# It was never set at all, so the comparison never ran while the gate printed
# "CI sets it"; then a new ref was compared against the DEFAULT BRANCH, which it
# does not descend from; then the fix for that used the MUTABLE `github.ref`, so
# a second push made the base the very commit under test; then a root ref fell
# back to the default branch again, and a previously FAILED tip was trusted as an
# accepted base. Every one of those was found by reading, because nothing
# executed the choice. A decision with inputs and one output can be driven.
#
# The workflow performs the fetching this names; this file only decides.
set -euo pipefail

ZERO=0000000000000000000000000000000000000000
event=""; pr_base=""; before=""; sha=""; ref=""; default=""; remote=origin

while [ $# -gt 0 ]; do
  case "$1" in
    --event)          event="${2-}";   shift 2 ;;
    --pr-base)        pr_base="${2-}"; shift 2 ;;
    --before)         before="${2-}";  shift 2 ;;
    --sha)            sha="${2-}";     shift 2 ;;
    --ref)            ref="${2-}";     shift 2 ;;
    --default-branch) default="${2-}"; shift 2 ;;
    --remote)         remote="${2-}";  shift 2 ;;
    *)
      echo "REFUSING: unknown argument '$1'." >&2
      echo "  This is called from one place, so an unrecognised flag means the" >&2
      echo "  caller and this file disagree about the contract." >&2
      exit 2 ;;
  esac
done

# ⚠ THE ALL-ZERO SHA IS ABSENCE, IN EVERY POSITION IT CAN APPEAR. GitHub spells
# "there was no previous tip" as forty zeroes rather than as an empty string, and
# a rev made of zeroes resolves nowhere -- so treating it as a value produces a
# base ref that cannot be fetched and a refusal blamed on the fetch.
[ "$pr_base" = "$ZERO" ] && pr_base=""
[ "$before"  = "$ZERO" ] && before=""
[ "$sha"     = "$ZERO" ] && sha=""

if [ -z "$default" ]; then
  echo "REFUSING: --default-branch is required." >&2
  exit 2
fi

# 1. A pull request carries its own base, which is the tree the change will land
#    on. Nothing else can be more accurate than that.
if [ -n "$pr_base" ]; then
  printf '%s\n' "$pr_base"
  exit 0
fi

if [ -z "$sha" ]; then
  echo "REFUSING: --sha is required for a push event." >&2
  echo "  Without the event's own commit there is nothing to compare, and" >&2
  echo "  guessing from the ref is what made this choice wrong twice." >&2
  exit 2
fi

# 2. A push to the default branch. Its previous tip is the accepted state, and
#    there is no merge base to appeal to -- the branch IS the trunk.
#
#    ⚠ NAMED LIMIT: this trusts the previous tip. If the default branch is itself
#    red, that trust is misplaced. It is the only base available for the trunk,
#    and the alternative -- "the last commit whose CI passed" -- is not in the
#    event payload.
if [ "$ref" = "refs/heads/$default" ]; then
  if [ -n "$before" ]; then
    printf '%s\n' "$before"
  else
    printf 'EMPTY\n'
  fi
  exit 0
fi

# 3. Any other ref: branch or tag. The base is where it left the default branch,
#    NOT its previous tip.
#
#    ⚠ AND NOT `before`, WHICH CAN BE A TIP THIS GATE ALREADY REJECTED. Push A
#    adds lane B material, raises its baseline and fails; push B is an empty
#    commit whose `before` is A. Comparing B against A sees no increase, so B is
#    green while carrying exactly the material that made A fail. The merge base
#    is immune: it is a commit on the default branch, so the whole branch is
#    measured against a state the project accepted.
if base="$(git merge-base "$sha" "$remote/$default" 2>/dev/null)" && [ -n "$base" ]; then
  printf '%s\n' "$base"
  exit 0
fi

# 4. No merge base at all: an orphan branch, or a tag on a root commit. There is
#    no accepted ancestry, so there is no grandfathered debt either -- the target
#    is an empty baseline rather than some other branch's slack.
printf 'EMPTY\n'
