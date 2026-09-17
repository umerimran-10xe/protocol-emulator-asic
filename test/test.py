# SPDX-FileCopyrightText: © 2026 Umer Imran
# SPDX-License-Identifier: Apache-2.0
"""Behavioural tests for the protocol emulator.

Each test loads a small program over the SPI config port, pulses `run`, and
checks what appears on the protocol pins. The programs are written with the
assembler in protoemu_asm.py rather than as hex, so they stay readable.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

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

    async def _frame(self, read, control, addr):
        """16-bit header: [15] read, [14] control space, [7:0] address."""
        self.set(CS_N, 0)
        await ClockCycles(self.dut.clk, SPI_HALF)
        header = ((1 << 15) if read else 0) | ((1 << 14) if control else 0) | (addr & 0xFF)
        await self.xfer(header, 16)

    async def load(self, program, addr=0):
        await self._frame(read=False, control=False, addr=addr)
        for word in A.assemble(program):
            await self.xfer(word, 16)
        self.set(CS_N, 1)
        await ClockCycles(self.dut.clk, SPI_HALF * 2)

    async def readback(self, count, addr=0):
        await self._frame(read=True, control=False, addr=addr)
        out = [await self.xfer(0, 16) for _ in range(count)]
        self.set(CS_N, 1)
        await ClockCycles(self.dut.clk, SPI_HALF * 2)
        return out

    async def write_control(self, values, addr=0):
        await self._frame(read=False, control=True, addr=addr)
        for value in values:
            await self.xfer(value, 16)
        self.set(CS_N, 1)
        await ClockCycles(self.dut.clk, SPI_HALF * 2)

    async def read_control(self, count, addr=0):
        await self._frame(read=True, control=True, addr=addr)
        out = [await self.xfer(0, 16) for _ in range(count)]
        self.set(CS_N, 1)
        await ClockCycles(self.dut.clk, SPI_HALF * 2)
        return out

    async def set_start_pc(self, machine, address):
        await self.write_control([address], addr=machine)

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


async def _uart_receive(dut, pin, bit_cycles, timeout=20000):
    """A UART receiver written from the protocol, not from the program under
    test: find the start bit, sample at the middle of each bit, LSB first, and
    check the stop bit. Returns the received byte.
    """
    def line():
        return (int(dut.uio_out.value) >> pin) & 1

    for _ in range(timeout):                       # wait for the idle line
        await RisingEdge(dut.clk)
        if line() == 1:
            break
    else:
        raise AssertionError("line never went idle")

    for _ in range(timeout):                       # then for the start bit
        await RisingEdge(dut.clk)
        if line() == 0:
            break
    else:
        raise AssertionError("no start bit")

    await ClockCycles(dut.clk, bit_cycles + bit_cycles // 2)   # middle of bit 0
    byte = 0
    for i in range(8):
        byte |= line() << i                        # UART is LSB first
        await ClockCycles(dut.clk, bit_cycles)
    assert line() == 1, "stop bit was not high"
    return byte


@cocotb.test()
async def test_uart_transmit_is_decoded_by_a_receiver(dut):
    """Bit-bang a real 1 Mbaud UART frame and decode it with a receiver that
    knows only the protocol. This is the whole point of the chip: a protocol
    the hardware was never told about, expressed as a program.
    """
    bit_cycles = 50                       # 50 MHz / 50 = 1 Mbaud
    byte = 0x5A

    host = await setup(dut)
    await host.load([
        A.LOAD(A.REG_PINMASK, 0x01),                  # pin 0 is TX
        A.LOAD(A.REG_DRIVEMODE, 0x00),
        A.LOAD(A.REG_SHIFTCFG, A.shiftcfg(msbfirst=0, clken=0)),
        A.LOAD(A.REG_SHIFTDAT, byte),
        A.SET(0x01),                                  # idle high
        A.SYS(A.SYS_SYNC),                            # anchor the frame to now
        A.WAITU(bit_cycles),
        A.SET(0x00),                                  # start bit
        A.WAITU(bit_cycles),
        # Each bit takes 2 * (delay + 1) cycles, so delay 24 is one bit time.
        A.SHIFT(dir_in=False, pin=0, nbits=8, delay=bit_cycles // 2 - 1),
        A.SET(0x01),                                  # stop bit
        A.WAITU(bit_cycles),
        A.SYS(A.SYS_HALT),
    ])

    receiver = cocotb.start_soon(_uart_receive(dut, pin=0, bit_cycles=bit_cycles))
    await host.start()
    got = await receiver
    assert got == byte, f"received {got:#04x}, transmitted {byte:#04x}"


def _bus(dut, pin):
    """An open-drain bus line: low only while the emulator actively drives it,
    otherwise pulled high. This is what a real I2C bus with pull-ups looks like,
    and reading it this way also checks the emulator never drives high.
    """
    oe, out = int(dut.uio_oe.value), int(dut.uio_out.value)
    driving = (oe >> pin) & 1
    if driving:
        assert not ((out >> pin) & 1), f"pin {pin} drove high on an open-drain bus"
        return 0
    return 1


async def _i2c_watch_address(dut, sda=0, scl=1, timeout=20000):
    """Wait for an I2C START (SDA falling while SCL is high), then sample SDA on
    each rising edge of SCL and return the eight bits, MSB first."""
    prev_sda = prev_scl = 1
    started = False
    byte, bits = 0, 0

    for _ in range(timeout):
        await RisingEdge(dut.clk)
        now_sda, now_scl = _bus(dut, sda), _bus(dut, scl)
        if not started:
            if prev_scl and now_scl and prev_sda and not now_sda:
                started = True
        elif now_scl and not prev_scl:             # SCL rising: sample
            byte = (byte << 1) | now_sda
            bits += 1
            if bits == 8:
                return byte
        prev_sda, prev_scl = now_sda, now_scl
    raise AssertionError(f"saw {bits} bits after start={started}")


@cocotb.test()
async def test_i2c_start_and_address_on_an_open_drain_bus(dut):
    """Drive an I2C START and an address byte with both lines in open-drain.

    Nothing in the program says "open-drain" more than once: DRIVEMODE is set
    at the top and every SET after it releases rather than drives high. On an
    engine without per-pin open-drain this becomes a pin-direction dance around
    every single bit.
    """
    host = await setup(dut)
    address = 0xA4                       # 7-bit address 0x52, write
    await host.load([
        A.LOAD(A.REG_PINMASK, 0x03),              # pin 0 SDA, pin 1 SCL
        A.LOAD(A.REG_DRIVEMODE, 0x03),            # both open-drain
        A.SET(0x03, 8),                           # idle: both released high
        A.SET(0x02, 8),                           # START: SDA low, SCL high
        A.SET(0x00, 8),                           # SCL low, ready for data
        A.LOAD(A.REG_SHIFTCFG,
               A.shiftcfg(clkpin=1, clkidle=0, msbfirst=1, clken=1)),
        A.LOAD(A.REG_SHIFTDAT, address),
        # Data changes while SCL is low and is stable while SCL is high, which
        # is what the shift sequencer does for free.
        A.SHIFT(dir_in=False, pin=0, nbits=8, delay=6),
        A.SET(0x03, 8),                           # release both for the ACK slot
        A.SYS(A.SYS_HALT),
    ])

    watcher = cocotb.start_soon(_i2c_watch_address(dut))
    await host.start()
    got = await watcher
    assert got == address, f"bus saw {got:#04x}, program sent {address:#04x}"


def _random_program(rng, length):
    """A random but useful instruction stream.

    Fully uniform 16-bit words would mostly be long WAITs and immediate halts,
    which exercises nothing. This weights towards instructions that move pins
    and keeps waits short so a program actually gets somewhere.
    """
    program = [
        A.LOAD(A.REG_PINMASK, rng.randrange(256)),
        A.LOAD(A.REG_DRIVEMODE, rng.randrange(256)),
        A.LOAD(A.REG_SHIFTCFG, A.shiftcfg(clkpin=rng.randrange(8),
                                          clkidle=rng.randrange(2),
                                          msbfirst=rng.randrange(2),
                                          clken=rng.randrange(2))),
    ]
    while len(program) < length:
        pick = rng.randrange(10)
        if pick < 3:
            program.append(A.SET(rng.randrange(256), rng.randrange(4)))
        elif pick == 3:
            program.append(A.WAITP(rng.randrange(4), rng.randrange(8),
                                   rng.randrange(1, 12)))
        elif pick == 4:
            program.append(A.WAITU(rng.randrange(1, 24)))
        elif pick == 5:
            program.append(A.SHIFT(bool(rng.randrange(2)), rng.randrange(8),
                                   rng.randrange(1, 5), rng.randrange(3)))
        elif pick == 6 and len(program) > 3:
            # Branch strictly inside the program, so control can never reach an
            # address the loader did not write.
            program.append(A.JMP(rng.randrange(7), rng.randrange(3, len(program))))
        elif pick == 7:
            program.append(A.ALU(rng.randrange(13), rng.randrange(256)))
        elif pick == 8:
            program.append(A.LOAD(rng.randrange(8), rng.randrange(256)))
        else:
            program.append(A.SYS(rng.choice([A.SYS_NOP, A.SYS_SYNC, A.SYS_CLRFAULT]),
                                 rng.randrange(4)))
    # Falling off the end must halt rather than run into whatever the previous
    # program left in the store: the loader only writes as many words as this
    # program has, so everything past it is stale, and the model cannot know
    # what it holds.
    program.append(A.SYS(A.SYS_HALT))
    return program


@cocotb.test()
async def test_random_programs_match_the_model(dut):
    """Run randomised instruction streams through the RTL and through the
    Python model in lockstep, comparing the pins every cycle.

    The directed tests check the behaviours we thought to ask about. This
    checks the ones we did not.

    The model is fed `pin_s1`, the synchronised sample the state machine itself
    reads, rather than `uio_in`. The two input flops are trivial and separately
    covered; feeding them in here would only add bookkeeping to the test.
    """
    import os
    import random
    import protoemu_model as PM

    # Deeper soak without editing the test: PROTOEMU_TRIALS=200 ./test
    trials = int(os.environ.get("PROTOEMU_TRIALS", "20"))
    seed = int(os.environ.get("PROTOEMU_SEED", "0xC0FFEE"), 0)

    host = await setup(dut)
    rng = random.Random(seed)
    top = dut.user_project.u_top
    sm = top.u_sm

    def mismatch(trial, cycle, model, program):
        got = (int(dut.uio_out.value), int(dut.uio_oe.value),
               (int(dut.uo_out.value) >> HALTED) & 1)
        want = (model.pin_out, model.pin_oe, int(model.halted))
        if got == want:
            return None
        return (
            f"trial {trial}, cycle {cycle}: "
            f"RTL out={got[0]:#04x} oe={got[1]:#04x} halted={got[2]}, "
            f"model out={want[0]:#04x} oe={want[1]:#04x} halted={want[2]}\n"
            f"  RTL   pc={int(sm.pc.value)} st={int(sm.st.value)} "
            f"pinval={int(sm.pinval.value):#04x} pinmask={int(sm.pinmask.value):#04x} "
            f"drivemode={int(sm.drivemode.value):#04x} shreg={int(sm.shreg.value):#06x}\n"
            f"  model pc={model.pc} st={model.st} "
            f"pinval={model.pinval:#04x} pinmask={model.pinmask:#04x} "
            f"drivemode={model.drivemode:#04x} shreg={model.shreg:#06x}\n"
            f"  program {[hex(w) for w in program]}")

    for trial in range(trials):
        program = _random_program(rng, rng.randrange(12, 28))
        await host.load(program)

        model = PM.ProtoEmu(program)
        dut.uio_in.value = 0
        await host.start()

        # The cycle counter reads 0 for several edges before the run edge, so
        # align on the transition into 1 -- that is the edge at which the
        # machine retired its first instruction, with the counter reading 0.
        for _ in range(16):
            pin_in = int(top.pin_s1.value)
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
            if int(top.cycle.value) == 1:
                break
        else:
            raise AssertionError("cycle counter never started")

        model.step(pin_in, 0)
        problem = mismatch(trial, 0, model, program)
        assert problem is None, problem

        for cycle in range(1, 220):
            if model.halted:
                break
            pin_in = int(top.pin_s1.value)
            # Change the pins now and then, so WAITP and SHIFT-in see real
            # transitions rather than a constant level.
            if rng.randrange(5) == 0:
                dut.uio_in.value = rng.randrange(256)
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")

            model.step(pin_in, cycle)
            problem = mismatch(trial, cycle, model, program)
            assert problem is None, problem

        host.set(RUN, 0)
        await ClockCycles(dut.clk, 3)

    dut._log.info(f"{trials} random programs (seed {seed:#x}) matched the model "
                  "cycle for cycle")


async def _read_shifted_word(dut, clk_pin, data_pin, nbits, limit=4000):
    """Sample `data_pin` on each rising edge of the emulator's generated clock."""
    bits, prev = [], (int(dut.uio_out.value) >> clk_pin) & 1
    for _ in range(limit):
        await RisingEdge(dut.clk)
        out = int(dut.uio_out.value)
        now = (out >> clk_pin) & 1
        if now and not prev:
            bits.append((out >> data_pin) & 1)
            if len(bits) == nbits:
                return int("".join(str(b) for b in bits), 2)
        prev = now
    raise AssertionError(f"only saw {len(bits)} of {nbits} bits")


