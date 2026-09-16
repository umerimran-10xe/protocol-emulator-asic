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

## Verification plan

This is half the judging criteria, so it is designed up front rather than
bolted on.

- **Formal (SymbiYosys + Yices):** prove the properties that make the ISA
  trustworthy — every instruction retires in its stated cycle count; `WAITU`
  never overshoots its deadline; `WAITP` always terminates within its timeout;
  open-drain pins never drive high.
- **Constrained-random:** randomised instruction streams against a Python
  reference model of the ISA, comparing pin traces cycle by cycle.
- **Protocol conformance:** cocotb testbenches that talk to independent
  UART/SPI/I2C models, so we test against the protocol rather than against
  our own assumptions.
- **Gate-level:** the same tests re-run on the post-layout netlist in CI.

## Open questions

1. **Two state machines or four?** Four is more flexible but the pin block and
   program store cost scale with it. Two is the safe 6x4 choice.
2. **Shared or per-SM instruction memory?** Sharing saves area; separate stores
   avoid contention.
3. **Is edge capture worth its area?** It is the strongest differentiator but
   needs a timestamp FIFO. Where does it sit against the 6x4 budget?
4. **Clock rate.** 50 MHz is the template default. Low-speed USB (1.5 Mbit) and
   10Mbit Ethernet need oversampling headroom; what does timing closure allow?
