#!/usr/bin/env bash
# Choose the lane B ratchet's comparison base for one CI event.
#
# Prints ONE OR MORE revisions, one per line, or the word EMPTY. The caller must
# run the comparison against every line and require all of them to hold: a rise
# against any accepted state is a rise.
#
# ⚠ THIS EXISTS BECAUSE THE CHOICE WAS WRONG SIX TIMES. The distinct defects are
# enumerated once, in .github/workflows/ci.yml beside the step that calls this --
# one list, one total, in one place, because three inventories of the same history
# is how they came to disagree.
#
# The workflow performs the fetching this names; this file only decides.
set -euo pipefail

ZERO=0000000000000000000000000000000000000000
event=""; pr_base=""; before=""; sha=""; ref=""; default=""; remote=origin
baseline=scripts/public-surface-lane-b-baseline.txt
lane_b_trunk_rev=""
lane_b_trunk_has=unknown

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
# ⚠ FULLY QUALIFIED, BECAUSE `origin/main` IS A NAME A TAG MAY ALSO HAVE. Git
# resolves an ambiguous short name by checking refs/tags BEFORE refs/remotes, and
# a tag may legitimately be called `origin/main`. On a tag push the checkout then
# holds both, and the shorthand resolves to the TAG -- which is the commit under
# test, so the gate would compare its tree with itself and an upward baseline
# edit would pass. Git says "warning: refname 'origin/main' is ambiguous" on
# stderr, which this discards, and `rev-parse --verify --quiet` succeeds on the
# wrong object without a word. Measured: with both refs present, the shorthand
# named the tag's commit and refs/remotes/origin/main named the trunk's.
git rev-parse --verify --quiet "refs/remotes/$remote/$default^{commit}" >/dev/null 2>&1 \
  && lane_b_trunk_rev="refs/remotes/$remote/$default"

# ⚠ ASKED ONCE, HERE, AND WITH `ls-tree`. Whether the trunk carries the baseline
# decides how a baseline-less revision is read: a fork from before adoption
# (EMPTY) or the adoption itself (pass through, so the gate's own skip applies).
# `cat-file -e` cannot answer it -- it exits nonzero for an absent path and for
# an unreadable one alike -- so a failed lookup used to be recorded as "the trunk
# does not have it", which is the permissive answer. `ls-tree` separates them:
# rc 0 with empty output is looked-and-absent, nonzero is could-not-look, and
# could-not-look stays `unknown`, which licenses nothing.
if [ -n "$lane_b_trunk_rev" ]; then
  if lane_b_trunk_ls="$(git ls-tree --name-only "$lane_b_trunk_rev" -- "$baseline" 2>/dev/null)"; then
    if [ -n "$lane_b_trunk_ls" ]; then
      lane_b_trunk_has=yes
    else
      lane_b_trunk_has=no
    fi
  fi
fi

# ⚠ A REVISION WITHOUT THE BASELINE IS NOT ALWAYS A WEAKER TARGET -- IT DEPENDS
# ON WHY. The gate skips a target that predates the baseline file, which is right
# exactly once: the change that introduces it has a target without it, and that is
# this file's own adoption. It is a hole afterwards: a ref forked from before
# adoption selects such a merge base, the comparison is announced as skipped, and
# the push can add material with a matching baseline -- which later pushes then
# treat as the published number, laundering the increase permanently.
#
# The two are indistinguishable from the target alone, and distinguishable from
# the DEFAULT BRANCH: if the trunk carries the baseline, adoption is done and a
# target without it is a fork from before, so it is emitted as EMPTY -- every
# occurrence new. If the trunk does not carry it either, adoption is in progress
# and the gate's skip is the correct answer, so the revision passes through.
#
# A revision that does not resolve passes through as well. The gate refuses an
# unresolvable comparison target with its own message, and turning "I could not
# look" into EMPTY would replace a refusal with a verdict.
emit() {  # $1 = newline-separated revisions -> deduplicated, EMPTY where blind
  # ⚠ AND THE SAME `ls-tree` DISTINCTION HERE, NOT ONLY ON THE TRUNK. The trunk
  # inspection was fixed to separate looked-and-absent from could-not-look, and
  # this one -- the per-revision check that actually decides EMPTY -- was left on
  # `cat-file -e`, which conflates them. A target whose tree cannot be read
  # therefore became EMPTY: a verdict produced without inspecting anything, and
  # one that passes outright when the current lane is empty. Fourth layer of one
  # mistake, and the first three were each fixed while this one stood.
  #
  # A lookup that fails is a refusal. A revision that does not RESOLVE still
  # passes through, deliberately: the gate refuses an unresolvable comparison
  # target by name, and replacing its refusal with a silent EMPTY would be the
  # same substitution in the other direction.
  lane_b_emit_out=""
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    if [ "$r" = EMPTY ] || [ "$lane_b_trunk_has" = no ] \
       || ! git rev-parse --verify --quiet "$r^{commit}" >/dev/null 2>&1; then
      lane_b_emit_out="$lane_b_emit_out$r
"
      continue
    fi
    if lane_b_r_ls="$(git ls-tree --name-only "$r" -- "$baseline" 2>/dev/null)"; then
      if [ -n "$lane_b_r_ls" ]; then
        lane_b_emit_out="$lane_b_emit_out$r
"
      else
        lane_b_emit_out="${lane_b_emit_out}EMPTY
"
      fi
    else
      echo "REFUSING: could not inspect $r for $baseline." >&2
      echo "  The revision resolves but its tree could not be read, so whether" >&2
      echo "  it carries a baseline is unknown. Calling that EMPTY would be a" >&2
      echo "  verdict reached without looking." >&2
      return 2
    fi
  done <<LANE_B_EMIT_INPUT
$1
LANE_B_EMIT_INPUT
  printf '%s' "$lane_b_emit_out" | awk '!seen[$0]++'
}

