# Hardening results

Post-layout numbers for the protocol engine, from the `gds` workflow. These
supersede the earlier baseline, which hardened the Tiny Tapeout example and so
said nothing about this design.

Run: `gds` on the merge of PR #3. Jobs: **gds ✅ precheck ✅**.
Design metrics come from `tt_submission/stats/metrics.csv`.

## Numbers

| Metric | Value | Note |
|---|---|---|
| `design__die__area` | 916,214 um² | 6x4 tiles, 1289.28 x 710.64 |
| `design__core__area` | 902,417 um² | usable after margins |
| `design__instance__utilization` | **33.67%** | placed area, not the synthesis estimate |
| `design__instance__count` | 75,046 | |
| `timing__setup__ws` | **+1.6256 ns** | on a 20 ns period |
| `timing__hold__ws` | **+0.1261 ns** | |
| `timing__setup__tns` | 0.0 | no other path violates |
| `timing__hold__tns` | 0.0 | |
| `route__wirelength__estimated` | 717,761 um | 568x the empty template |
| `route__drc_errors` | 0 | |
| `magic__drc_error__count` | 0 | |
| `design__lvs_error__count` | 0 | |
| `route__antenna_violation__count` | 0 | |
| `design__max_slew_violation__count` | 6 | see below |
| `design__max_cap_violation__count` | 0 | |
| `design__max_fanout_violation__count` | 160 | see below |
| `power__total` | 9.47 mW | |

Clean DRC, LVS and antenna, and no timing violations. The design is
submittable as it stands.

## Two things these numbers change

**1. The clock has far less headroom than the empty die suggested.**

| | Setup slack | Implied longest path |
|---|---|---|
| Tiny Tapeout example | +9.91 ns | ~10.1 ns |
| This design | **+1.63 ns** | **~18.4 ns** |

Real logic consumed almost all the margin. 50 MHz closes comfortably, but the
ceiling is only about **54 MHz** as the design stands — there is no factor-of-two
left. That settles the clock-rate question, and not in favour of the stretch
goals: low-speed USB and 10Mbit Ethernet need oversampling headroom that a
54 MHz ceiling does not provide. Reaching them means pipelining the critical
path, not asking for a faster clock. Worth finding that out now rather than
after three more increments.

Hold slack is +0.13 ns. Positive, but thin enough that it is worth watching
rather than assuming.

**2. Post-layout area runs ~40% above the synthesis estimate.**

Synthesis reported 219,763 um² of cell area, 24.0% of the die. Placement
reports **33.67%**. The difference is clock-tree buffers, hold-fixing buffers
and upsizing — real cells that `scripts/area.sh` cannot see because it stops at
synthesis.

That ratio matters for the scale-up plan in `docs/architecture.md`, which was
written against synthesis numbers:

| Configuration | Synthesis estimate | Expected post-layout |
|---|---|---|
| 1 state machine (built) | 24.0% | 33.7% (measured) |
| 2 state machines | ~29% | ~41% |
| 4 state machines | ~40% | **~56%** |

Four machines was described as comfortable against LibreLane's 60% density
target. Applying the measured ratio, four lands at ~56% — not comfortable,
marginal. **Two is the safe next step**, and four needs a real hardening run to
decide rather than an extrapolation. Treat `area.sh` as an early-warning signal
from now on, not as a budget.

## Quality items to clean up

Neither blocks the flow, but both are worth fixing before the design grows:

- **160 max-fanout violations.** Almost certainly the control and reset nets
  fanning out across the 128 x 16 program store without enough buffering.
- **6 max-slew violations.** Likely the same nets.

These are the kind of thing that turns into a hold-time problem later, and hold
slack is already only +0.13 ns.

## Runtime

The `gds` job took **1h55m**, against ~22 minutes for the empty template, and
the full workflow 3h08m. Detailed routing dominates. Budget for this growing as
the design does, and see `docs/local-hardening.md` for why the local flow is
slower still rather than faster.
