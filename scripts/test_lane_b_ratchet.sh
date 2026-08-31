#!/usr/bin/env bash
# One control per refusal in the lane B ratchet.
#
# ⚠ WHY THIS EXISTS. Two of the last four findings on the ratchet were checks
# that were CORRECT two rounds earlier and were lost in a restructure: the
# target-format check vanished when the existence probe changed shape, and a
# pipefail fix covered one filter of two. Both survived review of the change
# that broke them, because after changing a mechanism I re-ran the case I had
# just changed rather than the cases the change could break.
#
# check_public_surface.sh has an in-process SELFTEST, but it scans an in-memory
# fixture: it cannot reach refusals that depend on the baseline FILE and on git
# state. So those are exercised here, against the real script in a real
# checkout, one condition at a time.
#
# ⚠ IT RUNS IN A THROWAWAY CLONE OF HEAD, and mutates that. Six review rounds
# produced six cleanup defects here, each introduced by the fix for the previous
# one -- a stranded directory, an inherited `rm -rf`, a cleanup keyed on the step
# reached, a guard broken by trap ORDERING. Three correct rules, all applied, and
# the mechanism kept producing them. What every one of those defects needed was a
# LIVE tree to damage; the clone removes the tree rather than the defects.
#
# The refusal on a dirty tree STAYS, and its reason is now a different one. It
# used to say: a failed restore over uncommitted work is worse than not running.
# That hazard is gone. The one that is not gone was never written down, because
# it came free with the first: THE SUBJECT OF A RUN IS A COMMIT. Clone HEAD while
# the caller has uncommitted edits and the harness reports green about code it
# never loaded -- the emptiest pass there is, arriving precisely when someone is
# editing the gate and wants to see a mutant bite.
set -euo pipefail
cd "$(dirname "$0")/.."

# ⚠ THE RE-ENTRY SENTINEL IS NOT AN INPUT, AND THIS IS THE SECOND TIME THAT
# SENTENCE HAS HAD TO BE WRITTEN HERE. #67 took LANE_B_BASELINE away from the
# gate for exactly this reason; then this harness, in the act of removing a
# degree of freedom, introduced a control variable for its own mechanism -- and
# a nonempty LANE_B_HARNESS_CLONE in the environment skipped the clone, skipped
# both dirty-tree refusals, mutated the caller's live checkout, and printed the
# caller's own string as the commit tested.
#
#   A rebuild that removes a degree of freedom tends to add a sentry, and the
#   sentry is the new degree of freedom.
#
# So it is refused rather than ignored, like the variable in the gate: an
# exported leftover from an older copy of this script must stop the run loudly
# instead of quietly turning the clone off.
if [ -n "${LANE_B_HARNESS_CLONE+set}" ]; then
  echo "REFUSING: LANE_B_HARNESS_CLONE is set, and is not an input." >&2
  echo "  This harness decides whether it is the clone by looking at where it" >&2
  echo "  is, not by being told. A set value here is a leftover from an older" >&2
  echo "  copy of this script, and honouring it would skip the clone, skip the" >&2
  echo "  dirty-tree refusals, and let the closing line name a commit nobody" >&2
  echo "  measured. Unset it and run again." >&2
  exit 2
fi

# ⚠ AND "AM I THE CLONE" IS DERIVED, NOT DECLARED. The parent writes a marker
# BESIDE the clone -- outside its worktree, so no control's `git status` ever
# sees it -- containing the path it created. The child recognises itself when
# that marker names its own toplevel. Nothing inherited, nothing exported.
lane_b_here="$(cd -P "$(git rev-parse --show-toplevel)" && pwd -P)"
lane_b_marker="$(dirname "$lane_b_here")/.lane-b-harness-clone"
lane_b_am_clone=no
if [ -f "$lane_b_marker" ] && [ "$(cat "$lane_b_marker" 2>/dev/null)" = "$lane_b_here" ]; then
  lane_b_am_clone=yes
fi

if [ "$lane_b_am_clone" = no ]; then
  if [ -n "$(git status --porcelain)" ]; then
    echo "REFUSING: working tree is dirty." >&2
    echo "  This harness clones HEAD and runs there, so uncommitted work would" >&2
    echo "  not be the thing under test -- the run would report green about code" >&2
    echo "  it never loaded. Commit or stash first." >&2
    exit 2
  fi
  # ⚠ `git status` DOES NOT SEE EVERYTHING, and the same reason applies. A path
  # marked --assume-unchanged or --skip-worktree is omitted from --porcelain, so
  # the guard above passes while the worktree differs from HEAD -- and those
  # differences are exactly what the clone will not carry. `ls-files -v` reports
  # assume-unchanged by LOWERCASING the status letter; skip-worktree gets its own
  # UPPERCASE `S`, so a lowercase-only test walks past it. Measured earlier:
  # `^[a-z]` matched 0 and `^[a-zS]` matched 1 on a skip-worktree path.
  #
  # ⚠ AND IT IS NOT `| grep -q`. Under pipefail, `grep -q` exits at the FIRST
  # match; if the index listing is larger than the pipe buffer, `git` then dies
  # of SIGPIPE, pipefail makes the whole condition nonzero, and A MATCH READS AS
  # NO MATCH. Not a missed refusal -- an inverted one, arriving only in the big
  # repositories where the flagged path is likeliest. The fix is to consume the
  # whole listing, which also lets git's own status survive to be checked and
  # runs the walk once instead of twice.
  set +e
  lane_b_flagged="$(git ls-files -v 2>/dev/null | grep '^[a-zS]'; exit "${PIPESTATUS[0]}")"
  lane_b_flag_st=$?
  set -e
  if [ "$lane_b_flag_st" -ne 0 ]; then
    echo "REFUSING: could not read the index flags (git ls-files -v exit $lane_b_flag_st)." >&2
    echo "  The dirty-tree guard above cannot be trusted without this, so the" >&2
    echo "  run stops rather than clone something it has not checked." >&2
    exit 2
  fi
  if [ -n "$lane_b_flagged" ]; then
    echo "REFUSING: some tracked paths carry assume-unchanged or skip-worktree." >&2
    echo "  git status cannot see edits to those, so the dirty-tree guard above" >&2
    echo "  is not answering the question it appears to answer, and the clone" >&2
    echo "  would silently test HEAD instead of what you are holding." >&2
    # ⚠ AND NOT `| head -5`, WHICH IS THE SHAPE THIS BLOCK EXISTS TO REMOVE.
    # I fixed the `grep -q` above, swept the class, found a second instance in
    # judge() -- and wrote a third one here, in the fix, on the line below the
    # comment describing it. `head` exits after five lines, the builtin printf
    # takes SIGPIPE, pipefail makes the harness die 141 before the `exit 2` that
    # carries the refusal. No pipe: the shell reads its own string.
    lane_b_shown=0
    while IFS= read -r lane_b_line; do
      [ "$lane_b_shown" -ge 5 ] && break
      printf '  %s\n' "$lane_b_line" >&2
      lane_b_shown=$((lane_b_shown + 1))
    done <<< "$lane_b_flagged"
    exit 2
  fi
  # ⚠ ARMED BEFORE THE ALLOCATION, AND THIS ONE MY OWN SWEEP FOUND AND MY
  # TRIAGE DISMISSED. The class list caught it -- "allocation one line above its
  # trap" -- and I wrote it off as a negligible window next to the three real
  # instances. It is not negligible: what leaks here is the entire clone root,
  # the largest object this harness creates, and "one line" is not a measure of
  # probability, only of how much code I have to read to see it.
  #
  #   The grep was right and the judgement was wrong. A triage that discards
  #   an instance of a class needs the same evidence as a fix.
  #
  # `${var:+"$var"}` expands to nothing while the variable is empty, and `rm -rf`
  # with no operand exits 0 -- measured, rather than assumed.
  lane_b_tmp_root=""
  trap 'rm -rf ${lane_b_tmp_root:+"$lane_b_tmp_root"}' EXIT
  lane_b_tmp_root="$(mktemp -d)"
  # --no-hardlinks is load-bearing: an ordinary local clone hard-links the object
  # store, and a write into .git/objects would reach through to the real
  # repository -- the same second-name-for-one-inode hazard this gate refuses on
  # its baseline, arriving through git's own optimisation.
  if ! git clone -q --no-hardlinks "$PWD" "$lane_b_tmp_root/repo" 2>/dev/null; then
    echo "REFUSING: could not clone this repository to run against." >&2
    exit 2
  fi
  # ⚠ THE MARKER IS WRITTEN IN THE SPELLING THE CHILD WILL COMPUTE, AND THEN
  # READ BACK. `mktemp` hands out whatever TMPDIR is spelled as; the child
  # resolves its own root with `cd -P`, so a symlinked ancestor made the two
  # differ -- and a child that does not recognise itself CLONES AGAIN, at every
  # level, until the machine runs out. Not hypothetical: /tmp is a symlink to
  # /private/tmp on macOS, which is where the lanes run. It is NOT a symlink on
  # this Linux container, which is exactly why I could not have met it here.
  #
  #   the cure for a degree of freedom introduced a comparison,
  #   and a comparison has a canonical form.
  #
  # The variable this replaced needed no canonicalisation, because it carried no
  # path. So the fix is checked the only way that survives a later edit: compute
  # the child's own answer the way the child computes it, write THAT, then read
  # it back and refuse if they disagree. A mismatch becomes a refusal at the
  # point of disagreement instead of a run that looks hung.
  lane_b_child_here="$(cd -P "$lane_b_tmp_root/repo" && cd -P "$(git rev-parse --show-toplevel)" && pwd -P)"
  lane_b_child_marker="$(dirname "$lane_b_child_here")/.lane-b-harness-clone"
  printf '%s\n' "$lane_b_child_here" > "$lane_b_child_marker"
  # ⚠ AND THE SKIP MARKER IS PROPAGATED, DERIVED RATHER THAN PASSED. The
  # recursion control below invokes this harness; my defence was that a nested
  # run needs about five minutes to reach that line and the bound is thirty
  # seconds. That defence rests on the SUBJECT STAYING SLOW -- a regression that
  # made every gate invocation return at once would carry the nested run all the
  # way to the terminal control, which would then launch another, and the count
  # of clone roots would report the control's own recursion rather than the
  # mutation under test. A control must not be able to fail for its own reason.
  #
  # Not an environment variable: that is the input this branch spent two rounds
  # removing. A file beside the clone, propagated the same way the clone marker
  # is, and invisible to any caller who has not put one beside their own
  # checkout.
  if [ -e "$(dirname "$lane_b_here")/.lane-b-skip-recursion-control" ]; then
    : > "$(dirname "$lane_b_child_here")/.lane-b-skip-recursion-control"
  fi
  if [ "$(cat "$lane_b_child_marker" 2>/dev/null)" != "$lane_b_child_here" ]; then
    echo "REFUSING: the clone marker does not name the clone as the child will" >&2
    echo "  resolve it, so the child would not recognise itself and would clone" >&2
    echo "  again, and again. Refusing here rather than recursing." >&2
    exit 2
  fi
  # ⚠ THE CHILD IS WAITED ON, NOT JUST RUN, SO AN INTERRUPT CAN BE HANDLED.
  # Measured, because the obvious version leaks: with the child in the
  # foreground, a TERM to this process removes the clone root while the child is
  # still alive in it -- the child keeps writing, the tree comes back half
  # populated, and an interrupted run leaves a clone root behind. Backgrounding
  # it and waiting means the signal handler can end the child FIRST and then
  # remove the root once nothing is writing to it.
  #
  # ⚠ AND THE HANDLERS ARE ARMED BEFORE THE CHILD IS RUNNABLE, not after. They
  # were installed on the two lines following the launch, which leaves a window
  # where a signal finds only the EXIT cleanup armed: the parent then removes the
  # clone root without killing or waiting for a child that is already running in
  # it. That is the same half-populated root the backgrounding was added to
  # prevent -- third instance this round of "install it before you need it", and
  # the third one inside my own fix for the previous one. An empty PID is the
  # initialised state, and the handler tolerates it.
  lane_b_child=""
  lane_b_end_child='if [ -n "$lane_b_child" ]; then kill "$lane_b_child" 2>/dev/null || true; wait "$lane_b_child" 2>/dev/null || true; fi; rm -rf "$lane_b_tmp_root";'
  trap "$lane_b_end_child exit 130" INT
  trap "$lane_b_end_child exit 143" TERM
  "$lane_b_tmp_root/repo/scripts/test_lane_b_ratchet.sh" &
  lane_b_child=$!
  lane_b_child_rc=0
  wait "$lane_b_child" || lane_b_child_rc=$?
  exit "$lane_b_child_rc"
fi

# ⚠ THE WITNESS IS MEASURED HERE, IN THE TREE UNDER TEST. It used to be the
# string the parent passed in, which made the closing line a repeater rather
# than an instrument: whoever set the variable chose what the run claimed to
# have tested. This reads the commit out of the checkout the controls are about
# to run against.
lane_b_tested="$(git rev-parse HEAD)"

# ⚠ A REGISTRY AND A TRAP BEFORE THE FIRST ALLOCATION, because sweeping for
# "where else does an allocation stand above its trap" found two temp FILES that
# a search for `mktemp -d` could never have shown: the synthetic index inside
# synth_target, called at line 210, and the one for the missing-blob target --
# both removed on the normal path only, both leaked by any errexit exit in
# between. synth_target runs long before the main EXIT trap exists, so the fix
# is a registry that the trap drains, which is the shape the gate already uses
# for GATE_TMPFILES. The `${a[@]+"${a[@]}"}` spelling is the gate's too: on bash
# 3.2 an EMPTY array is itself an unbound variable under `set -u`.
LANE_B_TMPFILES=()
trap 'rm -f ${LANE_B_TMPFILES[@]+"${LANE_B_TMPFILES[@]}"}' EXIT


