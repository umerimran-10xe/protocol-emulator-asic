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
  interleaving a single instruction stream by hand. This build has one machine;
  the store and pin block are already shared, which is what lets more be added.

Instruction memory is 128 x 16 bits, loaded over a simple SPI configuration port
after reset, which is what makes the design reprogrammable in silicon.

Three things set it apart from a conventional bit-bang engine:

- **Waits cannot hang the chip.** `WAITP` carries a timeout; when it expires the
  machine raises a fault flag and a `JMP` on that flag runs a recovery routine,
  so a missing clock or a stuck bus is a program-visible event.
- **Open-drain is native, per pin.** A pin in open-drain mode drives low and
  releases high, in hardware, so I2C is an ordinary program rather than a
  special case threaded through every instruction.
- **Timing is by deadline, not by delay.** `WAITU` waits until the shared cycle
  counter reaches an absolute target. Adding instructions before it does not
  move when it fires, so jitter cannot accumulate across a long frame.
- **It can measure, not just replay.** Arming edge capture records the pin
  state and the exact cycle of every change into a 16-entry FIFO. A program can
  read those timestamps back and work out a pulse width or a bit period it was
  never told — which is what it takes to talk to a device whose timing you do
  not know in advance.

Target protocols: **UART, SPI and I2C** first, with JTAG, SWD and PS/2 reachable
from the same instruction set. Low-speed USB and 10Mbit Ethernet are stretch
goals bounded by the achievable clock rate.

This design targets the IHP CMOS5L 130nm process at 6x4 tiles
(1289.28 x 710.64 um) with a 50 MHz clock.

> **Status:** one state machine, the full instruction set, the configuration
> port and timestamped edge capture. Additional state machines are next. See
> `docs/architecture.md` for the measured area position.

## How to test

1. Hold `rst_n` low to reset, then load a program into instruction memory over
   the configuration port (`cfg_sclk` / `cfg_mosi` / `cfg_cs_n`, reading back on
   `cfg_miso`).
2. Raise `run` to start execution.
3. Attach the protocol pins `pio[7:0]` to the device under test.

`run` doubles as the restart control: a 0 to 1 transition returns each machine
to its configured start address and clears the cycle counter, so every run
starts identically.
While `run` is low the machine is frozen, and each pulse on `step` advances it
one cycle -- enough to single-step a program on the bench.

The configuration frame is a 16-bit header — bit 15 set to read, bit 14 to
reach the control registers rather than the program store, and bits 7:0 the
start address — followed by 16-bit words with the address auto-incrementing, so
a whole program loads in one chip-select. Control register *n* holds the
address machine *n* starts from. Control registers 8 and 9 read back the two
program errors the hardware can see -- a pin more than one machine claimed, and
a machine that tried to arm edge capture without owning it -- and clear the bits
written to them.

For a UART loopback smoke test, load the UART program, tie `pio[0]` (TX) to
`pio[1]` (RX), and check that transmitted bytes come back.

The cocotb testbench in `test/` drives the same sequence in simulation and runs
against both RTL and the post-layout gate-level netlist. Programs are written
with the assembler in `test/protoemu_asm.py`; `docs/isa.md` is the instruction
reference.

## External hardware

None required. A logic analyser or a second microcontroller on the `pio[7:0]`
pins is useful for observing the emulated protocol, and the Tiny Tapeout demo
board's PMOD header exposes the bidirectional pins directly.
