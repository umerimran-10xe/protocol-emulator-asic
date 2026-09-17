# How many state machines, and how deep a program store?

Measured, not extrapolated. Five configurations were synthesised and analysed
with `scripts/area.sh` and `scripts/timing.sh`; none needed a hardening run.

## The numbers

Post-layout is estimated by applying the **1.40x** ratio measured in
`docs/baseline-results.md`, where 24.0% of synthesis area became 33.67% of
placed area once clock-tree and hold-fixing buffers landed.

| Configuration | Synthesis | Post-layout (est.) | Program store alone | Pre-layout slack |
|---|---|---|---|---|
| 1 machine, 128 entries *(built today)* | 28.1% | ~39.3% | 21.4% | -13.67 ns |
| 2 machines, 128 entries | 33.3% | ~46.6% | 24.4% | -12.59 ns |
| 2 machines, 64 entries | 21.0% | ~29.4% | 12.2% | — |
| 4 machines, 128 entries | 43.7% | **~61.2%** | 30.5% | -13.37 ns |
| **4 machines, 64 entries** | **28.3%** | **~39.6%** | 15.2% | **+3.58 ns** |

Pre-layout slack is from `scripts/timing.sh` and is badly pessimistic in
absolute terms — the design it reports at -13.67 ns signs off at +1.63 ns. Read
the column as a comparison between rows, which is what it is good for.

## What it says

**A second machine costs 5.2% of the die and nothing in timing.** The extra
read port sits in parallel with the existing one, not in series, so the
critical path does not lengthen — it moves to whichever machine synthesis
happens to lay out last, and the slack barely changes.

**Four machines with the current 128-entry store does not fit.** At ~61.2% it
is over LibreLane's 60% density target, and the store alone is 30.5% of the
die. This is the configuration `docs/architecture.md` originally called
comfortable, on synthesis numbers, before the 1.40x ratio was known.

**Four machines with a 64-entry store fits, and fixes the critical path.** At
~39.6% it costs the same silicon as the single machine built today, for four
times the concurrency. More striking is the timing: pre-layout slack goes from
-13.67 ns to **+3.58 ns**, a swing of over 17 ns.

That last result is not luck. `docs/timing.md` traced the critical path to
`PC -> program store read mux -> decode`, and the 160 fanout warnings to the
nets driving that store. Halving the store halves the mux depth *and* halves
the fanout on the PC bits feeding it, so the one change attacks the area
hog, the critical path and the fanout pressure at once.

## Re-measured against the real RTL

The table above came from variants built to be structurally representative. Now
that pin arbitration and per-machine capture cursors exist, the same three
configurations can be measured on the actual design:

| Configuration | Variant | Real RTL | Post-layout (est.) |
|---|---|---|---|
| 1 machine, 128 entries | 28.1% | 28.0% | ~39.2% |
| 4 machines, 128 entries | 43.7% | 45.6% | ~63.8% |
| **4 machines, 64 entries** | 28.3% | **30.3%** | **~42.4%** |

The variants were **2 points optimistic** at four machines, which is what the
arbiter, the four read cursors and the four fetch ports cost over a structural
stand-in. Every conclusion survives: four machines with a 128-entry store is
still over the 60% density target, and four machines with a 64-entry store still
fits with room to spare.

The timing result survives too, and improved. Pre-layout slack at four machines
and 64 entries is **+5.69 ns, met** — the variant measured +3.58 ns. Halving the
store still pays for the machines several times over.

## The decision

**Four machines, 64-entry shared store.** The trade is explicit: four machines
*or* a 128-instruction program, not both.

64 is not tight for this kind of engine. The RP2040's PIO, the closest
comparable, shares **32** instructions across its four state machines; this
would have twice that. A single complex protocol can still use the whole store,
because it is shared rather than partitioned.

What this gives up is the ability to hold four long protocol programs
resident at once. If that turns out to bind, the options in order of
preference are a deeper store with two machines, or paging the store over the
existing SPI port between phases.

## Still to design

The measurement variants were built to be structurally representative, not
correct. Before this becomes real RTL:

- ~~**Pin arbitration.**~~ **Done.** `src/protoemu_arb.v` gives each pin to the
  lowest-numbered machine that claims it, and only to that machine. Overlapping
  `PINMASK`s are reported to the host in control register 8 rather than
  silently resolved. The formal property has been extended the way this asked:
  `formal/protoemu_arb_miter.v` proves cross-machine non-interference at four
  machines, as a two-copy miter. `docs/architecture.md` has the properties.
- ~~**Capture ownership.**~~ **Done.** One record of the edges, one read cursor
  per machine, so every machine reads every edge at its own pace and no pop
  retires an entry out from under another. Arming stays machine 0's, because it
  resets the window for everyone; an arm from any other machine is dropped and
  reported in control register 9. The cost is that reading no longer makes room
  — the window holds the first 16 edges after each arm — which is what having
  several independent cursors buys.
- **Synchronisation between machines.** `SYS SYNC` currently re-anchors one
  machine's deadline. A barrier across machines is what full-duplex protocols
  will actually want.
- **The reference model** needs to become multi-machine alongside the RTL, or
  the randomised comparison stops covering the interesting part.

`PE_NSM` stays at 1 until those land. The machine array and the arbiter are
already in place and parameterised, so flipping it is a one-line change to
`src/protoemu_isa.vh` — but flipping it before capture and synchronisation are
designed would ship three machines that cannot measure or coordinate.

Pin arbitration cost **722 um2** and capture ownership a further **140 um2** at
one machine — 0.33% of the 6x4 die between them, 27.9% to 28.0% at synthesis,
with pre-layout slack unchanged. The cursors only really cost anything once
there are four of them, which is what the re-measured table above prices.
