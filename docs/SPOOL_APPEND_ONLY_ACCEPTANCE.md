# Spool Append Acceptance — Defold SDK

What was changed, what it was measured at, and what it deliberately does not
change. The bound this is measured against was fixed first, in its own commit,
and is in `SPOOL_OVERFLOW_LATENCY_BOUND.md`.

## Re-measured

Same harness, same caps, same machine — `test/bench_spool_append.lua`, 2000
appends of one envelope, default 500-entry / 256 KiB caps.

| | before | after | bound |
|---|---|---|---|
| envelopes re-measured per appended envelope | 437.6 | **1.0** | ≤ 1.0 |
| SDK-side p95 full ÷ p95 empty | 5.1x | **1.3–2.0x** | ≤ 2.0x |
| SDK-side p50 per append | 9.66 ms | **0.034 ms** | — |
| SDK-side p99 per append | 11.19 ms | **0.094 ms** | — |
| total for 2000 appends | 18309 ms | **73.3 ms** | — |
| entries handed to `sys.save` per append | 437.6 | **437.6** | not bounded |

Two honest notes about that table, both of which cut against the result.

**The ratio row is at the harness's resolution.** Three runs gave 1.4x, 1.3x
and 2.0x — the last one sitting exactly on the bound. That is not the fix being
marginal; it is what happens when the quantity being divided has shrunk to
0.04 ms and the divisor is estimated from 100 samples. The metric was not
changed after seeing this, because a metric changed to make a run pass is the
same mistake as a threshold chosen to be met. It is reported as measured, and
the **count** row is the one that carries the weight: exact, identical on every
run, and immune to the machine.

**The last row did not move, by design.** `sys.save` takes a whole table and
rewrites the whole file; Defold has no append and no partial write. That cost
is engine-side and is stated as owed in the bound document, along with the
measurement that would settle whether it matters and the segmented-chunk design
that would be the remedy if it does.

## What the change is

Appending used to copy the whole record, hand it to `save_spool`, which
re-sanitised it, called `approx_envelope_bytes` on **every** entry —
`json.encode` per envelope on real Defold — summed, evicted, and wrote; then
the client rebuilt its id index over the whole result. Four passes over the
entire backlog to append one envelope.

Now a spool **state** carries each entry's estimate and their running total, so
the **measuring** is O(added) — nothing is estimated twice. `spool_admit` is the single implementation of
the caps and both paths use it: the whole-record `save_spool` is expressed as
admission into an empty state.

**The append path is deliberately narrow.** It runs only in the clean steady
state — nothing settled awaiting a removal rewrite, nothing replaced in place,
no rewrite or condemnation owed. Every one of those is an invariant the
whole-record rewrite establishes in one place, and re-establishing them on a
second mutation path is how a fast path turns into a source of quiet
disagreement between mirror and disk. Those cases fall through to the rewrite,
unchanged.

The capture-accounting tail — which envelopes this call actually persisted, and
therefore whether a shutdown may claim durability — was extracted so that both
paths run the same code rather than two copies of it.

## What the tests pin, and how that was checked

⚠ **The append path is a pure optimisation: delete it and every behavioural
test still passes**, because the rewrite it falls back to produces an identical
record. So the assertions are about **cost**, counted rather than timed, and
about the two places the incremental bookkeeping can drift from the record.

Every one was mutation-checked — the change reverted, the test watched to fail
*for that reason*:

| mutation | what turned red |
|---|---|
| fast path disabled | `50.0 estimates per append at a 50-entry cap (bound 1.0)` |
| index erases before it adds | an envelope evicted on arrival stays marked present — plus three existing durability assertions |
| count-cap skip stops reporting its evictions | `spool_evicted` 0 where 1 is owed (an existing FIFO fixture caught this one first) |
| the state's identity check removed | admission decided against a record that had been replaced |

That third row is worth keeping. Skipping the estimate for entries the count
cap will certainly evict is a cost decision and a correct one; **not reporting
them is a lie about what was persisted**, and the first version of the
optimisation made exactly that trade without noticing. The repository's own
FIFO fixture caught it. Not estimating an entry and not accounting for it are
different things that looked like one thing.

⚠ **Admission is not O(1) overall, and the first version of this document
said so.** `table.remove(t, 1)` shifts every surviving element, so an eviction
costs O(backlog) pointer moves across two arrays. That term is left in place on
purpose: the write it accompanies hands the whole table to `sys.save`, which
serialises every surviving envelope on the same call. A head-offset
representation would still have to materialise a contiguous array for that
write — two pointer shifts traded for one copy, inside a serialisation that
does not change. The cost worth removing was the re-measuring, and that is the
row that moved.

## Not changed

- The record format. This is still one `sys.save` table, read by the same
  loader, and a spool written by the previous version loads unchanged.
- The eviction rule, the caps, the byte estimator, and the deadline record.
- Every path that is not the clean steady-state append.
