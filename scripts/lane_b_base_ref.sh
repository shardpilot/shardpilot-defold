#!/usr/bin/env bash
# Choose the lane B ratchet's comparison base for one CI event.
#
# Prints ONE OR MORE revisions, one per line, or the word EMPTY. The caller must
# run the comparison against every line and require all of them to hold: a rise
# against any accepted state is a rise.
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

# 2. A push to the default branch. Its previous tip is the accepted state.
#
#    ⚠ AND THAT IS A PREMISE, NOT A DEDUCTION. Review showed the hole: commit A
#    adds an occurrence and raises its baseline, CI fails, and an otherwise empty
#    commit B is green because its `before` is A and the two baselines agree --
#    A's material laundered onto the trunk. There is no merge base to appeal to
#    and the event payload carries no record of which commit was last ACCEPTED.
#
#    The repository's rule settles it rather than the code: THE TRUNK ADVANCES
#    ONLY THROUGH PULL REQUESTS. Under that rule the previous tip cannot be an
#    unreviewed state -- the only way a commit reaches the trunk is as the head of
#    a pull request whose own comparison was green -- so `before` is an accepted
#    state by construction rather than by luck.
#
#    ⚠ THE PREMISE IS NOT SELF-ENFORCING, AND THIS FILE CANNOT MAKE IT SO. Nothing
#    reachable from a CI event distinguishes a merge landed from a pull request
#    from a direct push. Branch protection on the default branch is what holds it,
#    and that is repository configuration rather than code. If direct pushes are
#    ever permitted, this line silently becomes the hole described above -- so the
#    premise is written here, where the trust is taken, rather than in a commit
#    message nobody reads twice.
if [ "$ref" = "refs/heads/$default" ]; then
  if [ -n "$before" ]; then
    printf '%s\n' "$before"
  else
    printf 'EMPTY\n'
  fi
  exit 0
fi

# 3. Any other ref: branch or tag. TWO bases, and the count may rise against
#    neither.
#
#    ⚠ THE MERGE BASE ALONE TURNS EVERY REDUCTION INTO SLACK. Push A takes a file
#    from the merge base's 10 down to 5 and passes; push B adds five back and
#    raises its baseline to 10, and against the unchanged merge base that is not a
#    rise either. The advertised rule -- the number may fall and may not rise --
#    stops holding across published pushes, and the debt someone paid becomes
#    reusable. The previous tip catches exactly that, because 5 -> 10 rises
#    against it.
#
#    ⚠ AND THE PREVIOUS TIP ALONE IS THE HOLE THE MERGE BASE CLOSES: a tip this
#    gate already rejected is not an accepted state, so an empty follow-up commit
#    would carry the rejected material through. Each base covers the other's gap,
#    so both are emitted and the caller must satisfy both.
#
#    ⚠ AND NOT `before`, WHICH CAN BE A TIP THIS GATE ALREADY REJECTED. Push A
#    adds lane B material, raises its baseline and fails; push B is an empty
#    commit whose `before` is A. Comparing B against A sees no increase, so B is
#    green while carrying exactly the material that made A fail. The merge base
#    is immune: it is a commit on the default branch, so the whole branch is
#    measured against a state the project accepted.
if base="$(git merge-base "$sha" "$remote/$default" 2>/dev/null)" && [ -n "$base" ]; then
  printf '%s\n' "$base"
  # Deduplicated rather than printed twice: on the first push of a branch the two
  # answers coincide, and a caller running the same comparison twice would report
  # the same failure twice and look like two problems.
  if [ -n "$before" ] && [ "$before" != "$base" ]; then
    printf '%s\n' "$before"
  fi
  exit 0
fi

# 4. No merge base at all: an orphan branch, or a tag on a root commit. There is
#    no accepted ancestry, so there is no grandfathered debt either -- the target
#    is an empty baseline rather than some other branch's slack.
printf 'EMPTY\n'