# ⚠ THE EVENT DECIDES, NOT THE SHAPE OF THE ARGUMENTS. `--event` was accepted and
# never read: the dispatch keyed off `pr_base` alone, so a PUSH carrying a
# non-empty `--pr-base` would use that arbitrary revision, and a PULL REQUEST
# without one fell through to the push logic and could end up on `before`. The
# workflow populates these consistently today, which is exactly the kind of fact
# a unit must not rely on -- an input the contract names and the code ignores is
# a promise nothing keeps.
case "$event" in
  pull_request)
    if [ -z "$pr_base" ]; then
      echo "REFUSING: --pr-base is required for a pull_request event." >&2
      echo "  Without it there is no base to compare against, and falling" >&2
      echo "  through to the push rules would pick one meant for a different" >&2
      echo "  question." >&2
      exit 2
    fi
    # 1. A pull request carries its own base, which is the tree the change will
    #    land on. Nothing else can be more accurate than that.
    emit "$pr_base" || exit $?
    exit 0
    ;;
  push)
    if [ -n "$pr_base" ]; then
      echo "REFUSING: --pr-base must not be set for a push event." >&2
      echo "  A push has no pull-request base. Accepting one here would let a" >&2
      echo "  caller regression choose an arbitrary revision to compare with." >&2
      exit 2
    fi
    ;;
  "")
    echo "REFUSING: --event is required." >&2
    echo "  The event decides which rules apply; inferring it from which other" >&2
    echo "  arguments happen to be set is how a pull request ended up on the" >&2
    echo "  push rules." >&2
    exit 2
    ;;
  *)
    echo "REFUSING: unsupported event '$event'." >&2
    echo "  Only pull_request and push have rules here. An unrecognised event" >&2
    echo "  is a caller this file has not been taught, not a default." >&2
    exit 2
    ;;
esac

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
# ⚠ AN ABSENT REF IS NOT "SOME OTHER REF". Without this, an empty `--ref` on a
# push to the trunk makes the comparison below false and the run falls through to
# the non-trunk case -- which, after that very push, resolves origin/<default> to
# the commit under test. The gate then compares the tree with itself and an
# upward baseline edit sails through. The fallback was silent because it is the
# LAST case, and a last case answers every question it is reached by.
if [ -z "$ref" ]; then
  echo "REFUSING: --ref is required for a push event." >&2
  echo "  Without it this cannot tell the trunk from any other ref, and the" >&2
  echo "  non-trunk answer would compare the pushed commit with itself." >&2
  exit 2
fi

if [ "$ref" = "refs/heads/$default" ]; then
  if [ -n "$before" ]; then
    emit "$before" || exit $?
  else
    printf 'EMPTY\n'
  fi
  exit 0
fi

# 3. Any other ref -- a branch or a tag. It is compared against the TRUNK AS IT
#    STANDS, and nothing published may carry more than the trunk currently does.
#
#    ⚠ THIS IS THE THIRD MODEL, AND THE FIRST TWO WERE BOTH WRONG. "The previous
#    tip" let a rejected push launder its material through an empty follow-up.
#    "The merge base, and every commit since it" was worse in both directions at
#    once: too strict, because `rev-list` cannot tell a previously PUBLISHED tip
#    from a commit created locally -- a developer who commits 10 -> 5 and then
#    5 -> 7 before pushing once is refused, though 7 is an honest reduction from
#    the published 10; and too weak, because a tag placed on an older commit has
#    that commit as its own merge base, so it was compared with itself and
#    republished debt the trunk had already paid down. It was also unaffordable:
#    one gate run per state, at roughly a minute each in the review container,
#    against a job budget of ten.
#
#    The trunk's current state is one comparison, cannot be gamed by local
#    history, and refuses the tag case outright: 10 occurrences against a trunk
#    that has paid down to 5 is a rise, whoever cut the tag.
#
#    ⚠ WHAT IT DOES NOT ENFORCE, SAID PLAINLY: monotonicity WITHIN a branch. A
#    branch may go 5 -> 7 while the trunk sits at 10 and this will pass. That is
#    deliberate. Not because the branch is unpublished -- this workflow runs on
#    every branch push precisely because a public repository exposes that tree
#    immediately -- but because the ceiling that matters is the trunk's: nothing
#    reachable here may carry more than the trunk currently does. Per-branch
#    monotonicity is a different rule, and it is caught where
#    it matters, at the pull request, whose base is the trunk's own tip and whose
#    comparison is the strict one.
if [ "$lane_b_trunk_rev" != "" ]; then
  emit "$lane_b_trunk_rev" || exit $?
  exit 0
fi

# 4. No trunk to compare against -- an unfetched default branch, or a repository
#    that has none. There is no accepted state to appeal to, so nothing is
#    grandfathered: every occurrence is new.
printf 'EMPTY\n'
