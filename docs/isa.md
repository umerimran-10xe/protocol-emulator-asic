# Instruction set reference

One 16-bit instruction, opcode in bits `[15:13]`, every field at a fixed
position. The authoritative encoding is `src/protoemu_isa.vh`; the assembler in
`test/protoemu_asm.py` mirrors it.

Unless noted, an instruction retires in **one cycle**.

## Machine state

| Register | Width | Purpose |
|---|---|---|
| `PC` | 7 | program counter, 128 instructions |
| `X`, `Y` | 8 | scratch, loop counters |
| `SHIFT` | 16 | serial data register |
| `TGT` | 16 | deadline, compared against the shared cycle counter |
| `PINMASK` | 8 | which pins this machine may drive |
| `DRIVEMODE` | 8 | 1 = open-drain, 0 = push-pull, per pin |
| `FAULT` | 1 | set by a `WAITP` timeout |

The **cycle counter** is 16 bits, shared, and zeroed on the `run` edge.

## Instructions

### `SET value[7:0], delay[4:0]` — `000`

Drives every pin selected by `PINMASK` with the corresponding bit of `value`.
Pins outside the mask are untouched. Retires in `1 + delay` cycles.

Open-drain pins never drive high: a 1 releases the pin and a 0 drives it low.

### `WAITP mode[1:0], pin[2:0], timeout[7:0]` — `001`

Waits for a pin condition: `0` low, `1` high, `2` rising, `3` falling.

`timeout` of 0 waits indefinitely. Otherwise the wait gives up after that many
cycles, sets `FAULT`, and falls through to the next instruction — so a stuck
bus is something the program can handle rather than something that hangs the
chip.

### `WAITU delta[12:0]` — `010`

`TGT += delta`, then waits until the shared cycle counter equals `TGT`.

This is a **deadline, not a delay**. Two programs with the same `WAITU` fire at
the same absolute cycle even if one does more work beforehand, so timing error
cannot accumulate across a long frame. Use `SYS SYNC` to re-anchor `TGT` to the
current cycle when starting a new frame.

### `SHIFT dir, pin[2:0], nbits[3:0], delay[4:0]` — `011`

Moves `nbits` between `SHIFT` and `pin`, `dir` 0 for out and 1 for in.
`nbits` encodes 1–15 directly and 16 as `0`. Each bit takes `2 * (delay + 1)`
cycles, split evenly between the two clock half-periods.

Data is always **right-justified** in `SHIFT[nbits-1:0]`, for both bit orders:
the register is indexed rather than rotated, so an 8-bit MSB-first transfer of
`SHIFT[7:0]` needs no pre-alignment.

If `SHIFTCFG.clken` is set, a clock is generated on `SHIFTCFG.clkpin`, idling
at `SHIFTCFG.clkidle`, which makes SPI a single instruction.

**Shifting in has a minimum delay.** Pins are sampled through two
synchroniser flops, so a bit driven by the peripheral takes two cycles to
become visible. A half-period of `delay + 1` cycles must cover that plus
whatever the peripheral itself takes to respond: `delay = 6` is comfortable at
50 MHz, and `delay = 0` will sample stale data. Shifting *out* has no such
constraint.

### `JMP cond[2:0], addr[6:0]` — `100`

| cond | Meaning |
|---|---|
| 0 | always |
| 1 | `X != 0`, post-decrement `X` |
| 2 | `Y != 0`, post-decrement `Y` |
| 3 | `X == 0` |
| 4 | `Y == 0` |
| 5 | `FAULT` set; taking the branch clears it |
| 6 | `FAULT` clear |
| 7 | the capture FIFO has an entry waiting |

Conditions 1 and 2 make a counted loop two instructions: load the counter, then
branch back. A loop with `X = n` runs `n + 1` times.

### `ALU fn[3:0], imm[8:0]` — `101`

