# Protocol Emulator ASIC

A reprogrammable, general-purpose **protocol emulator** for the
[Jane Street protocol emulator ASIC competition](https://blog.janestreet.com/protocol-emulator-asic-competition/).

Rather than putting fixed UART, SPI and I2C blocks on the die, this chip runs
firmware on a small engine whose instruction set is built for pin timing —
reading pins, driving pins, waiting on edges, and counting cycles exactly. New
protocols can be added after fabrication.

## Target

| | |
|---|---|
| Process | IHP CMOS5L 130nm (`ihp-sg13cmos5l`) |
| Shuttle | Tiny Tapeout, targeting the March 2027 CMOS5L shuttle |
| Area | 6x4 tiles = 1289.28 x 710.64 um |
| Clock | 50 MHz (`CLOCK_PERIOD` 20ns) |
| Template | [`ttihp-verilog-template`](https://github.com/TinyTapeout/ttihp-verilog-template) `cmos5l` branch |
| Deadline | 2027-01-18 |

Protocols: **UART, SPI, I2C** first; JTAG, SWD and PS/2 reachable from the same
ISA; low-speed USB and 10Mbit Ethernet as stretch goals.

## Repository layout

| Path | What |
|---|---|
| `src/` | RTL and the LibreLane config |
| `src/protoemu_isa.vh` | the instruction encoding, shared by RTL and assembler |
| `test/` | cocotb testbenches (run against RTL and the post-layout netlist) |
| `test/protoemu_asm.py` | assembler, so test programs are mnemonics not hex |
| `docs/isa.md` | instruction set reference |
| `docs/architecture.md` | design decisions and the measurements behind them |
| `docs/local-hardening.md` | running the full RTL-to-GDS flow on this machine |
| `docs/info.md` | datasheet source |
| `scripts/lint.sh` | the same Verilator lint CI runs, in milliseconds |
| `scripts/area.sh` | fast local area check against the 6x4 budget |
| `scripts/formal.sh` | SymbiYosys proofs of the state machine's safety properties |
| `scripts/harden.sh` | local RTL-to-GDS with a progress bar |
| `info.yaml` | Tiny Tapeout project definition: tiles, pinout, top module |

## Building

The full RTL-to-GDS flow runs in GitHub Actions via LibreLane — no local ASIC
tooling required. Push, and the `gds` workflow hardens the design, runs the
Tiny Tapeout precheck, re-runs the tests against the gate-level netlist, and
publishes a GDS viewer plus the `tt_submission` artifact.

For the fast local loop:

```sh
source ~/eda/activate-eda.sh   # yosys, iverilog, verilator, sby, cocotb
./scripts/lint.sh              # ~12 ms
cd test && make                # RTL simulation, ~3 s
./scripts/formal.sh            # SymbiYosys safety proofs, ~1 s
./scripts/area.sh              # cell count vs. the 6x4 budget, seconds
./scripts/harden.sh -f         # RTL to GDS, ~6 min (full run ~59 min)
```

Each rung catches what the one below it cannot, and CI stays authoritative.
`docs/local-hardening.md` covers the rootless Nix setup the last step needs.

## Status

First working increment: one state machine executing the full instruction set,
a 128 x 16 program store, and an SPI configuration port. 14 cocotb tests pass
against RTL, and the design hardens cleanly.

| | |
|---|---|
| Cell area | 219,763 um2, **24.0%** of the 6x4 die |
| Tests | 16 cocotb tests passing, including a decoded UART frame |
| Formal | 6 safety properties proved by k-induction |
| Lint | clean, zero warnings |

Next: timestamped edge capture, then scaling from one state machine to four.
`docs/architecture.md` has the measured area case for both.

## License

Apache-2.0 — see [LICENSE](LICENSE).
