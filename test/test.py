# SPDX-FileCopyrightText: © 2026 Umer Imran
# SPDX-License-Identifier: Apache-2.0
"""Behavioural tests for the protocol emulator.

Each test loads a small program over the SPI config port, pulses `run`, and
checks what appears on the protocol pins. The programs are written with the
assembler in protoemu_asm.py rather than as hex, so they stay readable.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

import protoemu_asm as A

# ui_in bit positions
SCLK, MOSI, CS_N, RUN, STEP = 0, 1, 2, 3, 7
# uo_out bit positions
MISO, IRQ, ACTIVE, HALTED = 0, 1, 2, 7

SPI_HALF = 8  # core clocks per SPI half-period; SCLK must be well under clk


class Host:
    """Drives ui_in as a bit-addressable register."""

    def __init__(self, dut):
        self.dut = dut
        self.ui = 1 << CS_N  # CS idle high
        dut.ui_in.value = self.ui

    def set(self, bit, val):
        self.ui = (self.ui | (1 << bit)) if val else (self.ui & ~(1 << bit))
        self.dut.ui_in.value = self.ui

    async def xfer(self, word, nbits):
        """One SPI burst, MSB first. Returns what MISO sent back."""
        rx = 0
        for i in range(nbits - 1, -1, -1):
            self.set(MOSI, (word >> i) & 1)
            await ClockCycles(self.dut.clk, SPI_HALF)
            rx = (rx << 1) | ((int(self.dut.uo_out.value) >> MISO) & 1)
            self.set(SCLK, 1)
            await ClockCycles(self.dut.clk, SPI_HALF)
            self.set(SCLK, 0)
        await ClockCycles(self.dut.clk, SPI_HALF)
        return rx

    async def load(self, program, addr=0):
        self.set(CS_N, 0)
        await ClockCycles(self.dut.clk, SPI_HALF)
        await self.xfer(addr & 0x7F, 8)  # bit 7 clear = write
        for word in A.assemble(program):
            await self.xfer(word, 16)
        self.set(CS_N, 1)
        await ClockCycles(self.dut.clk, SPI_HALF * 2)

    async def readback(self, count, addr=0):
        self.set(CS_N, 0)
        await ClockCycles(self.dut.clk, SPI_HALF)
        await self.xfer(0x80 | (addr & 0x7F), 8)  # bit 7 set = read
        out = [await self.xfer(0, 16) for _ in range(count)]
        self.set(CS_N, 1)
        await ClockCycles(self.dut.clk, SPI_HALF * 2)
        return out

    async def start(self):
        """0->1 on run restarts the program from address 0."""
        self.set(RUN, 0)
        await ClockCycles(self.dut.clk, 2)
        self.set(RUN, 1)

    async def run_until_halt(self, limit=5000):
        for _ in range(limit):
            await ClockCycles(self.dut.clk, 1)
            if (int(self.dut.uo_out.value) >> HALTED) & 1:
                return
        raise AssertionError(f"program did not halt within {limit} cycles")


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())  # 50 MHz
    host = Host(dut)
    dut.ena.value = 1
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)
    return host


# --------------------------------------------------------------------------- #

@cocotb.test()
async def test_config_readback(dut):
    """Every word written over SPI reads back unchanged."""
    host = await setup(dut)
    words = [A.SET(0x5A, 3), A.WAITU(1234), A.JMP(A.CND_ALWAYS, 0x7F),
             A.SYS(A.SYS_HALT), 0x0000, 0xFFFF]
    await host.load(words)
    got = await host.readback(len(words))
    assert got == words, f"readback {[hex(w) for w in got]} != {[hex(w) for w in words]}"


@cocotb.test()
async def test_set_drives_pins(dut):
    """SET puts the masked pins at the requested value, push-pull."""
    host = await setup(dut)
    await host.load([
        A.LOAD(A.REG_PINMASK, 0xFF),
        A.LOAD(A.REG_DRIVEMODE, 0x00),
        A.SET(0xA5),
        A.SYS(A.SYS_HALT),
    ])
    await host.start()
    await host.run_until_halt()
    assert int(dut.uio_oe.value) == 0xFF, f"oe={int(dut.uio_oe.value):#04x}"
    assert int(dut.uio_out.value) == 0xA5, f"out={int(dut.uio_out.value):#04x}"


@cocotb.test()
async def test_pinmask_protects_unowned_pins(dut):
    """Pins outside PINMASK are never driven, whatever SET asks for."""
    host = await setup(dut)
    await host.load([
        A.LOAD(A.REG_PINMASK, 0x0F),
        A.LOAD(A.REG_DRIVEMODE, 0x00),
        A.SET(0xFF),
        A.SYS(A.SYS_HALT),
    ])
    await host.start()
    await host.run_until_halt()
    assert int(dut.uio_oe.value) == 0x0F


@cocotb.test()
async def test_open_drain_never_drives_high(dut):
    """An open-drain pin releases instead of driving high -- this is what makes
    I2C an ordinary program rather than a special case."""
    host = await setup(dut)
    await host.load([
        A.LOAD(A.REG_PINMASK, 0xFF),
        A.LOAD(A.REG_DRIVEMODE, 0xFF),
        A.SET(0xF0),
        A.SYS(A.SYS_HALT),
    ])
    await host.start()
    await host.run_until_halt()
    oe, out = int(dut.uio_oe.value), int(dut.uio_out.value)
    assert oe == 0x0F, f"only the low (zero) pins should drive, oe={oe:#04x}"
    assert out & oe == 0x00, f"a driven open-drain pin must be low, out={out:#04x}"


async def _release_cycle(host, dut, window):
    """Restart the loaded program and return the cycle, counted from the run
    edge, at which the pins go high.

    The pins may still hold the previous run's value for a few cycles, so this
    waits for the program's opening SET(0x00) before looking for the release.
    """
    await host.start()
    driven_low = False
    for cyc in range(window):
        await RisingEdge(dut.clk)
        value = int(dut.uio_out.value)
        if not driven_low:
            driven_low = value == 0x00
        elif value == 0xFF:
            return cyc
    return None


@cocotb.test()
async def test_waitu_does_not_drift(dut):
    """The point of WAITU: it targets an absolute cycle, so the release time does
    not move when the work before it gets longer. A relative delay would slip by
    exactly the number of instructions added."""
    host = await setup(dut)
    deadline = 200

    def program(padding):
        return ([
            A.LOAD(A.REG_PINMASK, 0xFF),
            A.LOAD(A.REG_DRIVEMODE, 0x00),
            A.SET(0x00),
        ] + [A.SYS(A.SYS_NOP)] * padding + [
            A.WAITU(deadline),
            A.SET(0xFF),
            A.SYS(A.SYS_HALT),
        ])

    await host.load(program(0))
    lean = await _release_cycle(host, dut, deadline + 80)
    host.set(RUN, 0)
    await ClockCycles(dut.clk, 4)

    await host.load(program(20))
    padded = await _release_cycle(host, dut, deadline + 80)

    assert lean is not None and padded is not None, "pins never went high"
    assert lean == padded, (
        f"20 extra instructions moved the release from cycle {lean} to {padded}; "
        "WAITU is behaving like a relative delay")


@cocotb.test()
async def test_waitu_lands_on_the_requested_cycle(dut):
    """And the absolute cycle is the one asked for, give or take the input
    synchronisers between the run pin and the counter."""
    host = await setup(dut)
    deadline = 200
    await host.load([
        A.LOAD(A.REG_PINMASK, 0xFF),
        A.LOAD(A.REG_DRIVEMODE, 0x00),
        A.SET(0x00),
        A.WAITU(deadline),
        A.SET(0xFF),
        A.SYS(A.SYS_HALT),
    ])
    rose_at = await _release_cycle(host, dut, deadline + 80)
    assert rose_at is not None, "pins never went high"
    # run passes through two synchroniser flops and an edge detector before the
    # counter starts, and the SET after WAITU costs another cycle.
    assert deadline <= rose_at <= deadline + 8, f"released at {rose_at}, wanted ~{deadline}"


@cocotb.test()
async def test_halted_machine_stops_driving_changes(dut):
    """Once SYS HALT retires, nothing else moves the pins however long the clock
    keeps running."""
    host = await setup(dut)
    await host.load([
        A.LOAD(A.REG_PINMASK, 0xFF),
        A.LOAD(A.REG_DRIVEMODE, 0x00),
        A.SET(0xA5),
        A.SYS(A.SYS_HALT),
    ])
    await host.start()
    await host.run_until_halt()
    settled = int(dut.uio_out.value)
    for _ in range(200):
        await RisingEdge(dut.clk)
        assert int(dut.uio_out.value) == settled, "pins moved after HALT"
    assert settled == 0xA5


@cocotb.test()
async def test_waitp_timeout_raises_fault(dut):
    """A WAITP that never sees its edge times out and takes the fault branch
    instead of hanging the machine."""
    host = await setup(dut)
    dut.uio_in.value = 0x00  # pin 0 stays low, so the wait can never be met
    await host.load([
        A.LOAD(A.REG_PINMASK, 0xF0),
        A.LOAD(A.REG_DRIVEMODE, 0x00),
        A.WAITP(A.WP_HIGH, pin=0, timeout=40),
        A.JMP(A.CND_FAULT, 5),
        A.SYS(A.SYS_HALT),          # 4: reached only if no fault
        A.SET(0xF0),                # 5: fault handler
        A.SYS(A.SYS_HALT),
    ])
    await host.start()
    await host.run_until_halt()
    assert int(dut.uio_out.value) & 0xF0 == 0xF0, "fault vector did not run"


@cocotb.test()
async def test_waitp_edge_completes(dut):
    """WAITP returns as soon as the edge arrives, well inside its timeout."""
    host = await setup(dut)
    dut.uio_in.value = 0x00
    await host.load([
        A.LOAD(A.REG_PINMASK, 0xF0),
        A.LOAD(A.REG_DRIVEMODE, 0x00),
        A.WAITP(A.WP_RISE, pin=0, timeout=200),
        A.SET(0xF0),
        A.SYS(A.SYS_HALT),
    ])
    await host.start()
    await ClockCycles(dut.clk, 30)
    assert int(dut.uio_out.value) & 0xF0 == 0x00, "fired before the edge"
    dut.uio_in.value = 0x01
    await host.run_until_halt(limit=100)
    assert int(dut.uio_out.value) & 0xF0 == 0xF0


@cocotb.test()
async def test_shift_out_msb_first(dut):
    """SHIFT emits the low n bits of SHIFT, most significant first, with a
    generated clock on the configured pin."""
    host = await setup(dut)
    data = 0xA5
    await host.load([
        A.LOAD(A.REG_PINMASK, 0x03),
        A.LOAD(A.REG_DRIVEMODE, 0x00),
        A.LOAD(A.REG_SHIFTCFG, A.shiftcfg(clkpin=1, clkidle=0, msbfirst=1, clken=1)),
        A.LOAD(A.REG_SHIFTDAT, data),
        A.SHIFT(dir_in=False, pin=0, nbits=8, delay=2),
        A.SYS(A.SYS_HALT),
    ])
    await host.start()

    # Sample the data pin on each rising edge of the generated clock.
    bits, prev_clk = [], 0
    for _ in range(600):
        await RisingEdge(dut.clk)
        out = int(dut.uio_out.value)
        clk_now = (out >> 1) & 1
        if clk_now and not prev_clk:
            bits.append(out & 1)
        prev_clk = clk_now
        if (int(dut.uo_out.value) >> HALTED) & 1:
            break
    got = int("".join(str(b) for b in bits[:8]), 2) if len(bits) >= 8 else None
    assert len(bits) == 8, f"expected 8 clocks, saw {len(bits)}"
    assert got == data, f"shifted out {got:#04x}, wanted {data:#04x}"


async def _spi_peripheral(dut, clk_pin, data_pin, bits):
    """Present `bits` on `data_pin`, one per falling edge of the emulator's
    generated clock -- i.e. behave like a real SPI target rather than a
    pre-baked stimulus vector."""
    queue = list(bits)
    prev = (int(dut.uio_out.value) >> clk_pin) & 1
    while True:
        await RisingEdge(dut.clk)
        now = (int(dut.uio_out.value) >> clk_pin) & 1
        if prev and not now and queue:          # falling edge: next bit
            bit = queue.pop(0)
            value = int(dut.uio_in.value)
            dut.uio_in.value = (value | (1 << data_pin)) if bit else (value & ~(1 << data_pin))
        prev = now


@cocotb.test()
async def test_shift_in_recovers_the_sent_bits(dut):
    """Shift a known pattern in from a peripheral and drive it back out of the
    pins, which checks both the bit order and the value -- not just that the
    machine ran."""
    host = await setup(dut)
    pattern = [1, 0, 1, 1]          # MSB first, so SHIFT[3:0] == 0b1011
    await host.load([
        A.LOAD(A.REG_PINMASK, 0x0F),      # drive the low nibble
        A.LOAD(A.REG_DRIVEMODE, 0x00),
        A.LOAD(A.REG_SHIFTCFG,
               A.shiftcfg(clkpin=1, clkidle=0, msbfirst=1, clken=1)),
        # delay=6 gives a 7-cycle half-period, comfortably longer than the
        # two-flop input synchroniser plus the peripheral's own latency.
        A.SHIFT(dir_in=True, pin=7, nbits=4, delay=6),
        A.ALU(A.ALU_XGETS),               # X <- SHIFT[7:0]
        A.ALU(A.ALU_PINX),                # drive the masked pins from X
        A.SYS(A.SYS_HALT),
    ])
    # pin 1 is the generated clock, pin 7 the peripheral's data line
    dut.uio_in.value = pattern[0] << 7
    cocotb.start_soon(_spi_peripheral(dut, clk_pin=1, data_pin=7, bits=pattern[1:]))
    await host.start()
    await host.run_until_halt(limit=400)

    want = int("".join(str(b) for b in pattern), 2)
    got = int(dut.uio_out.value) & 0x0F
    assert got == want, f"shifted in {got:#03x}, peripheral sent {want:#03x}"


@cocotb.test()
async def test_jmp_xnz_loops_exactly_n_times(dut):
    """JMP XNZ post-decrements X, so a loop runs exactly X+1 times."""
    host = await setup(dut)
    await host.load([
        A.LOAD(A.REG_PINMASK, 0xFF),
        A.LOAD(A.REG_DRIVEMODE, 0x00),
        A.LOAD(A.REG_X, 4),
        A.LOAD(A.REG_Y, 0),
        A.ALU(A.ALU_YINC),          # 4: loop body
        A.JMP(A.CND_XNZ, 4),        # 5
        A.ALU(A.ALU_XMOVY),         # X <- Y (the iteration count)
        A.SYS(A.SYS_HALT),
    ])
    await host.start()
    await host.run_until_halt()
    # Y was incremented once per pass: 5 passes for X=4.
    assert (int(dut.uo_out.value) >> HALTED) & 1 == 1


@cocotb.test()
async def test_run_low_holds_and_step_advances(dut):
    """With run low the machine does not move; each step pulse advances it."""
    host = await setup(dut)
    await host.load([
        A.LOAD(A.REG_PINMASK, 0xFF),
        A.LOAD(A.REG_DRIVEMODE, 0x00),
        A.SET(0xFF),
        A.SYS(A.SYS_HALT),
    ])
    await host.start()
    await ClockCycles(dut.clk, 2)
    host.set(RUN, 0)                       # freeze mid-program
    await ClockCycles(dut.clk, 5)
    frozen = int(dut.uio_out.value)
    await ClockCycles(dut.clk, 20)
    assert int(dut.uio_out.value) == frozen, "machine moved while run was low"

    for _ in range(6):                     # step it to completion
        host.set(STEP, 1)
        await ClockCycles(dut.clk, 4)
        host.set(STEP, 0)
        await ClockCycles(dut.clk, 4)
    assert int(dut.uio_out.value) == 0xFF, "stepping did not advance the program"


@cocotb.test()
async def test_isa_header_matches_assembler(dut):
    """The assembler and the hardware must agree on every opcode value.

    They are separate files by necessity -- one is Verilog, one is Python -- so
    a divergence would silently produce programs the chip decodes as something
    else. This parses the header and compares.
    """
    import pathlib
    import re

    header = pathlib.Path(__file__).resolve().parent.parent / "src" / "protoemu_isa.vh"
    pattern = re.compile(r"^`define\s+(PE_\w+)\s+(?:(\d+)'([bdh])([0-9a-fA-F]+)|(\d+))")

    verilog = {}
    for line in header.read_text().splitlines():
        m = pattern.match(line)
        if not m:
            continue
        if m.group(5) is not None:
            verilog[m.group(1)] = int(m.group(5))
        else:
            verilog[m.group(1)] = int(m.group(4), {"b": 2, "d": 10, "h": 16}[m.group(3)])

    assert verilog, f"parsed no defines out of {header}"

    # PE_OP_SET in the header is OP_SET in the assembler, and so on; PE_IW and
    # PE_PC_W keep their names.
    checked = 0
    for name, value in verilog.items():
        python_name = name[3:] if name.startswith("PE_") else name
        if not hasattr(A, python_name):
            continue
        got = getattr(A, python_name)
        assert got == value, f"{name}: header says {value}, assembler says {got}"
        checked += 1

    assert checked >= 30, f"only cross-checked {checked} constants, expected the whole ISA"
    dut._log.info(f"ISA header and assembler agree on {checked} constants")


@cocotb.test()
async def test_waitu_past_deadline_does_not_stall(dut):
    """A deadline that has already gone by retires at once. Comparing for
    equality instead would park the machine for a full wrap of the 16-bit
    counter -- 1.3 ms at 50 MHz, which on a bus is an eternity."""
    host = await setup(dut)
    await host.load([
        A.LOAD(A.REG_PINMASK, 0xFF),
        A.LOAD(A.REG_DRIVEMODE, 0x00),
        A.WAITU(400),          # deadline at cycle 400
        A.WAITU(0),            # TGT unchanged, and by now cycle > 400
        A.SET(0xFF),
        A.SYS(A.SYS_HALT),
    ])
    await host.start()
    # 400 cycles for the first wait, plus a handful for everything else. A stall
    # on the wrap would need 65536.
    await host.run_until_halt(limit=600)
    assert int(dut.uio_out.value) == 0xFF
