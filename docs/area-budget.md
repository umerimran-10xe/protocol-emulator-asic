# Area budget (IHP CMOS5L, 6x4 tiles)

Measured from `sg13cmos5l_stdcell_typ_1p20V_25C.lib`, not estimated.
Regenerate the design's own number with `./scripts/area.sh`.

## The die

| | |
|---|---|
| 6x4 tile die | 1289.28 x 710.64 um = **916,214 um²** |
| at 45% density | 412,296 um² = ~56,800 NAND2-equivalents |
| at 60% density (LibreLane's `PL_TARGET_DENSITY_PCT`) | 549,728 um² = ~75,700 NAND2-equivalents |

## Reference cell costs

| Cell | Area (um²) | In NAND2s |
|---|---|---|
| `inv_1` | 5.44 | 0.75 |
| `nand2_1` | 7.26 | 1.00 |
| `dfrbpq_1` (smallest flop) | 48.99 | 6.75 |
| `sdfbbp_1` (scan flop) | 63.50 | 8.75 |

The library has 84 cells total.

## What this means for instruction memory

| Flop-based storage | Area | % of 6x4 die |
|---|---|---|
| 256 bits | 12,541 um² | 1.4% |
| 512 bits | 25,082 um² | 2.7% |
| 1024 bits | 50,165 um² | 5.5% |
| 2048 bits | 100,329 um² | 11.0% |

**This changes the SRAM decision.** The competition post advises budgeting SRAM
for instruction memory because it is more area-efficient than flip-flops. That
is true per bit, but the absolute numbers here are forgiving: 2048 bits of
flops — say 128 instructions x 16 bits — costs 11% of the die, or about 18% of
the usable cell area at 60% density.

So a flop-based instruction memory is viable for a first working design, and
avoids the macro-placement, routing-halo and timing complications an SRAM macro
brings on a 6x4 tile. SRAM stays on the table if the ISA needs a deeper program
store, but it is not a prerequisite.

Caveat: cell area is not the binding constraint — **routing congestion usually
is**. These figures are a floor, and the authoritative number is the routing
summary and cell usage report the `gds` workflow posts to its job summary.