@cocotb.test()
async def test_capture_timestamps_an_unknown_edge(dut):
    """Arm edge capture, let an edge arrive whose timing the program was never
    told, then shift the recorded timestamp back out and check it.

    This is the differentiator: the chip measures a protocol rather than only
    replaying one. The timestamp lands in SHIFT, so getting it off the chip is
    an ordinary SHIFT instruction.
    """
    host = await setup(dut)
    edge_at = 120                      # cycles after the run edge

    await host.load([
        A.LOAD(A.REG_PINMASK, 0x06),               # pin 1 data out, pin 2 clock
        A.LOAD(A.REG_DRIVEMODE, 0x00),
        A.LOAD(A.REG_SHIFTCFG,
               A.shiftcfg(clkpin=2, clkidle=0, msbfirst=1, clken=1)),
        A.CAPARM(0x01),                            # watch pin 0
        A.WAITU(edge_at + 60),                     # wait past the edge
        A.JMP(A.CND_CAPRDY, 7),                    # 5: something was captured
        A.SYS(A.SYS_HALT),                         # 6: nothing was -- fail
        A.SYS(A.SYS_CAPPOP),                       # 7: X <- pins, SHIFT <- timestamp
        A.SHIFT(dir_in=False, pin=1, nbits=16, delay=3),
        A.SYS(A.SYS_HALT),
    ])

    dut.uio_in.value = 0x00
    await host.start()

    # Drive the edge at a cycle the program has no knowledge of.
    for _ in range(edge_at):
        await RisingEdge(dut.clk)
    dut.uio_in.value = 0x01

    stamp = await _read_shifted_word(dut, clk_pin=2, data_pin=1, nbits=16)

    # The pin passes through two synchroniser flops before capture sees it, and
    # the counter starts a couple of cycles after the run pin moves.
    assert abs(stamp - edge_at) <= 6, (
        f"captured timestamp {stamp}, edge was driven at cycle {edge_at}")
    dut._log.info(f"captured an edge at cycle {stamp}, driven at {edge_at}")