GATE=scripts/check_public_surface.sh
# ⚠ ABSOLUTE, because the selector controls run it from other directories.
SELECTOR="$PWD/scripts/lane_b_base_ref.sh"
BASELINE=scripts/public-surface-lane-b-baseline.txt
# ⚠ THE PIN IS GONE WITH THE OVERRIDE. This used to unset and re-export
# LANE_B_BASELINE so nothing could redirect the gate's writer at an arbitrary
# path. The gate no longer reads that variable at all, so there is nothing to
# pin and nothing to leak -- the hazard is removed rather than defended.

# ⚠ AND THE PIN IS NOT ENOUGH ON ITS OWN. The gate is a bash script, and a
# non-interactive bash sources $BASH_ENV at startup -- AFTER this export -- so a
# startup file assigning LANE_B_BASELINE replaces the pinned path inside the
# child. Reproduced: with BASH_ENV set to a file naming /tmp, the writer
# overwrote that file and the trap could not restore it. ENV is the same hazard
# for a POSIX sh child.
unset BASH_ENV ENV

# ⚠ AND THE COMPARISON REF IS AMBIENT TOO. The gate reads
# PUBLIC_SURFACE_BASE_REF with a default, so an exported value reaches every
# plain `expect` below -- which are the controls meant to exercise the
# CURRENT-TREE behaviour and nothing else. An unresolvable inherited ref turns
# the clean control into an exit 2; a resolvable one with a smaller baseline
# turns it into the anti-cheat refusal. Either way the harness fails for a
# reason that has nothing to do with the control under test. expect_ref supplies
# it explicitly, per call, and is the only thing that may.
unset PUBLIC_SURFACE_BASE_REF
# ⚠ EVERY TARGET IS SYNTHESIZED FROM HEAD, and none is fetched. CI clones at
# depth 1, so `origin/main~1` does not exist there and a harness leaning on it
# would silently skip its own controls on the one machine that matters. Building
# them with plumbing needs no network, no history and no branch: the commits are
# unreachable the moment this run ends.
#
# All of it runs against a TEMPORARY INDEX, so the real one is never touched --
# which is what lets the dirty-tree guard above stay strict.
synth_target() {  # $1 = sed program applied to the baseline, or "" to delete it
  local idx blob tree
  idx="$(mktemp)"
  LANE_B_TMPFILES+=("$idx")
  GIT_INDEX_FILE="$idx" git read-tree HEAD
  if [ -z "$1" ]; then
    GIT_INDEX_FILE="$idx" git update-index --force-remove "$BASELINE"
  else
    blob="$(git show "HEAD:$BASELINE" | sed "$1" | git hash-object -w --stdin)"
    GIT_INDEX_FILE="$idx" git update-index --cacheinfo "100644,$blob,$BASELINE"
  fi
  tree="$(GIT_INDEX_FILE="$idx" git write-tree)"
  rm -f "$idx"
  # ⚠ IDENTITY PASSED INLINE. commit-tree needs a committer, and a fresh CI
  # checkout has none configured -- this exits 128 with "Author identity
  # unknown" there while passing on any developer machine, which is the third
  # shape of "works where it is written, not where it runs" this ratchet has
  # produced. `-c` scopes it to the invocation; nothing in the repository's
  # config is touched, and these commits are unreachable anyway.
  git -c user.name="lane-b-ratchet-test" -c user.email="lane-b-ratchet-test@invalid" \
    commit-tree "$tree" -p HEAD -m "synthetic lane B target"
}

WITH_BASE="$(git rev-parse HEAD)"
WITHOUT_BASE="$(synth_target "")"

checks=0; failures=0

# ⚠ FROM HEAD, NOT FROM THE INDEX. `git checkout -- <path>` restores from the
# INDEX, and the cheat control below stages its own mutation, so an index-based
# restore is a no-op that leaves the tree modified -- and the next run then
# starts from a polluted state and every control fails at once. Observed while
# writing this. `reset --hard` is safe here only because the dirty-tree guard
# above refuses to start over uncommitted work.
# ⚠ ONLY THE PATHS THIS SCRIPT TOUCHES. A repository-wide `reset --hard` has a
# blast radius far larger than the mutations above, and it only looked safe
# because the guard was assumed to see all uncommitted work. Restoring by path
# keeps the damage bounded to what was deliberately broken, whatever the guard
# missed. NEW_FILE is removed rather than restored: HEAD does not have it.
RESTORE_PATHS=("$BASELINE" shardpilot/client.lua)
NEW_FILE=zz_lane_b_probe.lua

# ⚠ A HARD LINK IS A SECOND NAME FOR ONE INODE, AND GIT KNOWS ONLY THE FIRST.
# Linking shardpilot/client.lua or the baseline to a path outside this worktree leaves
# `git status --porcelain` clean, so the dirty-tree guard passes. The appends
# below then write THROUGH the inode and change every name for it, while the
# restore replaces only the worktree entry -- with a NEW inode, since
# `git checkout` writes a fresh file. So the outside name keeps the harness's
# edit permanently, and nothing in this script can reach it to undo that.
#
# `ls -ld` field 2 is the link count on GNU and BSD alike; `stat` spells it
# differently on each, and this gate documents bash 3.2 systems as supported.
for linked in "${RESTORE_PATHS[@]}"; do
  links="$(ls -ld "$linked" 2>/dev/null | awk '{print $2}')"
  case "$links" in
    ''|*[!0-9]*)
      echo "REFUSING: could not read the hard-link count of $linked." >&2
      exit 2
      ;;
  esac
  if [ "$links" -gt 1 ]; then
    echo "REFUSING: $linked has $links hard links." >&2
    echo "  This test writes through the inode, so it would modify every other" >&2
    echo "  name for it, and the restore can only put back this one." >&2
    exit 2
  fi
done

# ⚠ SCRATCH NAMES ARE NOT AUTOMATICALLY FREE. An IGNORED file at one of these
# paths -- via .git/info/exclude or a global ignore -- is invisible to
# `git status --porcelain`, so the dirty-tree guard passes, the redirection
# below truncates it, and the trap then deletes it. The guard cannot see it, so
# the existence check has to be a plain filesystem test.
for scratch in "$NEW_FILE" "$BASELINE.bak" "$BASELINE.real" "$BASELINE.link" "$BASELINE.tmp" "$BASELINE.hard" shardpilot/client.lua.tmp; do
  if [ -e "$scratch" ] || [ -L "$scratch" ]; then
    echo "REFUSING: $scratch already exists; this test would overwrite and then delete it." >&2
    echo "  git status may not show it (an ignored path is invisible there), so" >&2
    echo "  its absence is checked directly rather than inferred." >&2
    exit 2
  fi
done
restore() {
  # $BASELINE.tmp is listed here as well as in the index cleanup below: the
  # rewrites above redirect into it and then `mv`, so an interruption between
  # the two leaves it UNTRACKED in the worktree, where `git rm --cached` cannot
  # reach it. Removing the record without removing the file is the same half-
  # restore as removing the file without the record.
  rm -f "$NEW_FILE" "$BASELINE.bak" "$BASELINE.real" "$BASELINE.link" "$BASELINE.tmp" "$BASELINE.hard" shardpilot/client.lua.tmp
  # A DIRECTORY, so `rm -f` cannot reach it: the private write directory is
  # left behind by a killed writer, and a control plants one on purpose.
  rm -rf "$BASELINE.write.d"
  git checkout -q HEAD -- "${RESTORE_PATHS[@]}" 2>/dev/null || true
  # ⚠ EVERY SCRATCH PATH, NOT JUST THE PROBE. Controls stage before running, so
  # an interruption after the missing- or symlink-baseline setup leaves .bak,
  # .real or .link in the INDEX; deleting the files then leaves staged entries
  # that a later commit would carry. A restore that removes the evidence but not
  # the record is not a restore.
  git rm -q --cached --ignore-unmatch \
    "$NEW_FILE" "$BASELINE.bak" "$BASELINE.real" "$BASELINE.link" "$BASELINE.tmp" \
    "$BASELINE.hard" shardpilot/client.lua.tmp \
    >/dev/null 2>&1 || true
}
# ⚠ TRAP-ONLY, AND SEPARATE FROM restore(). The scratch DIRECTORIES were removed
# on the normal path only, so an interruption left `escape/` in the checkout --
# which the scratch-name guard then refuses on the NEXT run, turning one
# interrupted run into a harness that will not start -- and leaked the temporary
# directories outside it. A cleanup that only runs when nothing went wrong is not
# cleanup.
#
# It is NOT folded into restore(): controls call restore() mid-run to undo their
# own mutation, and folding directory removal in there deletes fixtures the
# later controls still need. Measured, because I did exactly that first: eleven
# controls failed at once.
cleanup_dirs() {
  chmod 755 scripts 2>/dev/null || true
  chattr -i scripts 2>/dev/null || true
  [ -n "${STUB:-}" ] && rm -rf "$STUB"
  [ -n "${STUBDIR:-}" ] && rm -rf "$STUBDIR"
  # ⚠ AND THE PER-CONTROL SCRATCH, WHICH LIVES OUTSIDE THE CLONE. Six controls
  # build stub PATH directories and "precious" copies outside the worktree, so
  # deleting the clone does not reach them: on any exit before their inline
  # `rm -rf`, they leak. That is the same class as the gate's own untrapped
  # mktemp sites (go#71) -- and this instance is mine, in this round's code.
  # One root, removed from the trap, so a new scratch site cannot forget.
  [ -n "${lane_b_scratch:-}" ] && rm -rf "$lane_b_scratch"
  # ⚠ EVERY INTERMEDIATE STATE, NOT THE TIDY ONE. The swap control does
  # `mv scripts scripts.real` then `ln -s`, and undoes it with `rm -f` then `mv`.
  # Interrupted between either pair, `scripts` is ABSENT rather than a symlink --
  # and a condition that only recognises the symlink leaves the repository's
  # entire scripts/ directory stranded as scripts.real. Keyed on what must be
  # restored (scripts.real exists) rather than on how far the swap got.
  if [ -e scripts.real ] || [ -L scripts.real ]; then
    [ -L scripts ] && rm -f scripts
    [ -e scripts ] || mv scripts.real scripts
  fi
  return 0
}
# ⚠ EMPTIED BEFORE THE TRAP CAN READ THEM. cleanup_dirs does `rm -rf` on these,
# and they are assigned hundreds of lines below -- so an exit between here and
# there ran the removal against whatever the CALLER had exported under those
# names. An inherited value is not ours to delete, and this is the third ambient
# input this harness has had to stop trusting, after LANE_B_BASELINE and
# BASH_ENV. I introduced it while fixing a cleanup that only ran when nothing
# went wrong.
# ⚠ THE TRAP IS INSTALLED FIRST, AND THE COMMENT ABOVE ALREADY SAID SO. The
# names were emptied before the trap could read them -- and then both scratch
# roots were ALLOCATED above the trap line, so an INT/TERM between the two
# `mktemp -d` calls, or a failure of the second under `set -e`, leaked the first
# outside the throwaway clone where the parent's cleanup cannot reach it. The
# lesson was written directly above the line that broke it; installing the trap
# before any allocation is the version that does not depend on remembering it.
STUB=""
STUBDIR=""
lane_b_scratch=""
SAVED=""
trap 'restore; cleanup_dirs; rm -f "$SAVED" ${LANE_B_TMPFILES[@]+"${LANE_B_TMPFILES[@]}"}' EXIT
# ⚠ AND SAVED MOVED DOWN HERE FOR THE SAME REASON, FOUND BY THE SAME QUESTION.
# It was allocated ninety-four lines above the trap that removes it -- the exact
# shape of the finding about the scratch roots, in a temp FILE rather than a
# temp directory, which is why looking for "where else is mktemp -d" would not
# have found it. Looking for "where else does an allocation stand above its
# trap" does. Nothing between the old site and here touches the baseline, so the
# pristine copy is still pristine.
SAVED="$(mktemp)"; cp "$BASELINE" "$SAVED"
STUBDIR="$(mktemp -d)"
lane_b_scratch="$(mktemp -d)"

# judge <label> <rc> <want> <needle> <output> -- ONE judgement, every caller.
# The two halves are reported separately and the exit is checked first, because
# "exit 1 for the wrong reason" and "the right reason at the wrong exit" are
# different defects and a message that merges them names the wrong one. An
# earlier copy of this in expect_ref did exactly that: it printed "reason not
# found" whenever the EXIT disagreed, including when the reason was present.
# must_write_baseline <label> -- a SETUP write, and its status is checked.
# `--write-baseline || true` in a fixture is the quietest way to build a control
# that cannot fail: if the write does not happen, the old baseline stays, the
# gate still disagrees with the tree, and the control observes exactly the exit
# and message it wanted -- from a state it never established. Review found this
# in two of the controls added for this very kind of defect.
must_write_baseline() {
  local label="$1"
  if ! "$GATE" --write-baseline >/dev/null 2>&1; then
    echo "FAIL [$label]: setup --write-baseline failed, so this control would" >&2
    echo "  have judged a state it never reached." >&2
    failures=$((failures + 1))
  fi
}

