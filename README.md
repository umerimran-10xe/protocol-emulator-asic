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
| `test/protoemu_model.py` | cycle-accurate chip-level reference model the RTL is checked against |
| `docs/isa.md` | instruction set reference |
| `docs/architecture.md` | design decisions and the measurements behind them |
| `docs/local-hardening.md` | running the full RTL-to-GDS flow on this machine |
| `docs/info.md` | datasheet source |
| `scripts/lint.sh` | the same Verilator lint CI runs, in milliseconds |
| `scripts/area.sh` | fast local area check against the 6x4 budget |
| `scripts/timing.sh` | pre-layout critical path, in seconds |
| `docs/timing.md` | where the clock period goes, measured |
| `docs/scaling.md` | how many state machines fit, and how deep a store |
| `formal/` | SymbiYosys proof configurations and the non-interference miter |
| `scripts/formal.sh` | SymbiYosys proofs: per-machine safety, pin arbitration, non-interference, rendezvous |
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
./scripts/harden.sh -f         # RTL to GDS; minutes when near-empty, much longer with real logic
```

Each rung catches what the one below it cannot, and CI stays authoritative.
`docs/local-hardening.md` covers the rootless Nix setup the last step needs.

## Status

**Four state machines**, sharing a 64 x 16 program store, an eight-pin block and
one timestamped edge-capture record. Each machine has its own start address, its
own pins by ownership, its own cursor into the capture record, and can meet the
others at a barrier.

| | |
|---|---|
| Cell area | 278,865 um2, **30.4%** of the 6x4 die (synthesis) |
| Tests | 27 cocotb tests passing, including decoded UART, I2C and two-machine full-duplex SPI |
| Timing | pre-layout slack **+5.03 ns, met** |
| Random | randomised programs checked cycle-for-cycle against a chip-level Python model |
| Formal | 5 tasks: per-machine safety and edge capture by k-induction, plus exhaustive pin arbitration, cross-machine non-interference and rendezvous at four machines — all mutation-checked |
| Lint | clean, zero warnings |

Next: more protocols across machines, and the stretch goals — low-speed USB and
10Mbit Ethernet. `docs/scaling.md` has how the machine count and store depth
were settled.

## License

Apache-2.0 — see [LICENSE](LICENSE).
