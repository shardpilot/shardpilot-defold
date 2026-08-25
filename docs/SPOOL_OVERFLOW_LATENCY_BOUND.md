# Spool Overflow Latency Bound — Defold SDK

**Fixed 2026-08-25, before any of the append-path implementation was written.**

A6 requires this in those words, and the reason is a trap rather than a
formality: the cheapest way to pass a latency requirement is to move the work
somewhere the harness is not looking. **A threshold chosen after seeing the
fixed run is chosen to be met.** So the numbers below are the baseline as it
stands today, and the bound derived from it, both recorded before the fix
exists.

This SDK's bound is stated differently from Godot's and Go's, and the reason is
the platform. Those two write a text file and can genuinely append to it. Defold
has one sanctioned durable primitive — `sys.save(path, table)` — which takes a
whole table and rewrites the whole file. **There is no append.** What follows
therefore separates the cost this SDK imposes on itself, which is bounded here,
from the cost the platform imposes, which is not, and says which is which
rather than blurring them.

## Baseline — the defect, measured

`client.lua::spool_envelopes` copies the whole `spool_record`, concatenates the
fresh envelopes, and hands the result to `write_spool_record` →
`storage.save_spool`. That function re-runs `sanitize_spool_events` over the
whole list, calls `approx_envelope_bytes` on **every** entry — which is
`json.encode` on real Defold — sums them, evicts, and writes. Then
`write_spool_record` rebuilds the client's `spool_index` over the whole saved
record. Four passes over the entire backlog to append one envelope.

2000 successive spool appends, one envelope each, growing into the default
500-entry / 256 KiB caps. Harness: `test/bench_spool_append.lua`, the real
`Client:spool_envelopes`, Lua 5.4 on x86-64 Linux.

```
append #    1:    0.049 ms   record     1 entries
append #  100:    2.253 ms   record   100 entries
append #  250:    5.430 ms   record   250 entries
append #  500:   10.479 ms   record   500 entries   <- the event cap
append # 1000:   10.679 ms   record   500 entries
append # 1500:   10.055 ms   record   500 entries
append # 2000:    9.886 ms   record   500 entries

n=2000  min 0.049  p50 9.659  p95 10.310  p99 11.187  max 12.710 ms
mean 9.155 ms   total 18309.0 ms across 2000 spooling appends
p95 empty(first 100) 1.998 ms   p95 full(last 100) 10.259 ms   ratio 5.1x
sys.save calls 2002   entries handed to sys.save 875250 (437.6 per append)
json.encode calls 875250 (437.6 per append) -- every entry re-encoded, every time
```

Three runs: ratio 5.1x, 5.1x, 6.2x; p50 9.66–9.87 ms. The two counts are
identical to the entry on every run, because they are structural rather than
timed.

⚠ **`sys.save` IN THIS HARNESS IS FREE.** It stores a reference and returns —
it does not serialize. So every millisecond above is the SDK's **own** work in
Lua, and the engine's durable write is on top of it, unmeasured. The figure
that matters is not the wall clock; it is **437.6**.

**437.6 envelopes re-encoded to append one.** That is the defect in a single
number, and it is implementation-independent: it does not move with the
machine, the interpreter, or how fast Defold's C-side JSON encoder is. To
append the 501st envelope this SDK encodes 500 it already encoded, then throws
the result away, then does it again for the 502nd.

**The cost grows with the backlog — 200x from one entry to the cap**, 0.049 ms
to 10.479 ms, flattening only because the cap stops the backlog growing. That
is the shape the number above predicts.

**The absolute milliseconds are NOT an end-to-end frame cost** and are not
bounded below. The harness's JSON encoder is written in Lua; Defold's is C and
much faster, so the real per-append figure is smaller — and the real durable
write, excluded here, makes it larger. Reporting ~10 ms as a frame budget claim
would be dressing an unmeasured quantity as a measured one. What is honestly
measured is the *shape*, and the shape is the requirement.

## The bound

### 1. Envelopes re-measured per appended envelope ≤ 1.0 (structural)

Today it is **437.6**. This is the load-bearing part, and it is a count rather
than a duration precisely so that no machine, interpreter or encoder can be
bought to satisfy it. An append must pay for what it appends.

### 2. SDK-side ratio, store excluded: p95 full ÷ p95 empty ≤ 2.0x

Today it is **5.1x** (5.0x with the fallback estimator, so this is not an
artifact of the harness's encoder). 2.0x leaves room for work amortised across
appends and nothing else. Measured on `test/bench_spool_append.lua`, whose
`sys.save` is free — this bounds the half of the cost that is this SDK's.

### 3. NOT bounded here: the durable write itself

**Entries handed to `sys.save` per append stays at the backlog size, and this
change does not reduce it.** `sys.save` takes a whole table; the platform
offers no append and no partial write, so the write is O(backlog) by
construction. Its cost is engine-side C that no harness in this repository can
measure — `scripts/ci_bob_build.sh` builds with `bob.jar` but never starts the
engine, and it says so.

Stating a bound on a quantity I cannot measure would be worse than stating
none. So this is recorded as **owed, with the measurement that would settle
it**: run the spool under a real `dmengine` and time `sys.save` for a
500-envelope record. If that is small, this is finished. If it is not, the
remedy is a **segmented spool** — chunk files of a fixed K entries, appending
into the tail chunk only, evicting whole chunks from the front — which is how
"the append is an append" expresses itself on a platform whose only primitive
is whole-file write.

That design is deliberately **not** being built first. It introduces a
multi-file store with no atomic multi-file commit, and every invariant the
single-file rewrite currently establishes in one place would have to be
re-established across chunk boundaries and audited. Building it against a cost
nobody has measured is the same mistake as choosing a threshold after seeing
the run — it just points the other way.