judge() {
  local label="$1" rc="$2" want="$3" needle="$4" out="$5"
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL [$label]: exit $rc, expected $want" >&2
    failures=$((failures + 1))
    return
  fi
  # ⚠ NO PIPE HERE, AND THE REASON CAME FROM THE INDEX-FLAG FINDING. That one
  # was `git ls-files -v | grep -q` inverting under pipefail on SIGPIPE; this
  # was the same shape, in the instrument that decides every pass and fail.
  # `printf` is a builtin, so its EPIPE is the shell's: grep -q exits at the
  # first match, printf dies writing the rest, pipefail makes the pipeline
  # nonzero, and `!` turns FOUND into "the reason was not '$needle'" -- a
  # control failing precisely because it succeeded, on outputs longer than a
  # pipe buffer. A shell pattern match asks the question with no pipe at all.
  local found=no
  case "$out" in *"$needle"*) found=yes ;; esac
  if [ -n "$needle" ] && [ "$found" = no ]; then
    echo "FAIL [$label]: exit $want as expected, but the reason was not '$needle'" >&2
    echo "  -- an exit code alone does not say WHICH refusal fired, and two" >&2
    echo "     conditions sharing a code is how a check goes missing unnoticed." >&2
    failures=$((failures + 1))
  fi
}

# expect <label> <wanted-exit> <substring> -- runs the gate and judges both.
expect() {
  local label="$1" want="$2" needle="$3" rc=0 out
  checks=$((checks + 1))
  git add -A >/dev/null 2>&1 || true
  out="$("$GATE" 2>&1)" || rc=$?
  judge "$label" "$rc" "$want" "$needle" "$out"
}

# ⚠ THE NEEDLE IS THE PREFIX, NOT THE CLAIM. This runs with no comparison
# target, and the summary now says which of two things the run established;
# asserting the strong wording here would demand a sentence this run has not
# earned -- which is what review round 7 found the gate printing.
expect "clean tree holds"            0 "LANE B RATCHET —"
mv "$BASELINE" "$BASELINE.bak"
expect "a missing baseline refuses"  2 "is missing"
mv "$BASELINE.bak" "$BASELINE"
ln -sf /dev/null "$BASELINE.link"; mv "$BASELINE" "$BASELINE.real"; ln -sf "$(basename "$BASELINE.real")" "$BASELINE"
# ⚠ THIS SCENE IS A SYMLINK IN BOTH PLACES, so the WORKING-TREE refusal is the
# one it reaches: the index probe now runs after canonicalisation, which runs
# after the filesystem checks. It used to assert the index message and stopped
# being able to reach it the moment the probe moved -- caught by this control
# failing rather than by my noticing. The index refusal has its own scene below,
# where the index and the working tree DISAGREE, which is the only state that
# isolates it.
# ⚠ THE NEEDLE MOVED TWICE IN TWO ROUNDS, WHICH IS THE POINT OF ASSERTING
# REASONS. This scene has always been "the baseline is a symlink"; the refusal
# that catches it was the working-tree guard, then the index guard, and now the
# format check -- because `git cat-file` on a mode-120000 entry returns the link
# target as text, which carries no format marker. Two guards were removed under
# it and the scene is still refused, one check later and for a true reason.
expect "a symlinked baseline refuses" 2 "is format 1"
rm -f "$BASELINE" "$BASELINE.link"; mv "$BASELINE.real" "$BASELINE"
# `sed -i` with no argument is GNU-only too -- BSD sed reads the next word as
# the backup suffix. Write to a temporary file and move it, everywhere.
sed 's/^# format-version: .*/# format-version: 1/' "$BASELINE" > "$BASELINE.tmp"
mv "$BASELINE.tmp" "$BASELINE"
expect "a format skew refuses"       2 "this script reads"
cp "$SAVED" "$BASELINE"
# awk, not `sed '0,/re/'`: that address is a GNU extension and BSD sed rejects
# it, which would abort the harness before the later controls on exactly the
# macOS systems this gate's bash 3.2 compatibility exists for.
awk 'BEGIN{done=0} /^[0-9]/ && !done {sub(/^/, "9"); done=1} {print}' "$BASELINE" > "$BASELINE.tmp"
mv "$BASELINE.tmp" "$BASELINE"
expect "a disagreeing count fails"   1 "moved and the baseline did not agree"
cp "$SAVED" "$BASELINE"

# expect_env <label> <VAR=value> <wanted-exit> <substring> -- one ambient value,
# supplied per call, the way expect_ref supplies the comparison ref. The harness
# drops these variables globally on purpose, so a control that needs one has to
# hand it over deliberately rather than inherit it.
expect_env() {
  local label="$1" assign="$2" want="$3" needle="$4" rc=0 out
  checks=$((checks + 1))
  git add -A >/dev/null 2>&1 || true
  shift 4
  out="$(env "$assign" "$GATE" "$@" 2>&1)" || rc=$?
  judge "$label" "$rc" "$want" "$needle" "$out"
}

# expect_nostage <label> <wanted-exit> <substring> -- runs WITHOUT `git add -A`.
# Every other control stages first, which is right for them: the gate reads the
# index. But a refusal about the WORKING TREE cannot be driven that way -- stage
# a symlink and the index carries mode 120000, so the index check fires first
# and the working-tree check is never reached. The two refusals exist precisely
# because those are different states.
expect_nostage() {
  local label="$1" want="$2" needle="$3" rc=0 out
  checks=$((checks + 1))
  out="$("$GATE" 2>&1)" || rc=$?
  judge "$label" "$rc" "$want" "$needle" "$out"
}

expect_ref() {
  local label="$1" ref="$2" want="$3" needle="$4" rc=0 out
  checks=$((checks + 1))
  git add -A >/dev/null 2>&1 || true
  out="$(PUBLIC_SURFACE_BASE_REF="$ref" "$GATE" 2>&1)" || rc=$?
  judge "$label" "$rc" "$want" "$needle" "$out"
}

expect_ref "an unresolvable base refuses" "no/such/ref"   2 "does not resolve"
expect_ref "a target with no baseline skips" "$WITHOUT_BASE" 0 "carries no"
expect_ref "a target with one compares"     "$WITH_BASE"     0 "LANE B RATCHET — held at"

# ⚠ THE CHEAT, and the reason the target comparison exists at all: add a match
# AND rewrite the baseline to fit it, so the current tree and its own baseline
# agree perfectly. Every local check passes. Only the target catches it.
# ⚠ THE MARKER IS ASSEMBLED, NOT WRITTEN. This file is not *.lua, so it is LANE A
# -- gated at zero -- and a literal reference here would make the harness itself
# the finding. The gate refused exactly that while this was being written. Same
# trick the gate uses on its own fixture data.
# ⚠ THE PAID STATE, which no other control reaches. Every one of them leaves at
# least one numeric row, so the comments-only baseline -- the shape this lane
# exists to arrive at -- is never parsed. Either status-1 allowance in the gate's
# two-filter read could be deleted with every other control green, and a real
# zero-debt baseline would then abort under pipefail. That allowance was one of
# the two silently-lost checks this harness was built for, so leaving it
# uncovered would be the fourth time it missed its own motive.
#
# The tree still carries 33 occurrences, so the correct outcome here is the
# ordinary count disagreement -- NOT an abort, and not a refusal.
grep '^#' "$SAVED" > "$BASELINE"
expect "a comments-only baseline is parsed, not fatal" 1 "moved and the baseline did not agree"
cp "$SAVED" "$BASELINE"

marker="ADR-"'0331'
printf -- '\n-- See %s for the freeze this follows.\n' "$marker" >> shardpilot/client.lua
git add -A >/dev/null 2>&1 || true
must_write_baseline "a raised baseline is caught by the target"
expect_ref "a raised baseline is caught by the target" "$WITH_BASE" 1 "the baseline was raised"
restore

# ⚠ A TARGET IN AN OLDER FORMAT, SYNTHESIZED -- because history has none. The
# format marker arrived with the file, so no real commit carries a format-1
# baseline, and without one the target-version check can be deleted and every
# control still passes. It was verified to survive exactly that mutation, which
# is why this exists: the check whose silent loss motivated this harness was the
# one the harness did not cover.
#
# ⚠ A FILE THE TARGET HAS NO ENTRY FOR. The cheat control above adds its match
# to shardpilot/client.lua, which both baselines already list, so it exercises only the
# "count rose" branch. The separate refusal for a path ABSENT from the target --
# the first occurrence in a previously clean file -- could be deleted with all
# ten other controls still passing. That is the same gap the format-1 target had:
# a harness tested as working rather than as covering its own motive.
printf -- '-- See %s for the freeze this follows.\nreturn {}\n' "$marker" > "$NEW_FILE"
git add -A >/dev/null 2>&1 || true
must_write_baseline "a file absent from the target is caught"
expect_ref "a file absent from the target is caught" "$WITH_BASE" 1 "is absent from"
restore

# ⚠ REMOVED, NOT RENUMBERED. A real format-1 baseline predates the marker, so it
# has NO `# format-version:` line at all -- and a synthetic target that merely
# changes the value keeps the grep succeeding, leaving the status-1 allowance in
# the target-version read uncovered. That is the fourth time this harness has
# covered the branch it meant to and missed the one next to it.
old_commit="$(synth_target '/^# format-version:/d')"
expect_ref "an older-format target is skipped, not misparsed" "$old_commit" 0 "target baseline is format 1"

# ⚠ AND THE SKIP ABOVE IS THE ANTI-CHEAT'S OFF SWITCH. The control above asserts
# that a skew SKIPS; it says nothing about what may ride along with the skew.
# Review round 3: bump the format and raise lane B counts in one change, and the
# comparison is discarded, leaving only the raised baseline checked against the
# raised tree. Green, with the ratchet switched off by the change it was meant
# to measure. Asserting the skip and asserting the bypass are two questions, and
# the first control answering the first is why the second went unnoticed.
printf -- '\n-- See %s for the freeze this follows.\n' "$marker" >> shardpilot/client.lua
# ⚠ STAGED BEFORE THE WRITE, because the writer reads the INDEX. Without this the
# baseline is regenerated from the unstaged tree, the count does not move, and the
# control fails at the ordinary ratchet with exit 1 -- proving nothing about skew.
git add -A >/dev/null 2>&1 || true
"$GATE" --write-baseline >/dev/null 2>&1 || true
git add -A >/dev/null 2>&1 || true
skew_commit="$(synth_target '/^# format-version:/d')"
expect_ref "a format skew may not carry a lane B source change" "$skew_commit" 2 \
  "may not carry lane B source changes"
restore

# ⚠ A COUNT THAT MUST BE REACHED, same rule the gate applies to itself: a run
# that asserts nothing prints the same closing line as a run that asserts
# everything. Raise this when you add a control; it refuses when one goes.
# ⚠ THE TWO REFUSALS I CLAIMED WERE UNREACHABLE. I wrote into the gate that
# these need a corrupt object store and so could not be driven. That was wrong,
# and it was wrong in the worst way: recorded as a permanent limit, in code.
# Both can be built from valid plumbing that damages nothing.
#
#   ls-tree fails when a SUBtree is missing -- `mktree --missing` accepts an
#   entry pointing at a tree that does not exist, and commit-tree accepts the
#   result (it validates the ROOT tree, which is why a missing root does not
#   work and a missing subtree does).
#
#   git show fails when the blob is missing while the tree still lists the path
#   -- `write-tree --missing-ok` is documented to allow exactly that.
#
# Neither writes a broken object anywhere reachable, and both are unreferenced
# after this run.
missing_sub="$(printf '040000 tree %s\tscripts\n' 0000000000000000000000000000000000000002 | git mktree --missing)"
no_tree_commit="$(git -c user.name="lane-b-ratchet-test" -c user.email="lane-b-ratchet-test@invalid" \
  commit-tree "$missing_sub" -m "synthetic unreadable tree")"
expect_ref "an unreadable tree on the target refuses" "$no_tree_commit" 2 "could not list"

idx_missing="$(mktemp)"
LANE_B_TMPFILES+=("$idx_missing")
GIT_INDEX_FILE="$idx_missing" git read-tree HEAD
GIT_INDEX_FILE="$idx_missing" git update-index --add \
  --cacheinfo "100644,0000000000000000000000000000000000000001,$BASELINE"
missing_blob_tree="$(GIT_INDEX_FILE="$idx_missing" git write-tree --missing-ok)"
rm -f "$idx_missing"
no_blob_commit="$(git -c user.name="lane-b-ratchet-test" -c user.email="lane-b-ratchet-test@invalid" \
  commit-tree "$missing_blob_tree" -p HEAD -m "synthetic unreadable blob")"
expect_ref "an unreadable baseline blob on the target refuses" "$no_blob_commit" 2 "could not be read"

# ⚠ THE PARENT SWAPPED BEFORE `cd`, AND IT NEEDS NO RACE. The anchor and the
# containment check are one property in two halves -- the cwd defends against a
# swap AFTER `cd`, this defends against one before it. I restored the first and
# deleted the second, and each looked whole alone, which is how a paired guard
# escapes an audit that enumerates guards one at a time.
#
# Constructible as a static state rather than a race: replace `scripts` with a
# symlink to a copy outside the worktree. `cd -P` then lands there permanently
# and every later check asks about the wrong directory.
cp -a scripts "$STUBDIR/fake"
mv scripts scripts.real && ln -s "$STUBDIR/fake" scripts
lane_b_swap_out="$(./scripts/check_public_surface.sh --write-baseline 2>&1)" || lane_b_swap_rc=$?
rm -f scripts && mv scripts.real scripts
rm -rf "$STUBDIR/fake"
checks=$((checks + 1))
judge "a parent swapped before the anchor refuses" "${lane_b_swap_rc:-0}" 2 "is not where it should be" "$lane_b_swap_out"

