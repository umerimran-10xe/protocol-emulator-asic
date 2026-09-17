# Timing

Where the clock period goes, measured rather than assumed. Numbers are from the
`gds` run on the merge of PR #3; reproduce the pre-layout view with
`./scripts/timing.sh`.

## Slack by corner

Signoff is the **slow** corner. The others are context, not headroom you can
spend.

| Corner | Setup slack | Implied longest path |
|---|---|---|
| `nom_fast_1p32V_m40C` | +12.49 ns | ~7.5 ns |
| `nom_typ_1p20V_25C` | +8.45 ns | ~11.5 ns |
| **`nom_slow_1p08V_125C`** | **+1.63 ns** | **~18.4 ns** |

At 50 MHz the design closes with 1.63 ns to spare in the worst corner, about 8%
of the period. The **guaranteed** ceiling is therefore around **54 MHz**, even
though a typical part would run near 87 MHz. Signoff is the number that counts.

This is what rules out the stretch goals as free: low-speed USB and 10Mbit
Ethernet want oversampling headroom that a 54 MHz guarantee does not give.
Reaching them means shortening the path, not raising the clock.

Clock skew is 0.388 ns, itself a quarter of the remaining margin.

## What the critical path is made of

Post-layout, the worst path is **74 stages, and 42 of them are buffers** — 26
`buf_1` and 16 `buf_8`. The rest is about twenty gates of real logic.

Pre-layout, `./scripts/timing.sh` names the path:

```
u_sm/<pc flop> -> u_imem/<read mux> -> u_sm/<decode> -> u_sm/<next state flop>
```

Fetch, decode and execute in a single cycle, with the 128-entry program store's
read mux in the middle. That is the structure to attack if the period ever has
to come down: either pipeline the fetch, which costs the one-instruction-per-
cycle contract that makes program timing readable, or shrink the read mux by
giving each machine a smaller window into the store.

Neither is needed yet. Both are cheaper to decide with `scripts/timing.sh` in
the loop than with a three-hour hardening run.

## The 160 max-fanout violations are the clock tree

This one is worth stating plainly, because the obvious guess is wrong. The
violations are **not** control or reset nets fanning out across the program
store. Classified by name:

| Count | Kind |
|---|---|
| **150** | `clkbuf_leaf_*_clk` — clock-tree leaf buffers |
| 10 | `fanout*` — signal repair buffers |

CTS built leaf buffers driving 17 to 19 flops each against a `MAX_FANOUT_CONSTRAINT`
of 8. That is a clock-tree clustering setting, not something the RTL controls.
Max **capacitance** violations, which is the electrically real constraint, are
**zero**, and the six max-slew violations sit on the same nets.

So these do not threaten function. What they do cost is the 0.388 ns of clock
skew, and the clock buffers that show up among the 42 on the critical path.
Tightening CTS clustering is worth perhaps a couple of hundred picoseconds —
worth having if margin ever gets tight, not worth doing now.

## Method note

`scripts/timing.sh` is pre-layout: no placement, no wire load model, no
resizing, and hierarchy deliberately kept so paths can be named — which also
blocks the cross-module optimisation the real flow performs. It reports about
-14 ns for a design that signs off at +1.63 ns.

Use it to answer "which module is the path in" and "did my change make it
worse". Use the `gds` workflow for a number to quote.
