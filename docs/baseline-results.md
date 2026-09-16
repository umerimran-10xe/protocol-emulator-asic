# Baseline hardening results

First successful run of the full RTL-to-GDS flow on the 6x4 CMOS5L tile,
2026-09-16. The RTL was still the Tiny Tapeout example, so these numbers say
nothing about the emulator design — the point was to prove the flow, the tile
size and the submission path all work before committing real RTL.

Run: `gds` on `main` @ `54ab519`. Jobs: **gds ✅ precheck ✅ gl_test ✅**
(`viewer` failed — GitHub Pages deployment, unrelated to the design).

## Numbers

| Metric | Value | Note |
|---|---|---|
| `design__die__area` | 916,214 um² | matches 1289.28 x 710.64 exactly |
| `design__core__area` | 902,417 um² | usable after margins |
| `design__instance__utilization` | 0.07% | stock example, essentially empty |
| `route__wirelength__estimated` | 1,264 um | |
| `timing__setup__ws` | **+9.91 ns** | worst setup slack on a 20 ns clock |
| `timing__hold__ws` | **+7.87 ns** | worst hold slack |
| `route__drc_errors` | 0 | converged 2 -> 1 -> 1 -> 0 across iterations |
| `magic__drc_error__count` | 0 | |
| `design__lvs_error__count` | 0 | |
| `route__antenna_violation__count` | 0 | |
| `design__max_slew_violation__count` | 0 | |
| `design__max_cap_violation__count` | 0 | |

## What this establishes

- **6x4 is real and routable.** The die area LibreLane reports matches the
  tile table exactly, so `tt_block_6x4_pgvdd.def` works as expected.
- **Clean DRC and LVS**, so the submission path is sound.
- **Enormous timing headroom.** +9.91 ns setup slack on a 20 ns period means
  the stock design uses about half the clock period. That headroom is what the
  emulator core gets to spend, and it leaves room to consider a faster clock
  for the USB and Ethernet stretch goals.
- **Runtime: ~22 minutes.** This is why hardening is now behind a paths filter
  and why local hardening is worth setting up.

Regenerate by pushing a change under `src/**` or `info.yaml`, or via
`workflow_dispatch` on the `gds` workflow.