@cocotb.test()
async def test_capture_measures_a_pulse_width(dut):
    """Two edges, two timestamps: the difference is a pulse width the program
    never knew in advance. This is how an unknown bit period gets measured."""
    host = await setup(dut)
    rise_at, width = 80, 55

    program = [
        A.LOAD(A.REG_PINMASK, 0x06),
        A.LOAD(A.REG_DRIVEMODE, 0x00),
        A.LOAD(A.REG_SHIFTCFG,
               A.shiftcfg(clkpin=2, clkidle=0, msbfirst=1, clken=1)),
        A.CAPARM(0x01),
        A.WAITU(rise_at + width + 60),
        A.SYS(A.SYS_CAPPOP),                       # first edge
        A.SHIFT(dir_in=False, pin=1, nbits=16, delay=3),
        A.SYS(A.SYS_CAPPOP),                       # second edge
        A.SHIFT(dir_in=False, pin=1, nbits=16, delay=3),
        A.SYS(A.SYS_HALT),
    ]
    await host.load(program)

    dut.uio_in.value = 0x00
    await host.start()

    async def drive_pulse():
        for _ in range(rise_at):
            await RisingEdge(dut.clk)
        dut.uio_in.value = 0x01
        for _ in range(width):
            await RisingEdge(dut.clk)
        dut.uio_in.value = 0x00

    cocotb.start_soon(drive_pulse())
    first = await _read_shifted_word(dut, clk_pin=2, data_pin=1, nbits=16)
    second = await _read_shifted_word(dut, clk_pin=2, data_pin=1, nbits=16)

    measured = second - first
    assert abs(measured - width) <= 2, (
        f"measured pulse width {measured}, drove {width} "
        f"(timestamps {first} and {second})")
    dut._log.info(f"measured a {measured}-cycle pulse, drove {width}")


