"""Assembler for the protocol emulator ISA.

Mirrors src/protoemu_isa.vh. Keep the two in step -- test_isa_header_matches()
in test.py checks that every constant here has the same value there, so a
divergence fails the test run rather than silently producing wrong programs.
"""

# opcodes
OP_SET, OP_WAITP, OP_WAITU, OP_SHIFT, OP_JMP, OP_ALU, OP_LOAD, OP_SYS = range(8)

# WAITP modes
WP_LOW, WP_HIGH, WP_RISE, WP_FALL = range(4)

# JMP conditions
(CND_ALWAYS, CND_XNZ, CND_YNZ, CND_XZ, CND_YZ, CND_FAULT, CND_NFAULT,
 CND_CAPRDY) = range(8)

# ALU functions
(ALU_XINC, ALU_XDEC, ALU_YINC, ALU_YDEC, ALU_XMOVY, ALU_YMOVX,
 ALU_XGETS, ALU_SPUTX, ALU_XADDI, ALU_XANDI, ALU_XORI, ALU_XXORI,
 ALU_PINX) = range(13)

# LOAD destinations
(REG_PINMASK, REG_DRIVEMODE, REG_X, REG_Y,
 REG_TGTLO, REG_TGTHI, REG_SHIFTCFG, REG_SHIFTDAT) = range(8)

# SYS functions
(SYS_NOP, SYS_HALT, SYS_IRQ, SYS_SYNC, SYS_CLRFAULT,
 SYS_CAPARM, SYS_CAPPOP, SYS_BARRIER) = range(8)

BAR_W = 4

PC_W = 7
IMEM_DEPTH = 1 << PC_W


def _fit(name, value, bits):
    if not 0 <= value < (1 << bits):
        raise ValueError(f"{name}={value} does not fit in {bits} bits")
    return value


def SET(value, delay=0):
    """Drive the masked pins with `value`, then stall `delay` extra cycles."""
    return (OP_SET << 13) | (_fit("value", value, 8) << 5) | _fit("delay", delay, 5)


def WAITP(mode, pin, timeout=0):
    """Wait for a pin condition. timeout=0 waits forever; otherwise a timeout
    raises the fault flag instead of hanging."""
    return ((OP_WAITP << 13) | (_fit("mode", mode, 2) << 11)
            | (_fit("pin", pin, 3) << 8) | _fit("timeout", timeout, 8))


def WAITU(delta):
    """TGT += delta, then wait until the cycle counter reaches TGT."""
    return (OP_WAITU << 13) | _fit("delta", delta, 13)


def SHIFT(dir_in, pin, nbits, delay=0):
    """Move nbits between the shift register and `pin`. nbits=16 encodes as 0."""
    if not 1 <= nbits <= 16:
        raise ValueError(f"nbits={nbits} must be 1..16")
    return ((OP_SHIFT << 13) | ((1 if dir_in else 0) << 12) | (_fit("pin", pin, 3) << 9)
            | ((nbits & 0xF) << 5) | _fit("delay", delay, 5))


def JMP(cond, addr):
    return (OP_JMP << 13) | (_fit("cond", cond, 3) << 10) | _fit("addr", addr, PC_W)


def ALU(fn, imm=0):
    return (OP_ALU << 13) | (_fit("fn", fn, 4) << 9) | _fit("imm", imm, 9)


def LOAD(reg, imm):
    return (OP_LOAD << 13) | (_fit("reg", reg, 3) << 10) | _fit("imm", imm, 10)


def SYS(fn, arg=0):
    return (OP_SYS << 13) | (_fit("fn", fn, 3) << 10) | _fit("arg", arg, 10)


def CAPARM(mask):
    """Arm edge capture on the pins in `mask`, discarding anything captured
    before. SYS CAPPOP then reads entries out, oldest first."""
    return SYS(SYS_CAPARM, _fit("mask", mask, 8))


def BARRIER(machines):
    """Stop until every machine in `machines` is also stopped at a barrier.

    All of them leave on the same cycle, which is what lets a transmitter and a
    receiver on separate machines start a transfer on the same edge. A halted
    machine counts as arrived, so finishing early does not wedge the rest.
    """
    return SYS(SYS_BARRIER, _fit("machines", machines, BAR_W))


def shiftcfg(clkpin=0, clkidle=0, msbfirst=1, clken=0):
    """Pack the SHIFTCFG immediate."""
    return ((clkpin & 7) | (clkidle << 3) | (msbfirst << 4) | (clken << 5))


def assemble(program):
    """Check a program fits the store and return it as a list of words."""
    if len(program) > IMEM_DEPTH:
        raise ValueError(f"program is {len(program)} words, store holds {IMEM_DEPTH}")
    return list(program)
