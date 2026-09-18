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

**Formal (SymbiYosys + Yices) — running.** `./scripts/formal.sh` runs five
tasks. Every block that holds state shared between machines is proved, and every
proof is mutation-checked rather than merely observed to pass.

`protoemu_sm` proves the per-machine properties by k-induction, so they hold in
every reachable state rather than just the first few cycles. They live in an
`ifdef FORMAL` block at the bottom of `src/protoemu_sm.v`, next to the logic
they constrain.

| Property | Why it matters |
|---|---|
| An open-drain pin never drives high | Driving high into an I2C bus is contention |
| A pin outside `PINMASK` is never driven | One machine cannot reach into another's pins |
| The state register only holds defined states | The unused encodings 6 and 7 are unreachable |
| A halted machine holds its pins and stays halted | Found a real bug: `ST_HALT` fell through to the shift datapath and kept driving |
| An armed `WAITP` always leaves the wait when its timeout expires | The timeout is the whole point; a wait that could hang is worse than no timeout |
| Nothing moves when neither running nor stepping | `run`/`step` really are a freeze control |

`protoemu_arb` proves the pin arbiter. It is combinational, so one BMC step is
already exhaustive over its entire input space — there is nothing a directed
test could add on top.

| Property | Why it matters |
|---|---|
| A pin no machine claims is released, and reads 0 | An unowned pin does not carry a machine's internal `PINVAL` to the pad |
| What a pin shows is its owner's request, unchanged | Arbitration must not alter the winner's output, only choose it |
| `conflict` is exactly "claimed by more than one machine" | It is reported to the host as a program error, so a missed or false overlap is as bad as the fight itself |

`protoemu_barrier` proves the rendezvous, also combinational and also
exhaustive in one step.

| Property | Why it matters |
|---|---|
| Nobody leaves a barrier they are not at | The release signal must not fire at a machine that is still executing |
| Nobody leaves before every participant has arrived or halted | This is the whole guarantee a program buys by using a barrier |
| Nobody is left waiting once its participants are all there | Without it, a barrier that never releases would satisfy everything above |
| Two machines waiting on the same set leave together | The reason the block exists: a transmitter and a receiver starting on the same edge |

Dropping the halted term, or releasing without checking the machine is actually
at a barrier, each make it fail.

`protoemu_capture` proves the edge-capture block by k-induction, at four read
cursors. The cursors are what make this worth proving: four machines advancing
independently into one record is not something a directed test can cover.

| Property | Why it matters |
|---|---|
| The window never overruns the record | The write pointer is bounded by the depth, however the edges arrive |
| No cursor ever passes the writer | This is the one that matters: it makes `ready` mean "an entry was written here", not "the pointers happen to differ" |
| Popping an empty cursor does nothing | A program that reads without checking `ready` re-reads rather than walking off the end |
| Arming resets the window for every cursor | No cursor is left pointing into a record that no longer exists |
| Overflow is only reported for an edge that arrived with the window full | Not because the pointers drifted |

Letting a pop move a cursor without `ready`, letting the writer run past the
depth, and leaving the cursors alone on an arm each make it fail.

`protoemu_arb_miter` proves **cross-machine non-interference**, which is the
property the per-machine proof cannot see. Two copies of the arbiter get the
same claims but independently chosen drive requests, with only the *owner* of
each pin assumed to ask for the same thing in both. The assertion is that the
pins still come out identical — so nothing a non-owner does can reach any pin
it does not own, for every combination of programs rather than the ones a test
happened to run. Ownership is restated in the miter from the claims rather than
taken from the arbiter's own priority chain, so a bug in that chain cannot make
the proof agree with itself.

Both arbiter tasks are run at **four** machines, the count `docs/scaling.md`
settled on, while the chip is still built with one: the multi-machine behaviour
is proved before it is instantiated.

All three tasks were mutation-checked rather than merely observed to pass —
dropping the priority term, merging drive enables instead of selecting them,
and suppressing the conflict report each make them fail.

**Directed tests (cocotb) — running.** 26 tests in `test/test.py`, written
against the assembler rather than hex. They cover config load and readback, pin
drive and masking, open-drain, both `WAITU` behaviours, `WAITP` hit and timeout,
`SHIFT` in and out against a peripheral model that responds to the generated
clock, counted loops, run/step control, per-machine start addresses, the
control-register decode, the capture window's behaviour when it is read while
filling, barriers that name machines which were never built, and a cross-check that the assembler and the Verilog header agree on
all 46 ISA constants.

**Constrained-random — running.** `test/protoemu_model.py` is a cycle-accurate
Python model, written from the RTL and deliberately mirroring its structure: one
`step()` is one clock, every read takes the pre-state, and the variables carry
the register names, so a mismatch report names the register that diverged.

It models the **chip**, not one machine. `Machine` is `protoemu_sm.v`;
`ProtoEmu` is the shared program store and cycle counter, the pin arbitration,
the rendezvous, and the one capture record with a cursor per machine. Anything
shared lives on the chip, which is what lets the model say something at four
machines rather than one. Within a step every machine is stepped from a snapshot
of the pre-state, because that is what a clock edge does.

The strobes are modelled as registers rather than as immediate effects, which
matters more than it sounds: `cap_arm` and `cap_pop` are registered in
`protoemu_sm.v`, so the entry a machine reads and whether one is ready still
reflect the state from before. Getting that wrong made `JMP CAPRDY` branch a
cycle early — a divergence a 400-program soak found on trial 167 once capture
instructions joined the random stream.

