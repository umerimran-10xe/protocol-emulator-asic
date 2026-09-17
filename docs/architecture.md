# Architecture proposal

> **Status: proposal, not yet implemented.** This is the design worth arguing
> about before RTL is written. See "Open questions" at the end.

## The competitive problem

Jane Street judges on *unique functionality* and *novel verification*, not
speed. Several public entries already exist and every one of them is a
straight RP2040-PIO clone. A fourth PIO clone does not win.

So the design question is not "how do we build a PIO" but "what does PIO get
wrong that matters for the use case Jane Street actually named" — hardware
debugging and reverse engineering.

## What PIO gets wrong

| Limitation | Why it hurts |
|---|---|
| `wait` has no timeout | A stuck SCL hangs the state machine forever. No recovery, no diagnosis. |
| 32 instructions, shared across 4 SMs | Real protocols with error handling do not fit. |
| No native open-drain | I2C needs `pindirs` tricks that burn instruction slots. |
| Relative delays only | Jitter accumulates across a frame; timing must be hand-balanced against instruction cost. |
| Emit-only mindset | It generates known protocols. It does not *measure* unknown ones. |

## Four differentiators

**1. `WAIT` with timeout and a fault vector.** Every wait carries an 8-bit
timeout. On expiry the state machine traps to a handler instead of hanging.
A stuck bus becomes a diagnosable event.

**2. Native per-pin open-drain.** A drive-mode register selects push-pull or
open-drain per pin, so I2C is a first-class citizen rather than a workaround.

**3. Deadline-based timing (`WAITU`).** Instead of "delay N cycles", wait until
an *absolute* cycle count. Each bit boundary is computed once from a running
target register, so per-instruction cost never accumulates into frame-level
jitter. This is what makes bit-banging robust rather than fragile.

**4. Timestamped edge capture.** The engine can record pin transitions with
cycle timestamps, so the chip can *measure* an unknown protocol, not just
replay a known one. This is the differentiator: it turns the part from a
protocol generator into a protocol analyser, which is precisely the
"hardware debugging and reverse engineering" use case the competition post
names.

## Instruction encoding (16-bit)

```
15 13 12                                    0
+-----+------------------------------------+
| op  |              operands              |
+-----+------------------------------------+
```

| op | Mnemonic | Encoding | Meaning |
|---|---|---|---|
| 000 | `SET` | `value[7:0], delay[4:0]` | Drive masked pins, then delay |
| 001 | `WAITP` | `mode, pol, pin[2:0], timeout[7:0]` | Wait for level/edge, trap on timeout |
| 010 | `WAITU` | `delta[12:0]` | `TGT += delta`; wait until `CYCLE == TGT` |
| 011 | `SHIFT` | `dir, pin[2:0], nbits[3:0], delay[4:0]` | Shift bits in/out of a pin |
| 100 | `JMP` | `cond[3:0], addr[8:0]` | Conditional branch, 512-instruction space |
| 101 | `ALU` | `op[3:0], ...` | X/Y scratch arithmetic |
| 110 | `LOAD` | `reg[2:0], imm[9:0]` | Load immediate (PINMASK, DRIVEMODE, TGT, X, Y) |
| 111 | `SYS` | `fn[3:0], arg[8:0]` | IRQ, halt, sync between state machines, capture control |

## State per state machine

- `PC` (9 bits), `X`, `Y` scratch (8 bits)
- `SHIFT` register (8 bits) + bit counter
- `TGT` deadline register, compared against a free-running `CYCLE` counter
- `PINMASK`, `DRIVEMODE` (push-pull / open-drain per pin)

Two state machines share one pin block, so full-duplex protocols (SPI, or
simultaneous UART TX and RX) do not need hand-interleaving.

## Area position

From `docs/area-budget.md`: the smallest flop is 48.99 um², and 2048 bits of
flop-based instruction memory costs 11% of the 6x4 die. A 128 x 16-bit program
store per state machine is therefore affordable **in flip-flops**, without the
macro-placement and routing-halo cost of an SRAM macro. SRAM remains an option
if the program store needs to be deeper.

## Verification

Half the judging criteria, so it was designed up front rather than bolted on.
Two of the four layers are running.

**Formal (SymbiYosys + Yices) — running.** `./scripts/formal.sh` proves the
following by k-induction, so they hold in every reachable state rather than
just the first few cycles. The properties live in an `ifdef FORMAL` block at
the bottom of `src/protoemu_sm.v`, next to the logic they constrain.

| Property | Why it matters |
|---|---|
| An open-drain pin never drives high | Driving high into an I2C bus is contention |
| A pin outside `PINMASK` is never driven | One machine cannot reach into another's pins |
| The state register only holds defined states | The unused encodings 6 and 7 are unreachable |
| A halted machine holds its pins and stays halted | Found a real bug: `ST_HALT` fell through to the shift datapath and kept driving |
| An armed `WAITP` always leaves the wait when its timeout expires | The timeout is the whole point; a wait that could hang is worse than no timeout |
| Nothing moves when neither running nor stepping | `run`/`step` really are a freeze control |