# ⚠ THE SERIALISATION CHECK, DRIVEN -- and the route is VERIFIED before it is
# trusted. The audit claimed this refusal kept a control; it did not. Nothing
# here made the redirect fail: must_write_baseline only exercises successful
# writes, and the grep stub dies during scanning, long before the writer.
#
# `chmod` is not a route: this harness can run as root, where permissions are
# advisory -- measured, uid 0 writes into a 555 directory without complaint, so
# a chmod-based control would be green because of the environment rather than
# the subject. The immutable attribute stops root too, and that is the route.
#
# ⚠ AND THE ROUTE IS PROBED. An attribute the filesystem silently ignores would
# make this control pass vacuously, which is the exact failure it exists to
# catch one level down. So the control writes a probe first: if the probe
# SUCCEEDS, the route is not in force and this reports that rather than a pass.
# ⚠ WHAT EVERY STUB IN THIS FILE IS ALLOWED TO KEY ON, AND WHY THE ANSWER IS
# NOT "SOMETHING SEMANTIC". A control keyed on the SPELLING of a call stops
# testing the moment the call is reworded -- the occurrence-pass control keyed
# on the flag cluster `-aonE`, the counting passes were rewritten to take the
# pattern flag separately, and the stub silently stopped matching. It failed
# loudly, and that is the whole point of what follows.
#
# The stubs here key on paths and flag fragments, and mostly cannot do better:
# a stub that fires for every `-o` grep breaks the audit passes first and the
# control then fails for the wrong reason. Narrowness is not the defect. SILENCE
# is. So the rule is about what a control ASSERTS, not about what its stub
# matches:
#
#   a control that asserts a REFUSAL cannot go quiet. An inert stub produces
#   no refusal, the exit is 0 where 2 was wanted, and the control fails.
#
#   a control that asserts SUCCESS can. The gate exits 0 either way, the
#   "precious" copy outside is untouched either way, and a stub that never
#   fired reads exactly like a guard that worked.
#
# Counted at the time of writing: 26 stub-backed controls assert a refusal and
# are immune by construction; exactly TWO assert success -- the two below -- and
# both write a marker when the hook fires and check it FIRST, before any other
# assertion. That is not decoration. The symlinked-TMPDIR control was caught by
# its own version of this branch within the hour of it being added.
#
# So: a new control that asserts success and installs a stub must carry a fired
# marker. This is a written rule and not a gate -- nothing here enforces it, and
# saying otherwise would be the kind of claim this file exists to distrust.

# ⚠ THE PARENT SWAPPED *AFTER* THE ANCHOR, and this needs a hook rather than a
# race. The other swap scene replaces scripts/ before the gate starts, so it
# exits at containment and never proves what the held cwd is for. This one lets
# the gate anchor, then swaps the parent from inside the run -- a stub `mv`,
# which the gate invokes only after `cd -P` and after the temporary is written.
#
# If the rename used the PATH (`$LANE_B_BASELINE`) it would re-resolve scripts/
# and land outside. Using the bare leaf, the kernel resolves against the held
# working directory -- a descriptor, which the swap cannot reach. The assertion
# is the external file, not the exit code: the gate should SUCCEED here, and the
# outside copy should be untouched.
lane_b_outside="$(mktemp -d "$lane_b_scratch/XXXXXX")"
mkdir -p "$lane_b_outside/scripts"
printf 'PRECIOUS OUTSIDE\n' > "$lane_b_outside/scripts/public-surface-lane-b-baseline.txt"
lane_b_swapstub="$(mktemp -d "$lane_b_scratch/XXXXXX")"
{
  echo '#!/bin/sh'
  printf 'REAL_MV=%q\n' "$(command -v mv)"
  echo 'case " $* " in'
  echo '  *../public-surface-lane-b-baseline.txt*)'
  printf '    "$REAL_MV" %q %q 2>/dev/null &&\n' "$PWD/scripts" "$PWD/scripts.real"
  printf '      ln -s %q %q 2>/dev/null &&\n' "$lane_b_outside/scripts" "$PWD/scripts"
  printf '      : > %q\n' "$lane_b_outside/.hook-fired"
  echo '    ;;'
  echo 'esac'
  echo 'exec "$REAL_MV" "$@"'
} > "$lane_b_swapstub/mv"
chmod +x "$lane_b_swapstub/mv"
checks=$((checks + 1))
lane_b_anchor_out="$(env "PATH=$lane_b_swapstub:$PATH" "$GATE" --write-baseline 2>&1)" || lane_b_anchor_rc=$?
rm -f scripts 2>/dev/null || true
[ -d scripts.real ] && mv scripts.real scripts
# ⚠ AND THE SCENE ASSERTS THAT IT HAPPENED. Every mutation in that hook is
# `2>/dev/null` with its status discarded, so a hook that silently did nothing --
# a path with a space splitting the arguments, which is exactly how this was
# found -- left the gate running normally, the outside copy untouched, and this
# control reporting a pass for a swap that never occurred. The paths are quoted
# with %q now, and the hook records that it fired; a scene that did not happen
# fails rather than passes, the same rule as must_write_baseline.
if [ ! -e "$lane_b_outside/.hook-fired" ]; then
  echo "FAIL [the held cwd survives a parent swapped after anchoring]: the hook" >&2
  echo "  never fired, so this control would have passed without swapping" >&2
  echo "  anything. The scene was not established." >&2
  failures=$((failures + 1))
elif [ "$(head -1 "$lane_b_outside/scripts/public-surface-lane-b-baseline.txt")" != "PRECIOUS OUTSIDE" ]; then
  echo "FAIL [the held cwd survives a parent swapped after anchoring]: the write" >&2
  echo "  followed the replacement instead of the held directory." >&2
  failures=$((failures + 1))
elif [ "${lane_b_anchor_rc:-0}" -ne 0 ]; then
  echo "FAIL [the held cwd survives a parent swapped after anchoring]: exit ${lane_b_anchor_rc}, expected 0" >&2
  failures=$((failures + 1))
fi
rm -rf "$lane_b_swapstub" "$lane_b_outside"
restore

# ⚠ A SYMLINK SWAPPED IN AT THE LEAF, after the checks and before the write.
# The working-tree symlink refusal runs during the scan; between it and the
# put-in-place there is a window, and the PR body used to carry this as a named
# limit -- "no deterministic control, removed by construction".
#
# ⚠ AND THE FIRST HOOK I REACHED FOR WAS THE SUBJECT ITSELF. A stub `mv` swaps
# the leaf and defers, which looks like the parent-swap control one scene up.
# It is not: the mutation this control exists to catch is "write THROUGH the
# leaf instead of renaming over it", and that mutation removes the `mv` call --
# so the hook never fires, the swap never happens, and the control passes.
# Measured, not reasoned: against `cat "$tmp" > "$leaf"` the mv-hooked version
# reported a pass and a DIFFERENT control caught the mutant.
#
#   A hook inside the step under test cannot survive that step being replaced.
#
# So the hook is `ls`, which the gate runs for the hard-link count -- after both
# symlink refusals, before the writer, and untouched by how the write is done.
# The stub swaps the leaf for a link outside the worktree, then defers to the
# real `ls`, which reports link count 1 on the link and lets the gate proceed.
#
# ⚠ AND THE HOOK FIRES EXACTLY ONCE, measured rather than assumed: a logging
# stub counted every `ls` in a full --write-baseline run, and there is one, this
# probe. That is what makes it a single deterministic instant instead of an
# unknown number of them -- a stub that fired again after the write would put
# the link back and fail this control for a reason that is not its subject. The
# match is the exact argument list for the same reason.
#
# ⚠ AND THE PROPERTY IS NOT THE ONE I FIRST WROTE DOWN. I claimed `mv` is safe
# only on the rename(2) path and follows the link when it falls back to copying
# across filesystems. Measured, both ways -- and it is false: GNU `mv` unlinks
# the destination NAME first on the copy fallback too, so the outside file
# survives a cross-device move as well.
#
#   mv  (same device)   -> link replaced, outside intact
#   mv  (/dev/shm -> /) -> link replaced, outside intact
#   cp                  -> link FOLLOWED, outside clobbered, link still standing
#   cat >               -> link FOLLOWED, outside clobbered
#
# So what this control holds is narrower and more useful than a fact about
# filesystems: the put-in-place must stay a RENAME. Turn it into a copy or a
# redirect -- the ordinary shape of a later tidy-up -- and the write goes
# through the link. That is the mutant this control is driven against.
#
# ⚠ AND THE MEASUREMENT ABOVE WAS UNDER-SAMPLED ON AN AXIS THE TABLE DID NOT
# NAME. Two filesystems, and exactly ONE shape of target: a symlink to a regular
# file. Varying the shape is the whole finding:
#
#   leaf -> regular file   mv     link replaced        outside intact
#   leaf -> DIRECTORY      mv     link still standing  temp moved INSIDE it,
#                                 and the gate printed WROTE and exited 0
#   leaf -> dangling       mv     link replaced        outside intact
#   all three              mv -T  link replaced        outside intact
#
# A table of results reads as the full list of axes varied. Mine listed
# filesystems, so the shape of the target looked settled when it had never been
# moved. The control now walks both shapes under one label, because a second
# control with its own name would hide that this one was half an axis.
for lane_b_shape in file dir; do
  lane_b_leafout="$(mktemp -d "$lane_b_scratch/XXXXXX")"
  printf 'PRECIOUS LEAF\n' > "$lane_b_leafout/target.txt"
  mkdir -p "$lane_b_leafout/target.d"
  if [ "$lane_b_shape" = file ]; then
    lane_b_leaftgt="$lane_b_leafout/target.txt"
  else
    lane_b_leaftgt="$lane_b_leafout/target.d"
  fi
  lane_b_leafstub="$(mktemp -d "$lane_b_scratch/XXXXXX")"
  {
    echo '#!/bin/sh'
    printf 'REAL_LS=%q\n' "$(command -v basename)"
    echo 'case "$*" in'
    # ⚠ HOOKED ON `basename`, WHICH RUNS AFTER THE GATE ENTERS scripts/ -- so the
    # plant is a bare leaf name, not a path. Three hooks in this file have now
    # died with the step they lived inside; dirname and basename are the two
    # moments these scenes need and are not checks that can be deleted.
    echo '  "scripts/public-surface-lane-b-baseline.txt")'
    echo '    rm -f public-surface-lane-b-baseline.txt 2>/dev/null'
    printf '    ln -s %q public-surface-lane-b-baseline.txt 2>/dev/null &&\n' "$lane_b_leaftgt"
    printf '      : > %q\n' "$lane_b_leafout/.hook-fired"
    echo '    ;;'
    echo 'esac'
    echo 'exec "$REAL_LS" "$@"'
  } > "$lane_b_leafstub/basename"
  chmod +x "$lane_b_leafstub/basename"
  checks=$((checks + 1))
  lane_b_leaf_label="a leaf swapped in before the write is replaced, not followed (target: $lane_b_shape)"
  lane_b_leaf_rc=0
  lane_b_leaf_out="$(env "PATH=$lane_b_leafstub:$PATH" "$GATE" --write-baseline 2>&1)" || lane_b_leaf_rc=$?
  lane_b_intruded="$(find "$lane_b_leafout/target.d" -mindepth 1 | wc -l)"
  if [ ! -e "$lane_b_leafout/.hook-fired" ]; then
    echo "FAIL [$lane_b_leaf_label]: the hook never fired, so this control would" >&2
    echo "  have passed without planting a link. The scene was not established." >&2
    failures=$((failures + 1))
  elif [ "$(head -1 "$lane_b_leafout/target.txt")" != "PRECIOUS LEAF" ]; then
    echo "FAIL [$lane_b_leaf_label]: the baseline was written THROUGH the link," >&2
    echo "  into the outside file." >&2
    failures=$((failures + 1))
  elif [ "$lane_b_intruded" -ne 0 ]; then
    echo "FAIL [$lane_b_leaf_label]: the rename treated the link as a DIRECTORY" >&2
    echo "  and put the new baseline inside it, outside the worktree." >&2
    failures=$((failures + 1))
  elif [ "$lane_b_leaf_rc" -ne 0 ]; then
    echo "FAIL [$lane_b_leaf_label]: exit $lane_b_leaf_rc, expected 0" >&2
    printf '%s\n' "$lane_b_leaf_out" | sed 's/^/    /' >&2
    failures=$((failures + 1))
  elif [ -L scripts/public-surface-lane-b-baseline.txt ]; then
    echo "FAIL [$lane_b_leaf_label]: the link is still standing at the baseline" >&2
    echo "  path after the write." >&2
    failures=$((failures + 1))
  fi
  rm -rf "$lane_b_leafstub" "$lane_b_leafout"
  restore
done

# ⚠ THE RENAME FAILURE, BOUGHT BACK. The audit claimed the writer's guards were
# covered; they were not. The serialisation control makes the REDIRECT fail and
# asserts the earlier branch, so deleting the rename handler left every control
# green. Two adjacent handlers, one exercised -- the same "fixed the half I was
# looking at" this file keeps producing.
#
# A selective stub: `mv` fails only for the baseline's temporary, and defers to
# the real one otherwise, so the refusal that fires is this one and not some
# earlier mover's.
lane_b_mvstub="$(mktemp -d "$lane_b_scratch/XXXXXX")"
{
  echo '#!/bin/sh'
  echo 'case " $* " in *../public-surface-lane-b-baseline.txt*) exit 1 ;; esac'
  printf 'exec %q "$@"\n' "$(command -v mv)"
} > "$lane_b_mvstub/mv"
chmod +x "$lane_b_mvstub/mv"
expect_env "a failed rename refuses" \
  "PATH=$lane_b_mvstub:$PATH" 2 "could not put the new baseline in place" --write-baseline