`test_random_programs_match_the_model` runs randomised instruction streams
through the RTL and the model in lockstep and compares the pins every cycle.
The generator is weighted rather than uniform -- uniform 16-bit words are
mostly long waits and immediate halts, which exercises nothing -- and branches
are confined inside the program so control cannot reach an address the loader
never wrote. It emits the whole instruction set, capture and barriers included.

    PROTOEMU_TRIALS=250 PROTOEMU_SEED=0x5EED make   # deeper soak

This one test skips in gate-level simulation. It reads `pin_s1`, the cycle
counter and the machine's registers by name — to feed the model and to say
which register diverged — and none of those names survive synthesis. Every
other test looks only at the pins and runs against the netlist unchanged.

The default of 20 programs keeps the suite a few seconds; the soak is for
before a merge that touches the datapath.

**Protocol conformance — running.** Three protocols, all decoded by models
written from the protocol rather than from the program under test:

- a 1 Mbaud UART frame, recovered by a receiver that finds the start bit and
  samples at mid-bit;
- an I2C START and address byte on a bus modelled with pull-ups, where a line
  reads low only while the emulator actively drives it -- so the model would
  catch the emulator driving high, not just report the wrong byte;
- **full-duplex SPI split across two machines**, against a target that samples
  MOSI on each active edge and presents the next MISO bit on each idle edge.

The SPI test is the one the multi-machine work was for. Machine 0 owns SCLK and
MOSI and shifts a byte out; machine 1 owns none of those pins -- the arbiter
would not let it -- and shifts the target's byte in off MISO, sampling on the
edges machine 0 generates. The only thing keeping the two shift engines in step
is that `SYS BARRIER` released them on the same cycle.

That the barrier is load-bearing is checked rather than asserted. Machine 1
waits on an external ready line first, at a time no program can predict, so
instruction counting cannot align the two. Replace the barriers with no-ops and
machine 0 finishes transmitting before machine 1 starts listening: the received
byte comes back `0xf0` instead of `0x3c`.

An earlier version of this test padded machine 1 with seven no-ops instead and
claimed the same thing, which was wrong -- at a divider of 6 the receive path
absorbs a seven-cycle skew without noticing, and the test passed with the
barriers removed. Worth recording, because a test that cannot fail for the
reason it claims is worse than no test.

These are the tests that matter most: they show protocols the hardware was
never told about, expressed as programs.

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

**Four state machines fit, but only with a shallower store — and this is now
what is built.** This section originally said four machines land near 40% and
were comfortable. That was a synthesis number, before the 1.40x post-layout
ratio was measured. Redone properly in `docs/scaling.md`: four machines with a
128-entry store land at **~61%**, over the 60% density target.

Four machines with a **64-entry** store is the configuration that shipped.
Measured on the built RTL: **278,865 um2, 30.4% of the die** at synthesis, and
pre-layout slack **+5.03 ns, met** — against -12.90 ns for the single machine
with the deeper store. Shrinking the store attacks the critical path and the
area at once, because the store's read mux and the PC fanout driving it were
the critical path.

The trade is explicit and was taken: four machines *or* a 128-instruction
program, not both.

**Timestamped edge capture earns its place — and cost more than estimated.**
It is built. The estimate here was 320 bits for `{pin[2:0], timestamp, dir}`,
1.7% of the die. The built version records the **whole pin state** rather than
which pin moved, so simultaneous edges cost one entry instead of being lost:
16 entries of `{pins[7:0], timestamp[15:0]}` is 384 bits, and with the FIFO
pointers, edge detection and read muxes the measured cost is **+34,658 um2,
3.8% of the die** — synthesis went from 24.0% to 27.8%.

Twice the estimate, and still worth it: it is the only feature that lets the
chip measure a protocol it was not told about, and `scripts/timing.sh` confirms
it adds nothing to the critical path, which still runs PC to program store to
decode.

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
| `src/protoemu_arb.v` | pin ownership between machines, and conflict reporting |
| `src/protoemu_barrier.v` | rendezvous: machines waiting on each other leave together |
| `src/protoemu_imem.v` | 64 x 16 program store, one write port, one fetch port per machine |
| `src/protoemu_capture.v` | timestamped edge capture: one 16-entry record, one read cursor per machine |
| `src/protoemu_cfg.v` | SPI slave: load and read back the program store and control registers |
| `src/protoemu_top.v` | cycle counter, input synchronisers, run/step control, the machine array |
| `src/protoemu_isa.vh` | the encoding, shared by hardware and assembler |
| `test/protoemu_asm.py` | assembler, so programs are written in mnemonics |

## Still open

1. **Does the shared store need a write port from the machines themselves?**
   Self-modifying programs would make adaptive protocols possible, but the
   arbitration cost across four machines is not yet measured.
2. ~~**How do machines synchronise with each other?**~~ Answered: `SYS BARRIER`
   stops a machine until every machine it names is also at a barrier and
   releases all of them on the same cycle. `src/protoemu_barrier.v` carries the
   proofs. What is still open is the protocol work that uses it -- full-duplex
   SPI with the transmitter and receiver on separate machines is the first case
   the barrier was built for.
3. **Clock rate**, once the design is large enough for timing closure to bind.