`0` `X++`, `1` `X--`, `2` `Y++`, `3` `Y--`, `4` `X = Y`, `5` `Y = X`,
`6` `X = SHIFT[7:0]`, `7` `SHIFT[7:0] = X`, `8` `X += imm`, `9` `X &= imm`,
`10` `X |= imm`, `11` `X ^= imm`, `12` drive the masked pins from `X`.

Function 12 is the parallel counterpart of `SHIFT`: it puts a computed or
received byte onto the pins in one cycle, without serialising it.

### `LOAD reg[2:0], imm[9:0]` — `110`

`0` `PINMASK`, `1` `DRIVEMODE`, `2` `X`, `3` `Y`, `4` `TGT[9:0]`,
`5` `TGT[15:10]`, `6` `SHIFTCFG`, `7` `SHIFT = imm[7:0]`.

`SHIFTCFG` packs `clkpin[2:0]`, `clkidle` at bit 3, `msbfirst` at bit 4 and
`clken` at bit 5.

### `SYS fn[2:0], arg[9:0]` — `111`

`0` no-op, `1` halt, `2` pulse `irq` (and halt if `arg[0]`),
`3` `TGT = cycle` (re-anchor the deadline to now), `4` clear `FAULT`,
`5` arm edge capture on the pins in `arg[7:0]`, `6` pop a captured entry.

A halted machine holds its pins and stops fetching until the next `run` edge.

## Timestamped edge capture

`SYS CAPARM mask` starts watching the pins in `mask`. From then on, every time
one of them changes, the **whole pin state and the current cycle count** are
pushed into a 16-entry FIFO. Recording the full state rather than which pin
moved means simultaneous edges cost one entry instead of being lost.

`SYS CAPPOP` takes the oldest entry: `X` gets the pin state, `SHIFT` gets the
16-bit timestamp. Popping an empty FIFO does nothing, so pair it with
`JMP CAPRDY`. Because the timestamp lands in `SHIFT`, getting it off the chip
is an ordinary `SHIFT` instruction.

Arming clears the FIFO, so timestamps are always comparable against the moment
capture started. If more than 16 edges arrive before the program drains them,
the oldest are kept and `cap_overflow` (`uo[3]`) goes high.

Capture also arms from outside the chip on a rising edge of `trig_in`
(`ui[4]`), watching all eight pins — so a capture can be started by the event
being observed rather than only by the program.

This is what lets the chip measure a protocol it was never told about:

```python
program = [
    A.CAPARM(0x01),                   # watch pin 0
    A.WAITU(500),                     # let the traffic happen
    A.SYS(A.SYS_CAPPOP),              # first edge  -> SHIFT
    A.SHIFT(dir_in=False, pin=1, nbits=16, delay=3),
    A.SYS(A.SYS_CAPPOP),              # second edge -> SHIFT
    A.SHIFT(dir_in=False, pin=1, nbits=16, delay=3),
    A.SYS(A.SYS_HALT),
]
```

The difference between the two timestamps is a pulse width, or a bit period,
that nothing in the program knew in advance.

## Worked example: send a byte, MSB first, with a clock

```python
import protoemu_asm as A

program = [
    A.LOAD(A.REG_PINMASK,   0x03),        # own pin 0 (data) and pin 1 (clock)
    A.LOAD(A.REG_DRIVEMODE, 0x00),        # push-pull
    A.LOAD(A.REG_SHIFTCFG,
           A.shiftcfg(clkpin=1, clkidle=0, msbfirst=1, clken=1)),
    A.LOAD(A.REG_SHIFTDAT,  0xA5),
    A.SHIFT(dir_in=False, pin=0, nbits=8, delay=2),
    A.SYS(A.SYS_HALT),
]
```

## Recovering from a stuck bus

```python
program = [
    A.LOAD(A.REG_PINMASK, 0xF0),
    A.WAITP(A.WP_RISE, pin=0, timeout=200),   # expect a clock edge
    A.JMP(A.CND_FAULT, RECOVER),              # it never came
    ...                                        # normal path
]
```

Without the timeout this is a hang. With it, the missing edge is a branch.
