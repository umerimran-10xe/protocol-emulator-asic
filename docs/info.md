<!---
This file is used to generate your project datasheet.
-->

## How it works

A general-purpose **protocol emulator**: a small, reprogrammable engine whose
instruction set is built around pin timing rather than arithmetic. Instead of
hard-wiring a UART block, an SPI block and an I2C block onto the die, the chip
executes firmware that toggles and samples pins with cycle-exact timing, so new
protocols can be added after fabrication.

The core is organised around three ideas:

- **Cycle-deterministic execution.** Every instruction retires in a known number
  of cycles, so a program's timing can be computed statically rather than
  measured. This is what makes bit-banging a real protocol feasible.
- **Pin-oriented ISA.** Instructions read pins, write pins, wait on pin edges or
  levels, shift bits in and out of a data register, and delay for a programmed
  number of cycles.
- **Independent state machines.** Multiple program counters share one pin block,
  so full-duplex protocols (SPI, or simultaneous UART TX and RX) run without
  interleaving a single instruction stream by hand.

Instruction memory is loaded over a simple configuration port after reset, which
is what makes the design reprogrammable in silicon.

Target protocols: **UART, SPI and I2C** first, with JTAG, SWD and PS/2 reachable
from the same instruction set. Low-speed USB and 10Mbit Ethernet are stretch
goals bounded by the achievable clock rate.

This design targets the IHP CMOS5L 130nm process at 6x4 tiles
(1289.28 x 710.64 um) with a 50 MHz clock.

> **Status:** architecture and toolchain are in place; the RTL currently in
> `src/project.v` is still the Tiny Tapeout example and is being replaced.

## How to test

1. Hold `rst_n` low to reset, then load a program into instruction memory over
   the configuration port (`cfg_sclk` / `cfg_mosi` / `cfg_cs_n`, reading back on
   `cfg_miso`).
2. Raise `run` to start execution.
3. Attach the protocol pins `pio[7:0]` to the device under test.

For a UART loopback smoke test, load the UART program, tie `pio[0]` (TX) to
`pio[1]` (RX), and check that transmitted bytes come back.

The cocotb testbench in `test/` drives the same sequence in simulation and runs
against both RTL and the post-layout gate-level netlist.

## External hardware

None required. A logic analyser or a second microcontroller on the `pio[7:0]`
pins is useful for observing the emulated protocol, and the Tiny Tapeout demo
board's PMOD header exposes the bidirectional pins directly.