**Directed tests (cocotb) — running.** 18 tests in `test/test.py`, written
against the assembler rather than hex. They cover config load and readback, pin
drive and masking, open-drain, both `WAITU` behaviours, `WAITP` hit and timeout,
`SHIFT` in and out against a peripheral model that responds to the generated
clock, counted loops, run/step control, and a cross-check that the assembler
and the Verilog header agree on all 46 ISA constants.

**Constrained-random — running.** `test/protoemu_model.py` is a cycle-accurate
Python model of the state machine, written from the RTL and deliberately
mirroring its structure: one `step()` is one clock, every read takes the
pre-state, and the variables carry the register names, so a mismatch report
names the register that diverged.

`test_random_programs_match_the_model` runs randomised instruction streams
through the RTL and the model in lockstep and compares the pins every cycle.
The generator is weighted rather than uniform -- uniform 16-bit words are
mostly long waits and immediate halts, which exercises nothing -- and branches
are confined inside the program so control cannot reach an address the loader
never wrote.

    PROTOEMU_TRIALS=250 PROTOEMU_SEED=0x5EED make   # deeper soak

The default of 20 programs keeps the suite a few seconds; the soak is for
before a merge that touches the datapath.

**Protocol conformance — started.** Two protocols so far, both decoded by
models written from the protocol rather than from the program under test:

- a 1 Mbaud UART frame, recovered by a receiver that finds the start bit and
  samples at mid-bit;
- an I2C START and address byte on a bus modelled with pull-ups, where a line
  reads low only while the emulator actively drives it -- so the model would
  catch the emulator driving high, not just report the wrong byte.

SPI against a third-party model is next. These are the tests that matter most:
they show protocols the hardware was never told about, expressed as programs.

**Gate-level — running in CI.** The same tests re-run on the post-layout
netlist by the `gl_test` job.

## Design decisions, and what settled them

The first increment is built and measured, so the questions this document
opened with are answered from synthesis rather than from estimates. One state
machine plus the shared 128 x 16 program store synthesises to **219,763 um2 of
cell area, 24.0% of the 6x4 die**, of which 51% is sequential.

**Shared instruction memory, not one store per machine.** The program store is
2048 bits and dominates the sequential area. Four private copies would be
~44% of the die on their own, before any logic. One shared store with a
combinational read port per machine costs roughly 35,000 um2 per extra port --
about 3.8% of the die each.

**Four state machines fit.** Each additional machine costs one read port plus
its own ~250 bits of state, measured at about 5% of the die. Four machines land
near 40% of cell area against LibreLane's 60% density target, so the flexible
option is also the affordable one. The build order is still 1 -> 2 -> 4, with
`area.sh` and a hardening run gating each step rather than a single jump.

**Timestamped edge capture earns its place.** A 16-entry FIFO of
`{pin[2:0], timestamp[15:0], direction}` is 320 bits, which is 15,700 um2, or
**1.7% of the die**. That is the cheapest of the four differentiators and the
only one that lets the chip measure a protocol it was not told about. It goes
into the next increment.

**Clock rate stays at 50 MHz** until the design is large enough for the number
to mean something. See `docs/baseline-results.md` for the slack the current
build closes with.

## Instruction timing

The property the formal work will prove, and what the cocotb tests already
check: every instruction retires in exactly one cycle, except

- `SET` and `SHIFT` with a non-zero delay field, which add that many cycles,
- `WAITP`, which retires when its condition is met or its timeout expires,
- `WAITU`, which retires when the shared cycle counter reaches `TGT`.

Nothing else stalls, so a program's timing is readable from its source.

## What is built

| Module | Role |
|---|---|
| `src/protoemu_sm.v` | fetch, decode and execute; pin drive with per-pin open-drain |
| `src/protoemu_imem.v` | 128 x 16 program store, one write port, two read ports |
| `src/protoemu_cfg.v` | SPI slave: load and read back the program store |
| `src/protoemu_top.v` | cycle counter, input synchronisers, run/step control |
| `src/protoemu_isa.vh` | the encoding, shared by hardware and assembler |
| `test/protoemu_asm.py` | assembler, so programs are written in mnemonics |

## Still open

1. **Does the shared store need a write port from the machines themselves?**
   Self-modifying programs would make adaptive protocols possible, but the
   arbitration cost across four machines is not yet measured.
2. **How do machines synchronise with each other?** `SYS SYNC` currently only
   re-anchors one machine's deadline. A barrier across machines is the natural
   extension, and is what full-duplex protocols will want.
3. **Clock rate**, once the design is large enough for timing closure to bind.