rm -rf "$lane_b_mvstub"

# ⚠ AND AN mv WITHOUT -T REFUSES RATHER THAN FALLING BACK. Found by the sweep,
# not by review: mapping every lane B refusal to the control needles that assert
# it left this one with nothing pointing at it. It is a refusal I added in this
# same round, which is the audit line without a control that this file exists to
# stop. Deterministic, no lever: a stub `mv` that fails when it is handed -T, as
# a pre-GNU mv would, and defers otherwise -- so the gate's behavioural probe
# concludes the option is missing and refuses instead of using semantics it has
# measured to be unsafe.
# ⚠ THE WINDOW BETWEEN `mkdir` AND `cd`, WHICH THE HELD DIRECTORY DOES NOT COVER.
# Holding the directory makes every later bare name safe, but the run still has to
# NAME it once, to enter it. Between the create and the entry a process that can
# rename in scripts/ can move the new directory aside and leave a symlink at the
# name, and the gate would then enter, serialise into, and install from a
# directory it did not make.
#
# That window cannot be closed in shell -- there is no open-and-enter primitive
# here -- so it is caught rather than prevented: after entering, `..` must still
# be the directory the run anchored, checked by inode immediately before the
# install. This control is what makes that a check rather than a claim. A stub
# `mkdir` creates the directory for real, then performs exactly the swap
# described, so the gate enters a planted directory whose parent is elsewhere.
lane_b_stolen="$(mktemp -d "$lane_b_scratch/XXXXXX")"
lane_b_mkstub="$(mktemp -d "$lane_b_scratch/XXXXXX")"
{
  echo '#!/bin/sh'
  printf 'REAL_MKDIR=%q\n' "$(command -v mkdir)"
  echo 'case " $* " in'
  echo '  *public-surface-lane-b-baseline.txt.write.d*)'
  echo '    "$REAL_MKDIR" "$@" || exit $?'
  printf '    mv public-surface-lane-b-baseline.txt.write.d %q/taken 2>/dev/null &&\n' "$lane_b_stolen"
  printf '      ln -s %q/taken public-surface-lane-b-baseline.txt.write.d 2>/dev/null\n' "$lane_b_stolen"
  echo '    exit 0'
  echo '    ;;'
  echo 'esac'
  echo 'exec "$REAL_MKDIR" "$@"'
} > "$lane_b_mkstub/mkdir"
chmod +x "$lane_b_mkstub/mkdir"
expect_env "a private directory moved out of its parent refuses" \
  "PATH=$lane_b_mkstub:$PATH" 2 "no longer where it was made" --write-baseline
rm -f scripts/public-surface-lane-b-baseline.txt.write.d
rm -rf "$lane_b_mkstub" "$lane_b_stolen"
restore

lane_b_notstub="$(mktemp -d "$lane_b_scratch/XXXXXX")"
{
  echo '#!/bin/sh'
  echo 'for a in "$@"; do case "$a" in -*T*) exit 1 ;; esac; done'
  printf 'exec %q "$@"\n' "$(command -v mv)"
} > "$lane_b_notstub/mv"
chmod +x "$lane_b_notstub/mv"
expect_env "an mv without --no-target-directory refuses" \
  "PATH=$lane_b_notstub:$PATH" 2 "has no --no-target-directory" --write-baseline
rm -rf "$lane_b_notstub"

# ⚠ AND THE PATHS THAT ANSWER THAT QUESTION ARE NOW INSIDE A PRIVATE DIRECTORY.
# Three review rounds walked this one down. Round 2: the probe was built with an
# ordinary redirect at a predictable name, so a planted symlink was followed.
# Round 3: the exclusive create that replaced it does not refuse a FIFO -- bash's
# noclobber is specified for REGULAR files, so `set -C; : > fifo` opens the entry
# and waits for a reader, and the job hangs to its CI timeout instead of
# refusing; and `mv -fT` still replaces a destination planted between the check
# and the move. Both were races against paths anyone could reach.
#
# `mkdir` has no carve-out: atomic, never follows the final component, EEXIST
# against every shape. So the write-aside and both probe paths moved inside one
# directory created at mode 700, and the races stopped existing rather than
# being narrowed. The controls below plant at the DIRECTORY's path, which is the
# only reachable path left.
lane_b_probe_path="$BASELINE.write.d"
lane_b_probe_outside="$lane_b_scratch/probe-outside.txt"
printf 'PRECIOUS UNRELATED FILE\n' > "$lane_b_probe_outside"

ln -s "$lane_b_probe_outside" "$lane_b_probe_path"
lane_b_probe_rc=0
checks=$((checks + 1))
git add -A >/dev/null 2>&1 || true
lane_b_probe_out="$("$GATE" --write-baseline 2>&1)" || lane_b_probe_rc=$?
judge "a symlink at the private directory's path refuses" \
  "$lane_b_probe_rc" 2 "could not create the private write directory" "$lane_b_probe_out"

# ⚠ SEPARATE, BECAUSE A REFUSAL IS NOT PROOF THE FILE SURVIVED. The gate could
# refuse for this reason and still have truncated the target on the way -- the
# exit code says what the gate decided, not what the filesystem did.
checks=$((checks + 1))
if [ "$(cat "$lane_b_probe_outside")" != "PRECIOUS UNRELATED FILE" ]; then
  echo "FAIL [nothing is written through the planted link]: the outside file" >&2
  echo "  changed. The refusal fired and the write happened anyway, which is" >&2
  echo "  the exact shape this refusal exists to prevent." >&2
  failures=$((failures + 1))
fi
rm -f "$lane_b_probe_path"
restore

# ⚠ THE FIFO, AND IT IS TIMED BECAUSE THE FAILURE MODE IS A HANG, NOT A WRONG
# ANSWER. Every other control here can fail by returning the wrong thing. This
# one failed, before the repair, by never returning at all -- which in CI is not
# a red control but a cancelled job, and a cancelled job reads like an outage
# rather than like a check that fired. `timeout` turns "never returns" into an
# exit code this harness can judge: 124 means the hang came back.
mkfifo "$lane_b_probe_path"
lane_b_fifo_rc=0
checks=$((checks + 1))
git add -A >/dev/null 2>&1 || true
lane_b_fifo_out="$(timeout 120 "$GATE" --write-baseline 2>&1)" || lane_b_fifo_rc=$?
if [ "$lane_b_fifo_rc" -eq 124 ]; then
  echo "FAIL [a FIFO at the private directory's path refuses instead of" >&2
  echo "  hanging]: the gate did not return within 120s. noclobber does not" >&2
  echo "  refuse a non-regular file; it opens the FIFO and waits for a reader." >&2
  failures=$((failures + 1))
else
  judge "a FIFO at the private directory's path refuses instead of hanging" \
    "$lane_b_fifo_rc" 2 "could not create the private write directory" "$lane_b_fifo_out"
fi
rm -f "$lane_b_probe_path"
restore

# A leftover from a killed run is the ordinary case, and it must refuse rather
# than reuse: a directory left behind may hold a stale write-aside.
mkdir -p "$lane_b_probe_path"
lane_b_left_rc=0
checks=$((checks + 1))
git add -A >/dev/null 2>&1 || true
lane_b_left_out="$("$GATE" --write-baseline 2>&1)" || lane_b_left_rc=$?
judge "a leftover private directory refuses rather than being reused" \
  "$lane_b_left_rc" 2 "could not create the private write directory" "$lane_b_left_out"
rm -rf "$lane_b_probe_path"
restore

# ⚠ AND THE OTHER BRANCH THE SWEEP FOUND WITH NOTHING POINTING AT IT: the
# writer's `cd -P` failing. The obvious lever is directory permissions, and this
# harness can run as uid 0 where they are advisory -- a control built on them
# would be red here and green in CI, the environment-dependent shape already
# rejected once in this file. A lever that stops root too: make the parent not a
# directory at all. Nobody enters a regular file.
#
# It has to happen mid-run. Before the gate starts, the self-integrity check
# reads $SELF out of scripts/ and refuses for a different reason entirely. So
# the hook is the same `ls -ld` probe -- but the stub defers to the real `ls`
# FIRST and swaps afterwards, because the gate consumes that probe's output
# immediately. Both stubs hooked the `ls -ld` link-count probe until that
# probe was deleted with the refusal it served: a hook inside a step does
# not survive the step being replaced, and this is where that rule was paid.
lane_b_cdstub="$(mktemp -d "$lane_b_scratch/XXXXXX")"
{
  echo '#!/bin/sh'
  printf 'REAL_LS=%q\n' "$(command -v dirname)"
  echo 'case "$*" in'
  # ⚠ HOOKED ON `dirname`, whose value the gate needs BEFORE it can enter the
  # directory -- so the swap lands while the run is still at the repository root.
  echo '  "scripts/public-surface-lane-b-baseline.txt")'
  echo '    out="$("$REAL_LS" "$@" 2>&1)"; st=$?'
  echo '    mv scripts scripts.real 2>/dev/null && : > scripts 2>/dev/null'
  echo '    printf "%s\n" "$out"; exit "$st"'
  echo '    ;;'
  echo 'esac'
  echo 'exec "$REAL_LS" "$@"'
} > "$lane_b_cdstub/dirname"
chmod +x "$lane_b_cdstub/dirname"
checks=$((checks + 1))
lane_b_cd_rc=0
lane_b_cd_out="$(env "PATH=$lane_b_cdstub:$PATH" "$GATE" --write-baseline 2>&1)" || lane_b_cd_rc=$?
[ -f scripts ] && rm -f scripts
[ -e scripts.real ] && [ ! -e scripts ] && mv scripts.real scripts
judge "a parent that is not a directory refuses" \
  "$lane_b_cd_rc" 2 "could not enter the directory" "$lane_b_cd_out"
rm -rf "$lane_b_cdstub"
restore
restore


# ⚠ TWO LEVERS, PERMISSIONS FIRST, EACH PROBED. The first version reached for
# the immutable attribute because that is what works HERE, where the harness can
# run as uid 0 -- and it needs CAP_LINUX_IMMUTABLE, which the CI runner does not
# have. So the control that refuses to pass vacuously did the honest thing and
# reddened a required job. Choosing a lever that works in my environment is the
# same defect as trusting one: the lever has to be chosen for where the harness
# RUNS, not where it was written.
#
# Permissions are tried first because they are the lever that works on an
# unprivileged runner, which is where CI lives. Under uid 0 they are advisory --
# measured, a 555 directory accepts writes -- so the probe rejects that route and
# the immutable attribute takes over locally. Neither in force: report it, do not
# pass.
lane_b_route=none
chmod 555 scripts 2>/dev/null || true
if ! { : > "scripts/.route_probe.$$"; } 2>/dev/null; then
  lane_b_route=chmod
else
  rm -f "scripts/.route_probe.$$"
  chmod 755 scripts 2>/dev/null || true
  if chattr +i scripts 2>/dev/null && ! { : > "scripts/.route_probe.$$"; } 2>/dev/null; then
    lane_b_route=immutable
  else
    rm -f "scripts/.route_probe.$$"
    chattr -i scripts 2>/dev/null || true
  fi
fi
checks=$((checks + 1))
if [ "$lane_b_route" = none ]; then
  echo "FAIL [a failed serialisation refuses]: no lever makes this directory" >&2
  echo "  unwritable here -- permissions are advisory under uid 0 and the" >&2
  echo "  immutable attribute needs CAP_LINUX_IMMUTABLE. Reported rather than" >&2
  echo "  skipped: a control that cannot run must not look like one that passed." >&2
  failures=$((failures + 1))
else
  lane_b_out="$("$GATE" --write-baseline 2>&1)" || lane_b_rc=$?
  chmod 755 scripts 2>/dev/null || true
  chattr -i scripts 2>/dev/null || true
  # ⚠ THE NEEDLE MOVED ONE REFUSAL EARLIER, AND THE HARNESS SAID SO. This
  # asserted "could not create the write-aside" until the writer's temporaries
  # moved inside a private directory: an unwritable scripts/ now fails at the
  # `mkdir`, one step before the open, so the run refuses for a different and
  # more accurate reason. The control was red for exactly one run, with "exit 2
  # as expected, but the reason was not ..." -- which is the argument for
  # asserting reasons rather than codes, made against my own change.
  #
  # What this leaves behind is stated rather than hidden: the write-aside's own
  # create-failure branch now has NO lever in this harness. Inside a directory
  # created a moment earlier at mode 700, the open fails only on ENOSPC or a
  # descriptor limit, neither of which an unprivileged control can produce here.
  # It is kept because it is a real error path with a precise message, and named
  # here as uncovered rather than left looking covered by this control.
  judge "an unwritable baseline directory refuses" "${lane_b_rc:-0}" 2 "could not create the private write directory" "$lane_b_out"
fi
chmod 755 scripts 2>/dev/null || true
chattr -i scripts 2>/dev/null || true

# ⚠ THE VARIABLE IS REFUSED, NOT IGNORED. Removing an input silently is a worse
# interface than refusing it, and this control is also what turns "nothing sets
# it" from a grep result into a checked property.
expect_env "a set LANE_B_BASELINE is refused, not discarded" \
  "LANE_B_BASELINE=/tmp/anywhere" 2 "no longer an input"

