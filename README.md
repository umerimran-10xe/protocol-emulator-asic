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
| `test/` | cocotb testbenches (run against RTL and the post-layout netlist) |
| `docs/info.md` | datasheet source |
| `scripts/area.sh` | fast local area check against the 6x4 budget |
| `info.yaml` | Tiny Tapeout project definition: tiles, pinout, top module |

## Building

The full RTL-to-GDS flow runs in GitHub Actions via LibreLane — no local ASIC
tooling required. Push, and the `gds` workflow hardens the design, runs the
Tiny Tapeout precheck, re-runs the tests against the gate-level netlist, and
publishes a GDS viewer plus the `tt_submission` artifact.

For the fast local loop:

```sh
source ~/eda/activate-eda.sh   # yosys, iverilog, verilator, sby, cocotb
cd test && make                # RTL simulation
./scripts/area.sh              # cell count vs. the 6x4 budget
```

## Status

Toolchain, CI and project configuration are in place and green. The RTL in
`src/project.v` is still the Tiny Tapeout example and is being replaced by the
emulator core.

## License

Apache-2.0 — see [LICENSE](LICENSE).