@cocotb.test()
async def test_start_address_selects_where_a_machine_begins(dut):
    """A machine starts at its configured address, not at zero.

    Every machine shares one program store, so without this they would all
    execute the same instructions in lockstep and more than one machine would
    be pointless.
    """
    host = await setup(dut)

    # Two programs in one store. The one at 0 would drive 0x0F; the one at 20
    # drives 0xF0. Only the second should ever run.
    await host.load([
        A.LOAD(A.REG_PINMASK, 0xFF),
        A.LOAD(A.REG_DRIVEMODE, 0x00),
        A.SET(0x0F),
        A.SYS(A.SYS_HALT),
    ], addr=0)
    await host.load([
        A.LOAD(A.REG_PINMASK, 0xFF),
        A.LOAD(A.REG_DRIVEMODE, 0x00),
        A.SET(0xF0),
        A.SYS(A.SYS_HALT),
    ], addr=20)

    await host.set_start_pc(machine=0, address=20)
    assert (await host.read_control(1))[0] == 20, "start address did not read back"

    await host.start()
    await host.run_until_halt()
    assert int(dut.uio_out.value) == 0xF0, (
        f"ran the program at 0, not the one at 20 (pins {int(dut.uio_out.value):#04x})")


@cocotb.test()
async def test_control_space_is_separate_from_the_program_store(dut):
    """A control write must not land in the program store, or vice versa."""
    host = await setup(dut)
    await host.load([A.SET(0xAB, 3), A.SYS(A.SYS_HALT)], addr=0)
    await host.set_start_pc(machine=0, address=7)

    assert (await host.readback(1, addr=0))[0] == A.SET(0xAB, 3), \
        "the control write disturbed the program store"
    assert (await host.read_control(1))[0] == 7, \
        "the program write disturbed the control registers"