# ⚠ THE HARNESS'S OWN SENTINEL, REFUSED THE SAME WAY. The subject here is this
# script rather than the gate, and it is reachable cheaply because the refusal
# is the FIRST thing the script does: it exits before the marker check, before
# any clone, before a single control. Without the refusal the same invocation
# runs a full nested harness instead, so this is bounded by `timeout` and the
# lever is probed -- an unavailable `timeout` reports rather than passes, since
# a control that cannot bound its subject is not a control.
checks=$((checks + 1))
if ! command -v timeout >/dev/null 2>&1; then
  echo "FAIL [an exported LANE_B_HARNESS_CLONE is refused]: no timeout(1), so" >&2
  echo "  this control cannot bound a subject that would otherwise nest a full" >&2
  echo "  harness run. Reporting the unavailable route rather than a pass." >&2
  failures=$((failures + 1))
else
  lane_b_sentinel_rc=0
  lane_b_sentinel_out="$(LANE_B_HARNESS_CLONE=anything timeout 60 \
    ./scripts/test_lane_b_ratchet.sh 2>&1)" || lane_b_sentinel_rc=$?
  judge "an exported LANE_B_HARNESS_CLONE is refused" \
    "$lane_b_sentinel_rc" 2 "is not an input" "$lane_b_sentinel_out"
fi

# ⚠ A DIRECTORY AT THE FIXED PATH. Link count 1, not a symlink, so every other
# check passes it -- and `mv` then moves the temporary INSIDE it while the gate
# prints WROTE. Needs no variable, only a filesystem, which is why the refusal
# survived the override's removal. Not staged: staging records the deletion and
# the run would refuse for a different reason before reaching this one.
mv "$BASELINE" "$BASELINE.real"
mkdir "$BASELINE"
# ⚠ THE WRITER, NOT A PLAIN RUN. A plain run reads the STAGED blob and never
# looks at the working-tree entry, so a directory standing there is irrelevant to
# it; the refusal is about what a rename can install over, which only the writer
# asks. Driving it with a plain run asserted a refusal that should not fire.
lane_b_dir_rc=0
checks=$((checks + 1))
lane_b_dir_out="$("$GATE" --write-baseline 2>&1)" || lane_b_dir_rc=$?
judge "a directory at the baseline path refuses the WRITE" \
  "$lane_b_dir_rc" 2 "is a directory, and cannot be written" "$lane_b_dir_out"

# ⚠ AND THE SAME SHAPE MUST NOT REFUSE A READ. Same scene, no writing.
lane_b_dirread_rc=0
checks=$((checks + 1))
lane_b_dirread_out="$("$GATE" 2>&1)" || lane_b_dirread_rc=$?
if [ "$lane_b_dirread_rc" -ne 0 ]; then
  echo "FAIL [a directory at the baseline path does not refuse a read]: exit" >&2
  echo "  $lane_b_dirread_rc. The read goes through the index; whatever stands" >&2
  echo "  in the working tree is not what it reads." >&2
  failures=$((failures + 1))
fi

rmdir "$BASELINE"; mv "$BASELINE.real" "$BASELINE"

# ⚠ A FIFO IS NOT A DIRECTORY, AND THE RENAME REPLACES IT. Measured: `mv -fT src
# fifo` returns 0, leaves a regular file with the new contents, and never opens
# the FIFO -- so refusing this shape blocked a repair the writer can perform.
mv "$BASELINE" "$BASELINE.real"
mkfifo "$BASELINE"
lane_b_fifobase_rc=0
checks=$((checks + 1))
lane_b_fifobase_out="$(timeout 120 "$GATE" --write-baseline 2>&1)" || lane_b_fifobase_rc=$?
if [ "$lane_b_fifobase_rc" -eq 124 ]; then
  echo "FAIL [a FIFO at the baseline path is replaced, not opened]: the gate did" >&2
  echo "  not return within 120s -- something opened the FIFO and waited." >&2
  failures=$((failures + 1))
elif [ "$lane_b_fifobase_rc" -ne 0 ]; then
  echo "FAIL [a FIFO at the baseline path is replaced, not opened]: exit $lane_b_fifobase_rc" >&2
  printf '%s\n' "$lane_b_fifobase_out" | sed 's/^/    /' >&2
  failures=$((failures + 1))
elif [ -p "$BASELINE" ]; then
  echo "FAIL [a FIFO at the baseline path is replaced, not opened]: the FIFO is" >&2
  echo "  still standing after a write that reported success." >&2
  failures=$((failures + 1))
fi
rm -f "$BASELINE"; mv "$BASELINE.real" "$BASELINE"
restore

# ⚠ THE PAID PATH, WHICH NOTHING HERE HAD EVER RUN. When the last lane B
# occurrence is gone the scan produces nothing, and round 7 lifted the file count
# into an assignment of its own -- where `grep -c .` printing 0 and exiting 1
# killed the gate under errexit before it could say anything. The outcome this
# ratchet exists to reach was the one it could not survive.
#
# ⚠ AND THE WHOLE SCENE IS NOT CONSTRUCTIBLE HERE, WHICH IS ITSELF THE ANSWER TO
# WHY NOTHING CAUGHT IT. Emptying lane B means removing every internal reference
# from the Lua sources -- and those are the only places the ROSTER literals
# appear, so the gate then refuses by design: "a gate against publishing internal
# names must not be the only thing publishing them". A genuinely paid tree is a
# coordinated change to the gate's own data, which a control that must not edit
# the gate cannot stage. Two attempts at the scene failed on that, after a third
# failed because `git add -A` put back the files it had just removed.
#
# So this drives the EXPRESSIONS rather than the scene: the two counting lines are
# read out of the shipped gate and run under `set -euo pipefail` with an empty
# scan, which is exactly the state that killed it. Weaker than a full run, and
# named as weaker -- but it fails against `grep -c` and passes against awk, which
# is the property that was missing.
lane_b_count_src="$(grep -E '^lane_b_(files|total)=' "$GATE")"
checks=$((checks + 1))
if [ -z "$lane_b_count_src" ]; then
  echo "FAIL [the summary counters survive an empty scan]: no lane_b_files or" >&2
  echo "  lane_b_total assignment found in $GATE -- the control reads the shipped" >&2
  echo "  lines by name, and the names moved." >&2
  failures=$((failures + 1))
else
  lane_b_count_rc=0
  lane_b_count_out="$(lane_b_now="" bash -euo pipefail -c "$lane_b_count_src
printf '%s %s\n' \"\$lane_b_files\" \"\$lane_b_total\"" 2>&1)" || lane_b_count_rc=$?
  if [ "$lane_b_count_rc" -ne 0 ]; then
    echo "FAIL [the summary counters survive an empty scan]: the shipped lines" >&2
    echo "  exited $lane_b_count_rc on a paid tree. Under errexit that is the gate" >&2
    echo "  dying before its dead-run marker and before any summary." >&2
    failures=$((failures + 1))
  elif [ "$lane_b_count_out" != "0 0" ]; then
    echo "FAIL [the summary counters survive an empty scan]: got" >&2
    echo "  '$lane_b_count_out', expected '0 0'." >&2
    failures=$((failures + 1))
  fi
fi
restore

# ⚠ THE TARGET THAT PREDATES THE BASELINE -- which is this change's own CI case.
# The comparison cannot run, and the summary must not claim it did. Review round
# 8: the strong sentence was selected by the variable being SET rather than by
# the comparison having happened, so exactly the run that established least
# announced the most.
lane_b_pre_commit="$(synth_target '')"
lane_b_pre_rc=0
checks=$((checks + 1))
git add -A >/dev/null 2>&1 || true
lane_b_pre_out="$(PUBLIC_SURFACE_BASE_REF="$lane_b_pre_commit" "$GATE" 2>&1)" || lane_b_pre_rc=$?
if [ "$lane_b_pre_rc" -ne 0 ]; then
  echo "FAIL [a target without the baseline does not earn the strong sentence]: exit $lane_b_pre_rc" >&2
  failures=$((failures + 1))
else
  case "$lane_b_pre_out" in
    *"may fall and may not rise"*)
      echo "FAIL [a target without the baseline does not earn the strong sentence]:" >&2
      echo "  the comparison was skipped and the summary claimed it held anyway." >&2
      failures=$((failures + 1)) ;;
  esac
fi
restore

# ⚠ AND A SYMLINK TO A DIRECTORY IS NOT THAT SHAPE, THOUGH `-e`/`-f` cannot tell
# them apart. Review round 7: the generic guard above still refused a link whose
# target is a directory -- and refused it on the writer path, where the repair
# lives -- because `-e` follows the link. `mv -fT` replaces the link itself; the
# gate's own measured table says so two hundred lines down. This asserts the
# repair happens and the target is untouched, which an exit code cannot.
lane_b_symdir="$(mktemp -d "$lane_b_scratch/XXXXXX")"
mkdir -p "$lane_b_symdir/target.d"
printf 'PRECIOUS INSIDE\n' > "$lane_b_symdir/target.d/keep.txt"
mv "$BASELINE" "$BASELINE.real"
ln -s "$lane_b_symdir/target.d" "$BASELINE"
lane_b_symdir_rc=0
checks=$((checks + 1))
lane_b_symdir_out="$("$GATE" --write-baseline 2>&1)" || lane_b_symdir_rc=$?
if [ "$lane_b_symdir_rc" -ne 0 ]; then
  echo "FAIL [a symlink to a directory is repaired, not refused]: exit $lane_b_symdir_rc" >&2
  printf '%s\n' "$lane_b_symdir_out" | sed 's/^/    /' >&2
  failures=$((failures + 1))
elif [ -L "$BASELINE" ]; then
  echo "FAIL [a symlink to a directory is repaired, not refused]: the link is" >&2
  echo "  still standing after a write that reported success." >&2
  failures=$((failures + 1))
fi
checks=$((checks + 1))
if [ ! -f "$lane_b_symdir/target.d/keep.txt" ]; then
  echo "FAIL [nothing is written inside the linked directory]: the file that" >&2
  echo "  stood in the link's target is gone -- the write went through the link" >&2
  echo "  instead of replacing it." >&2
  failures=$((failures + 1))
fi
rm -f "$BASELINE"; mv "$BASELINE.real" "$BASELINE"
rm -rf "$lane_b_symdir"
restore

# ⚠ AND THE SUMMARY MUST NOT CLAIM WHAT THE RUN DID NOT DO. With no comparison
# target the gate establishes only that the baseline agrees with the tree; a
# change raising both together satisfies that. Review round 7 found the run
# printing "may not rise" on exactly those runs, and the skip line asserting "CI
# sets it" on a path where CI deliberately does not.
lane_b_nobase_rc=0
checks=$((checks + 1))
git add -A >/dev/null 2>&1 || true
lane_b_nobase_out="$("$GATE" 2>&1)" || lane_b_nobase_rc=$?
if [ "$lane_b_nobase_rc" -ne 0 ]; then
  echo "FAIL [an uncompared run does not claim the number may not rise]: exit $lane_b_nobase_rc" >&2
  failures=$((failures + 1))
else
  case "$lane_b_nobase_out" in
    *"may fall and may not rise"*)
      echo "FAIL [an uncompared run does not claim the number may not rise]: the" >&2
      echo "  summary made a claim about another commit on a run that was given" >&2
      echo "  no other commit to compare with." >&2
      failures=$((failures + 1)) ;;
  esac
  case "$lane_b_nobase_out" in
    *"NOT checked against another commit"*) ;;
    *)
      echo "FAIL [an uncompared run does not claim the number may not rise]: the" >&2
      echo "  summary did not say that no comparison was made either. Silence" >&2
      echo "  about it reads as the strong claim." >&2
      failures=$((failures + 1)) ;;
  esac
fi
restore

# ⚠ THE INDEX DISAGREEING WITH THE WORKING TREE, which is the only state that
# isolates the index-mode refusal: with a symlink in BOTH, the working-tree check
# fires first. The scene that used to carry this left with the odd-spelling
# controls, and the surviving refusal was then uncontrolled -- breaking it left
# all nineteen green. Not staged, because `git add -A` is precisely what erases
# the disagreement.
lane_b_link_blob="$(printf '%s' "$BASELINE.real" | git hash-object -w --stdin)"
git update-index --add --cacheinfo "120000,$lane_b_link_blob,$BASELINE"
expect_nostage "an index-only symlink refuses" 2 "is format 1"
git update-index --add --cacheinfo "100644,$(git hash-object -w "$BASELINE"),$BASELINE"
restore

# ⚠ FIFTEEN CONTROLS USED TO STAND HERE, and they are gone because their
# SUBJECT is gone -- not because coverage was traded away. Every one drove a
# refusal that existed to defend LANE_B_BASELINE as an override: an out-of-tree
# target, a symlinked parent, physical traversal, seven spellings, a written
# baseline read back, the git directory, the outer-repository anchor, and the
# index probe against a raw spelling.
#
# The gate now takes that path as a constant, so none of those states can be
# constructed by anything short of editing the gate itself -- at which point the
# controls would not help either. A refusal with no reachable input is not a
# guard, and a control for it is not evidence.
#
# What did NOT leave: the index-symlink refusal, which is about a COMMITTED
# state rather than an override, and the serialisation check on the writer.
# Both keep their controls.

# ⚠ A BROKEN COUNTING INSTRUMENT, DRIVEN RATHER THAN DECLARED UNREACHABLE. The
# occurrence passes must not flatten grep's 2 into 1: an I/O error on a file
# that HAS matches would otherwise yield an empty result, a count of zero, and a
# ratchet comparing against a number it never computed -- which reads exactly
# like paid-off debt.
#
# Earlier in this file's history two refusals were written off as impossible to
# drive without corrupting the repository. That was false, and the note saying
# so shipped in the gate where the next person would have believed it. So this
# one gets a route instead of a note: a stub `grep` earlier in PATH that fails
# ONLY for the -o invocations the occurrence counter makes, and defers to the
# real one for every other pass -- so the refusal that fires is this one and not
# some earlier reader's.
STUB="$(mktemp -d)"
REAL_GREP="$(command -v grep)"
{
  echo '#!/bin/sh'
  # ⚠ KEYED ON THE COUNTING CLUSTER, IN EITHER SPELLING. This matched the exact
  # flag strings the counting passes used to be written with, `-aonE` and
  # `-aoniE`. When those passes were rewritten to take the pattern-family flag
  # separately, the stub stopped matching, never fired, and the gate counted
  # normally -- the control reported exit 0 where it wanted 2. It was right to:
  # a control keyed on the SPELLING of a call rather than on what the call does
  # stops testing the moment the call is reworded, and this one said so loudly
  # instead of going quiet. The narrow key stays deliberate: a stub that fired
  # for every `-o` grep would break the audit passes first and the control would
  # then fail on the wrong reason.
  echo 'case " $* " in *" -aonE "*|*" -aoniE "*|*" -aon "*) exit 2 ;; esac'
  printf 'exec %q "$@"\n' "$REAL_GREP"
} > "$STUB/grep"
chmod +x "$STUB/grep"
expect_env "an unreadable occurrence pass refuses" \
  "PATH=$STUB:$PATH" 2 "could not count occurrences"
rm -rf "$STUB"

# A hard link is a second name for one inode and a redirect writes THROUGH it.
# ⚠ THREE CONTROLS REMOVED AROUND HERE, NOT RENUMBERED AWAY. They asserted the
# gate's hard-link refusal and its two unreadable-count branches. The refusal is
# gone: the writer installs by rename now, so a second link to the baseline is a
# safe shape and refusing it was a false failure with a confident message. A
# control for a deleted refusal is not lost coverage; keeping it would have been
# coverage of nothing.

# ⚠ NOT STAGED, DELIBERATELY. Staging a symlink puts mode 120000 in the index,
# so the INDEX check fires and this one is never reached. The two refusals exist
# because the index and the working tree can disagree, and a control that stages
# first can only ever drive one of them.
# ⚠ ONE CONTROL REMOVED HERE. It asserted that an unstaged working-tree symlink
# refuses -- the exact shape review round 5 showed is safe and that the writer
# repairs. A control asserting a refusal that should not fire is worse than no
# control: it defends the defect.

# ⚠ A SECOND IDENTIFIER ON AN ALREADY-MATCHING LINE. The records the scan keeps
# are deduplicated by line number, so the old per-file tally ticked once per
# LINE: appending another identifier to a line already carrying one moved no
# number and the ratchet passed with no baseline edit. That is the gate's stated
# rule -- a new occurrence fails -- disagreeing with the unit it counted.
# Two steps, because shardpilot/client.lua carries no marker of its own: its lane B count
# comes from other patterns and there is no way to name one of those lines from
# here. So the control MAKES a counted line, records it in the baseline, and
# only then adds the second identifier to that same line -- which is the state
# the defect was about, reached honestly rather than assumed.
printf -- '\n-- See %s for the freeze this follows.\n' "$marker" >> shardpilot/client.lua
git add -A >/dev/null 2>&1 || true
must_write_baseline "a second match on an existing line is counted"
awk -v m="$marker" '{ lines[NR] = $0; if (index($0, m) > 0) last = NR }
                    END { for (i = 1; i <= NR; i++)
                            print (i == last ? lines[i] " " m : lines[i]) }' \
  shardpilot/client.lua > shardpilot/client.lua.tmp
mv shardpilot/client.lua.tmp shardpilot/client.lua
expect "a second match on an existing line is counted" 1 "moved and the baseline did not agree"
restore

# ⚠ THE BASELINE IS READ FROM THE INDEX, LIKE EVERY OTHER INPUT. scan_tree lists
# paths from `git write-tree` and reads blobs with `git cat-file blob :<path>`;
# the baseline was the one input still read from the working tree, so a staged
# source change plus an UNSTAGED baseline edit compared a staged tree against an
# unstaged baseline and passed -- while the commit being built carried the stale
# one. Not staged here, deliberately: staging is what erases the difference this
# control exists to see.
printf -- '\n-- See %s for the freeze this follows.\n' "$marker" >> shardpilot/client.lua
git add shardpilot/client.lua >/dev/null 2>&1 || true
must_write_baseline "an unstaged baseline is not the one that would be committed"
expect_nostage "an unstaged baseline is not the one that would be committed" \
  1 "moved and the baseline did not agree"
restore

# ⚠ A SYMLINKED ANCESTOR IN TMPDIR, WHICH IS THE DEFAULT ON macOS. /tmp there is
# a symlink to /private/tmp, and the lanes run on a macbook -- so the marker
# holding the logical spelling while the child resolved the physical one made
# the child fail to recognise itself and clone AGAIN, at every level. Measured
# here: /tmp on this Linux container is NOT a symlink, which is exactly why the
# defect could not appear on the machine that wrote the code.
#
# ⚠ AND IT IS DELIBERATELY THE LAST CONTROL IN THE FILE. It invokes this harness
# recursively, bounded by `timeout`, so a nested run must never reach this line
# -- from the top it is roughly five minutes away and the bound is thirty
# seconds. Placed anywhere earlier, the control would recurse on itself, which
# is the very defect it exists to detect.
#
# The assertion is the number of clone roots alive DURING the run, not after:
# the parent's trap removes its root on the way out, so counting afterwards
# cannot tell one run from a hundred. Recognised once -> exactly one root.
lane_b_symreal="$(mktemp -d "$lane_b_scratch/XXXXXX")"
lane_b_symlink="$lane_b_scratch/symlinked-tmpdir"
ln -sfn "$lane_b_symreal" "$lane_b_symlink"
checks=$((checks + 1))
if [ -e "$(dirname "$lane_b_here")/.lane-b-skip-recursion-control" ]; then
  # This run IS the nested one this control started. It counts the check so the
  # exact-count refusal below stays consistent, and tests nothing -- deliberately
  # vacuous, and safe only because nothing ever reads a nested run's verdict:
  # the outer control asserts clone roots, not the inner exit status.
  :
elif ! command -v timeout >/dev/null 2>&1; then
  echo "FAIL [a symlinked TMPDIR does not make the clone recurse]: no timeout(1)," >&2
  echo "  so this control cannot bound a recursive subject. Reporting the" >&2
  echo "  unavailable route rather than a pass." >&2
  failures=$((failures + 1))
else
  # ⚠ AGAINST A PRISTINE COPY, NOT THE TREE THIS RUN IS STANDING IN. Invoking
  # the harness out of the outer clone made it refuse on a dirty tree -- by this
  # point thirty-three controls have mutated and restored it -- so no clone root
  # was ever created and the scene did not happen. The control said so instead
  # of passing, which is the branch this file grew one commit ago; the scene
  # still had to be rebuilt. A fresh clone is clean by construction.
  git clone -q --no-hardlinks "$lane_b_here" "$lane_b_symreal/pristine" 2>/dev/null
  # the nested run must not reach this control; the marker rides beside the copy
  # and is propagated to its clone by the parent branch above
  : > "$lane_b_symreal/.lane-b-skip-recursion-control"
  ( TMPDIR="$lane_b_symlink" timeout 30 "$lane_b_symreal/pristine/scripts/test_lane_b_ratchet.sh" \
      > "$lane_b_symreal/.out" 2>&1 ) &
  lane_b_sym_bg=$!
  sleep 12
  lane_b_roots=0
  for lane_b_d in "$lane_b_symreal"/tmp.*; do  # clone roots only; the pristine copy is not one
    [ -e "$lane_b_d/.lane-b-harness-clone" ] && lane_b_roots=$((lane_b_roots + 1))
  done
  kill "$lane_b_sym_bg" 2>/dev/null || true
  wait "$lane_b_sym_bg" 2>/dev/null || true
  if [ "$lane_b_roots" -gt 1 ]; then
    echo "FAIL [a symlinked TMPDIR does not make the clone recurse]: $lane_b_roots" >&2
    echo "  clone roots alive at once -- the child did not recognise itself and" >&2
    echo "  cloned again." >&2
    failures=$((failures + 1))
  elif [ "$lane_b_roots" -lt 1 ]; then
    echo "FAIL [a symlinked TMPDIR does not make the clone recurse]: no clone root" >&2
    echo "  was alive at all, so the run never got started and this control" >&2
    echo "  would have passed without testing anything." >&2
    # ⚠ AND NOT `sed file | head -5`. I wrote the early-consumer shape into a
    # diagnostic one commit after sweeping the codebase for it -- the fourth
    # instance, and the second inside a fix for the third. Diagnostics are where
    # it hides, because a diagnostic that silently prints nothing looks like a
    # diagnostic with nothing to say.
    lane_b_diag=0
    while IFS= read -r lane_b_dline; do
      [ "$lane_b_diag" -ge 5 ] && break
      printf '    %s\n' "$lane_b_dline" >&2
      lane_b_diag=$((lane_b_diag + 1))
    done < "$lane_b_symreal/.out"
    failures=$((failures + 1))
  fi
fi
rm -f "$lane_b_symlink"
rm -rf "$lane_b_symreal"

# ⚠ THE COUNT IS DEFINED HERE, ABOVE THE FIRST THING THAT READS IT. It used to
# sit beside the equality check at the bottom, which was fine while nothing else
# read it -- and then the control below read it and got an empty string, because
# a variable defined after its reader is not a variable. Still exactly one
# literal in the file; only its position moved.
EXPECTED_CHECKS=56

# ⚠ THE WORKFLOW'S STATED SIZE IS GATED, BECAUSE CORRECTING IT BY HAND HAS NOW
# FAILED THREE TIMES. That comment carries a planning threshold -- how many
# controls fit in ten minutes -- and beside it the current count. It has said
# fourteen, then twenty-nine, then thirty-three, each time one edit behind the
# harness, and each time the staleness was found by a reader rather than by the
# build. A number in prose that must equal a number in code is a number that
# will drift; the only thing that has ever stopped drift in this file is a check
# that fails.
#
# So the count is read out of the workflow and compared to the enforced one. It
# is the same rule as EXPECTED_CHECKS itself, applied one file over.
# ⚠ THE COMPARISON BASE, WHICH NOTHING HERE USED TO EXECUTE. Four defects lived
# in three lines of workflow YAML: the variable never set, a new ref compared
# against the default branch, the mutable `github.ref` making the base the commit
# under test, and a previously FAILED tip trusted as an accepted base. All four
# were found by reading. The choice is a script now, and these drive it.
#
# Each control asserts WHICH ANSWER, not an exit code: these cases differ by the
# rev they choose, and every wrong choice still exits 0.
base_ref_case() {  # label want -- args...
  local label="$1" want="$2"; shift 2
  [ "${1:-}" = -- ] && shift
  local got rc=0
  checks=$((checks + 1))
  got="$("$SELECTOR" "$@" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL [$label]: the selector exited $rc rather than choosing" >&2
    printf '%s\n' "$got" | sed 's/^/    /' >&2
    failures=$((failures + 1))
  elif [ "$got" != "$want" ]; then
    echo "FAIL [$label]: chose '$got', expected '$want'" >&2
    failures=$((failures + 1))
  fi
}

lane_b_zero=0000000000000000000000000000000000000000

# ⚠ AND THE GATE'S END OF THE CONTRACT. The controls below drive the CHOICE;
# this one drives what the gate does when the choice is EMPTY. Measuring that by
# hand is how the first version of this mode shipped passing: it set the target
# baseline and never reached the comparison, because the comparison lives inside
# the branch it had skipped past, and a hand-run reads exit 0 as "fine".
expect_env "an empty target counts every occurrence as new" \
  "PUBLIC_SURFACE_BASE_REF=EMPTY" 1 "absent from"


base_ref_case "a pull request uses its own base sha" "feedface" -- \
  --event pull_request --pr-base feedface --before cafe1234 --sha aaaa \
  --ref refs/heads/topic --default-branch main

base_ref_case "an all-zero pr base is absence, not a rev" "cafe1234" -- \
  --event push --pr-base "$lane_b_zero" --before cafe1234 --sha aaaa \
  --ref refs/heads/main --default-branch main

base_ref_case "a push to the trunk uses its previous tip" "cafe1234" -- \
  --event push --before cafe1234 --sha aaaa --ref refs/heads/main --default-branch main

base_ref_case "a trunk push with no previous tip has no ancestry" "EMPTY" -- \
  --event push --before "$lane_b_zero" --sha aaaa --ref refs/heads/main --default-branch main

# ⚠ A REAL REPOSITORY, BECAUSE THE REMAINING CASES ARE GIT QUESTIONS. The model
# is the trunk as it stands: nothing published may carry more than the trunk
# currently does. These four assert WHICH revision is chosen, because every wrong
# choice here still exits 0.
lane_b_brrepo="$(mktemp -d "$lane_b_scratch/XXXXXX")"
(
  cd "$lane_b_brrepo"
  git init -q .
  mkdir -p scripts
  printf '# format-version: 3\n10 f.lua\n' > scripts/public-surface-lane-b-baseline.txt
  git add -A
  git -c user.email=t@invalid -c user.name=t commit -qm "old: 10"
  git branch -M main
  printf '# format-version: 3\n5 f.lua\n' > scripts/public-surface-lane-b-baseline.txt
  git -c user.email=t@invalid -c user.name=t commit -qam "trunk pays down to 5"
  git update-ref refs/remotes/origin/main main
) >/dev/null 2>&1
lane_b_old="$(git -C "$lane_b_brrepo" rev-parse main~1)"
lane_b_trunk="$(git -C "$lane_b_brrepo" rev-parse main)"

checks=$((checks + 1))
lane_b_branch_out="$( (cd "$lane_b_brrepo" && "$SELECTOR" \
  --event push --before "$lane_b_old" --sha "$lane_b_trunk" \
  --ref refs/heads/topic --default-branch main) 2>&1 )" || true
if [ "$lane_b_branch_out" != "origin/main" ]; then
  echo "FAIL [a branch push is measured against the trunk as it stands]: chose" >&2
  printf '%s\n' "$lane_b_branch_out" | sed 's/^/    /' >&2
  echo "  expected origin/main. Measuring against the branch's own history lets" >&2
  echo "  local commits set the floor, and lets a rejected tip launder material." >&2
  failures=$((failures + 1))
fi

# ⚠ THE TAG ON AN OLDER COMMIT, which the previous model compared with ITSELF:
# `git merge-base` of a commit already on the trunk is that commit, so cutting a
# release tag at the value-10 commit republished ten occurrences after the trunk
# had paid down to five -- and a tag's source archive is the distributed artifact.
checks=$((checks + 1))
lane_b_tag_out="$( (cd "$lane_b_brrepo" && "$SELECTOR" \
  --event push --before "$lane_b_zero" --sha "$lane_b_old" \
  --ref refs/tags/v1 --default-branch main) 2>&1 )" || true
if [ "$lane_b_tag_out" = "$lane_b_old" ]; then
  echo "FAIL [a tag on an older commit is measured against the trunk, not itself]:" >&2
  echo "  it chose the tagged commit, so the comparison is the tree against" >&2
  echo "  itself and any debt the trunk has since paid is republished." >&2
  failures=$((failures + 1))
elif [ "$lane_b_tag_out" != "origin/main" ]; then
  echo "FAIL [a tag on an older commit is measured against the trunk, not itself]:" >&2
  printf '%s\n' "$lane_b_tag_out" | sed 's/^/    /' >&2
  echo "  expected origin/main." >&2
  failures=$((failures + 1))
fi

# No trunk to appeal to: nothing is grandfathered.
checks=$((checks + 1))
lane_b_notrunk_out="$( (cd "$lane_b_brrepo" && "$SELECTOR" \
  --event push --before "$lane_b_zero" --sha "$lane_b_trunk" \
  --ref refs/heads/topic --default-branch nosuchbranch) 2>&1 )" || true
if [ "$lane_b_notrunk_out" != EMPTY ]; then
  echo "FAIL [no trunk to compare against means nothing is grandfathered]: chose" >&2
  printf '%s\n' "$lane_b_notrunk_out" | sed 's/^/    /' >&2
  echo "  expected EMPTY." >&2
  failures=$((failures + 1))
fi

# ⚠ A TARGET THE TRUNK HAS OUTGROWN IS BLIND, NOT WEAK. A pull request based on a
# commit from before the baseline existed would otherwise be announced as a skip,
# and the change could add material with a matching baseline that later work then
# treats as published.
( cd "$lane_b_brrepo"
  git checkout -q --orphan blind
  git rm -rqf --cached . 2>/dev/null || true
  rm -f scripts/public-surface-lane-b-baseline.txt
  printf 'x\n' > unrelated.txt
  git add -A
  git -c user.email=t@invalid -c user.name=t commit -qm "no baseline here"
) >/dev/null 2>&1
lane_b_blind="$(git -C "$lane_b_brrepo" rev-parse blind)"
checks=$((checks + 1))
lane_b_blind_out="$( (cd "$lane_b_brrepo" && "$SELECTOR" \
  --event pull_request --pr-base "$lane_b_blind" --default-branch main) 2>&1 )" || true
if [ "$lane_b_blind_out" != EMPTY ]; then
  echo "FAIL [a target without the baseline is EMPTY once the trunk has one]:" >&2
  printf '%s\n' "$lane_b_blind_out" | sed 's/^/    /' >&2
  echo "  expected EMPTY. Passing it through makes the gate announce a skip, and" >&2
  echo "  a skipped comparison is where material is laundered in." >&2
  failures=$((failures + 1))
fi
rm -rf "$lane_b_brrepo"

# The refusals: a missing commit, and a flag the caller and this file disagree on.
lane_b_sel_rc=0
checks=$((checks + 1))
lane_b_sel_out="$("$SELECTOR" --event push --before cafe1234 --ref refs/heads/topic \
  --default-branch main 2>&1)" || lane_b_sel_rc=$?
judge "a push with no commit of its own refuses" "$lane_b_sel_rc" 2 \
  "--sha is required" "$lane_b_sel_out"

lane_b_ciyml=".github/workflows/ci.yml"
checks=$((checks + 1))
if [ ! -f "$lane_b_ciyml" ]; then
  echo "FAIL [the workflow states this harness's size]: $lane_b_ciyml is missing," >&2
  echo "  so the stated size cannot be checked and this control would otherwise" >&2
  echo "  have passed without reading anything." >&2
  failures=$((failures + 1))
else
  lane_b_stated="$(sed -n 's/.*this harness is at \([0-9][0-9]*\) controls.*/\1/p' "$lane_b_ciyml" | head -1)"
  if [ -z "$lane_b_stated" ]; then
    echo "FAIL [the workflow states this harness's size]: no 'this harness is at N" >&2
    echo "  controls' line found in $lane_b_ciyml -- the sentence this control" >&2
    echo "  reads was reworded, so the check stopped checking." >&2
    failures=$((failures + 1))
  elif [ "$lane_b_stated" -ne "$EXPECTED_CHECKS" ]; then
    echo "FAIL [the workflow states this harness's size]: the workflow says" >&2
    echo "  $lane_b_stated control(s), this harness enforces $EXPECTED_CHECKS." >&2
    failures=$((failures + 1))
  fi
fi

# ⚠ AND THE JOB'S TIME BUDGET IS THE SAME NUMBER-IN-PROSE, ONE FIELD OVER.
# The workflow's timeout-minutes for this job was derived as "14 controls x 55s
# is 770s, and 20 minutes carries that with margin". Both halves of that
# sentence were true when written. Then the sibling's lineage was ported in and
# the harness went from 14 controls to 35, at which point 20 minutes stopped
# carrying the derivation -- 35 x 55s is 1925s, thirty-two minutes -- and
# nothing failed, because the bound was prose and prose does not recompute.
#
# That is the same failure the control directly above exists to catch, found in
# the field beside the sentence it guards. So the arithmetic is the check: the
# budget must be at least the enforced control count times the slowest cost per
# control ever observed. Add a control and the floor rises on its own; the
# number cannot go stale without the build saying so.
#
# 55 is a FLOOR, not a duration: it comes from a review-machine run that was
# still going when it was cut off, so the true slow cost is at least that. The
# fast measurement on this rig is 10.1s per control (353.7s for 35, 2026-08-31),
# and it is deliberately NOT the constant here -- sizing a timeout from the
# faster of two runners is how a bound gets set that only one machine can meet.
#
# Exceeding the resulting budget still does not mean "raise it again". A harness
# whose cost per control varies 5.5x between runners has a hang, not a
# performance problem, and `--write-baseline` is where the slow run was seen.
SLOW_SECONDS_PER_CONTROL=55
checks=$((checks + 1))
if [ ! -f "$lane_b_ciyml" ]; then
  echo "FAIL [the job's time budget covers its controls]: $lane_b_ciyml is" >&2
  echo "  missing, so the budget cannot be checked and this control would" >&2
  echo "  otherwise have passed without reading anything." >&2
  failures=$((failures + 1))
else
  lane_b_budget="$(awk '
    /^  lane-b-ratchet-controls:[[:space:]]*$/ { injob = 1; next }
    injob && /^  [^[:space:]#]/ { injob = 0 }
    injob && $1 == "timeout-minutes:" { print $2; exit }
  ' "$lane_b_ciyml")"
  lane_b_need=$((EXPECTED_CHECKS * SLOW_SECONDS_PER_CONTROL))
  if [ -z "$lane_b_budget" ]; then
    echo "FAIL [the job's time budget covers its controls]: no timeout-minutes" >&2
    echo "  found for job 'lane-b-ratchet-controls' in $lane_b_ciyml -- either" >&2
    echo "  the job was renamed or the field was dropped, and an absent budget" >&2
    echo "  is GitHub's six-hour default, not a bound." >&2
    failures=$((failures + 1))
  elif [ "$((lane_b_budget * 60))" -lt "$lane_b_need" ]; then
    echo "FAIL [the job's time budget covers its controls]: the workflow gives" >&2
    echo "  this job ${lane_b_budget}m ($((lane_b_budget * 60))s) for" >&2
    echo "  $EXPECTED_CHECKS control(s) at ${SLOW_SECONDS_PER_CONTROL}s each," >&2
    echo "  which needs ${lane_b_need}s ($(((lane_b_need + 59) / 60))m). Raise" >&2
    echo "  timeout-minutes to at least $(((lane_b_need + 59) / 60)), or remove" >&2
    echo "  controls -- do not lower the constant to fit." >&2
    failures=$((failures + 1))
  fi
fi

# ⚠ AND THE POLICY SENTENCE ITSELF IS A NUMBER-IN-PROSE. The review that
# opened this work found the gate announcing "REPORTED, NOT GATED" while the
# ratchet gated on change, and named two sites: the scope declaration and the
# runtime summary. Fixing exactly those two left the same stale sentence at two
# more -- the printable-signature exemption and the character-reference refusal
# -- because both justify EXEMPTING lane B from a refusal, and a refusal ends
# the run before the lane split, so the exemption's reasoning is a policy claim.
# A finding names instances; the class is the finding's real size.
#
# The word "gated" carries two meanings here that a reader cannot separate
# without context: gated AT ZERO, which lane B is not, and gated ON CHANGE,
# which it is. So the invariant is that the word never appears about lane B
# unqualified. That is enforceable, not advisory: measured before choosing it,
# this file had exactly ONE violation, and the sibling's merged main has exactly
# one, at the same place -- so the rule can be met today rather than aspired to.
#
# Known limit, stated rather than papered over: this reads lines that NAME the
# lane. The printable-signature site says "source is REPORTED AT ZERO rather
# than gated there" and never writes "lane B", so it is outside this control's
# reach and was found by reading. A sentence can still go stale by not naming
# its subject.
checks=$((checks + 1))
if [ ! -f "$GATE" ]; then
  echo "FAIL [lane B's policy is never stated unqualified]: $GATE is missing," >&2
  echo "  so the wording cannot be checked and this control would otherwise" >&2
  echo "  have passed without reading anything." >&2
  failures=$((failures + 1))
else
  set +e
  lane_b_unqual="$(awk '
    { l = tolower($0) }
    l ~ /lane[ -]?b/ && l ~ /gated/ && l !~ /at zero/ && l !~ /on change/ {
      printf "%d: %s\n", NR, $0
    }
  ' "$GATE")"
  lane_b_awk_st=$?
  set -e
  if [ "$lane_b_awk_st" -ne 0 ]; then
    echo "FAIL [lane B's policy is never stated unqualified]: awk exited" >&2
    echo "  $lane_b_awk_st reading $GATE, so nothing was checked. An empty" >&2
    echo "  result from a broken reader is not a clean result." >&2
    failures=$((failures + 1))
  elif [ -n "$lane_b_unqual" ]; then
    echo "FAIL [lane B's policy is never stated unqualified]: these line(s) say" >&2
    echo "  'gated' about lane B without saying which gating is meant:" >&2
    printf '%s\n' "$lane_b_unqual" | sed 's/^/    /' >&2
    echo "  Write 'gated at zero' or 'gated on change'. Lane B is the second." >&2
    failures=$((failures + 1))
  fi
fi

# ⚠ EXACTLY, NOT AT LEAST, AND THE NUMBER LIVES ONLY ON THE NEXT LINE. A floor
# accepts a stale count: add a control without touching it and the expected
# number silently drifts, after which that control can be deleted and the stale
# number still passes -- the silently-lost-check failure this harness exists to
# detect, reproduced inside the detector. Equality forces the number to move when
# a control is added, so a later removal cannot hide behind it.
#
# The number appears exactly ONCE, in EXPECTED_CHECKS, and the message READS it
# instead of repeating it. The revision before this one spelled "expected
# exactly 14" as a second literal directly beneath this paragraph -- the drift
# this paragraph forbids, one line from where it forbids it, and passing every
# healthy run because a stale expectation only shows up once some other count
# disagrees.
if [ "$checks" -ne "$EXPECTED_CHECKS" ]; then
  echo "REFUSING: $checks control(s) ran, expected exactly $EXPECTED_CHECKS" >&2
  exit 2
fi
if [ "$failures" -ne 0 ]; then
  # ⚠ "ACROSS", NOT "OF". A control may assert two things -- the planted-probe
  # pair asserts a refusal AND that the outside file survived it -- so $failures
  # can exceed the number of failing controls. "4 of 40 control(s) FAILED" reads
  # as four broken controls when it was three. A count that overstates its own
  # subject is the same defect this harness exists to find, in its last line.
  echo "lane B ratchet: $failures failure(s) across $checks control(s)" >&2
  exit 1
fi
echo "lane B ratchet: $checks control(s), 0 failure(s) — against ${lane_b_tested}"
