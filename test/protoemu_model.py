"""A cycle-accurate Python model of the protocol engine.

Written from src/protoemu_sm.v, and deliberately mirroring its structure:
one `step()` is one clock with `advance` asserted, every read takes the
pre-state, and the state variables have the same names as the registers. That
makes a mismatch easy to localise -- the differing field names the register.

test_random_programs_match_the_model() runs randomised instruction streams
through both this and the RTL and compares the pins every cycle.
"""

import protoemu_asm as A

NPIN = 8
MASK8 = 0xFF
MASK16 = 0xFFFF

ST_EXEC, ST_DELAY, ST_WAITP, ST_WAITU, ST_SHIFT, ST_HALT = range(6)


def _bit(value, index):
    return (value >> index) & 1


def _set_bit(value, index, bit):
    return (value | (1 << index)) if bit else (value & ~(1 << index))


class ProtoEmu:
    """One protocol state machine."""

    def __init__(self, program):
        self.imem = list(program) + [0] * (A.IMEM_DEPTH - len(program))
        self.reset()

    def reset(self):
        self.st = ST_EXEC
        self.pc = 0
        self.x = self.y = 0
        self.shreg = 0
        self.delay_cnt = 0
        self.tgt = 0
        self.pinmask = self.drivemode = self.pinval = 0
        self.fault = 0
        self.irq = 0
        self.wp_mode = self.wp_pin = self.wp_timeout = self.wp_prev = 0
        self.sh_dir = self.sh_pin = self.sh_idx = 0
        self.sh_left = self.sh_delay = self.sh_cnt = self.sh_phase = 0
        self.cfg_clkpin = 0
        self.cfg_clkidle = 0
        self.cfg_msbfirst = 1
        self.cfg_clken = 0
        # capture
        self.cap_fifo = []
        self.cap_armed = False
        self.cap_mask = 0
        self.cap_prev = 0
        self.cap_overflow = 0

    # ------------------------------------------------------------ outputs --
    @property
    def pin_out(self):
        """What reaches the pad, after arbitration.

        A pin this machine does not claim reads 0 rather than whatever PINVAL
        happens to hold: src/protoemu_arb.v gates each machine's request with
        its ownership of the pin, so an unowned pin is released *and* quiet.
        """
        out = 0
        for i in range(NPIN):
            if not _bit(self.pinmask, i):
                continue
            out = _set_bit(out, i, 0 if _bit(self.drivemode, i) else _bit(self.pinval, i))
        return out

    @property
    def pin_oe(self):
        oe = 0
        for i in range(NPIN):
            drive = _bit(self.pinmask, i) and (
                (not _bit(self.pinval, i)) if _bit(self.drivemode, i) else 1)
            oe = _set_bit(oe, i, drive)
        return oe

    @property
    def halted(self):
        return self.st == ST_HALT

    def state(self):
        """A dict for reporting the first differing field on a mismatch."""
        return {k: v for k, v in vars(self).items() if k != "imem"}

    # ------------------------------------------------------------- helpers --
    def _sh_idx_first(self, nbits):
        return (nbits - 1) & 0xF if self.cfg_msbfirst else 0

    def _sh_idx_next(self):
        return ((self.sh_idx - 1) & 0xF) if self.cfg_msbfirst else ((self.sh_idx + 1) & 0xF)

    def _branch_taken(self, cond):
        return {
            A.CND_ALWAYS: True,
            A.CND_XNZ:    self.x != 0,
            A.CND_YNZ:    self.y != 0,
            A.CND_XZ:     self.x == 0,
            A.CND_YZ:     self.y == 0,
            A.CND_FAULT:  bool(self.fault),
            A.CND_NFAULT: not self.fault,
            A.CND_CAPRDY: bool(self.cap_fifo),
        }.get(cond, False)

    def _wp_hit(self, now):
        if self.wp_mode == A.WP_LOW:
            return not now
        if self.wp_mode == A.WP_HIGH:
            return bool(now)
        if self.wp_mode == A.WP_RISE:
            return bool(now and not self.wp_prev)
        return bool(self.wp_prev and not now)     # WP_FALL

    # ---------------------------------------------------------------- step --
    CAP_DEPTH = 16

    def capture_tick(self, pin_in, cycle):
        """Edge capture runs off the clock, not off instruction execution, so
        the testbench calls this every cycle regardless of `advance`."""
        if self.cap_armed:
            if (pin_in ^ self.cap_prev) & self.cap_mask:
                if len(self.cap_fifo) >= self.CAP_DEPTH:
                    self.cap_overflow = 1
                else:
                    self.cap_fifo.append((pin_in, cycle & MASK16))
        self.cap_prev = pin_in

    def step(self, pin_in, cycle):
        """One clock with `advance` asserted. `pin_in` is the synchronised pin
        sample the RTL sees, `cycle` the shared counter's current value."""
        self.irq = 0
        if self.st == ST_EXEC:
            self._exec(pin_in, cycle)
        elif self.st == ST_DELAY:
            if self.delay_cnt == 1:
                self.st = ST_EXEC
            self.delay_cnt = (self.delay_cnt - 1) & 0x1F
        elif self.st == ST_WAITP:
            self._wait_pin(pin_in)
        elif self.st == ST_WAITU:
            # signed 16-bit difference: released once the counter reaches or
            # passes the target, so a missed deadline does not stall for a wrap
            delta = (cycle - self.tgt) & MASK16
            if delta < 0x8000:
                self.st = ST_EXEC
        elif self.st == ST_SHIFT:
            self._shift(pin_in)
        # ST_HALT and anything unreachable: hold

    def _wait_pin(self, pin_in):
        now = _bit(pin_in, self.wp_pin)
        hit = self._wp_hit(now)
        self.wp_prev = now
        if hit:
            self.st = ST_EXEC
        elif self.wp_timeout != 0:
            if self.wp_timeout == 1:
                self.fault = 1
                self.st = ST_EXEC
            self.wp_timeout -= 1

    def _shift(self, pin_in):
        if self.sh_cnt != 0:
            self.sh_cnt -= 1
            return
        self.sh_cnt = self.sh_delay
        if not self.sh_phase:
            self.sh_phase = 1
            if self.cfg_clken:
                self.pinval = _set_bit(self.pinval, self.cfg_clkpin, not self.cfg_clkidle)
            if self.sh_dir:
                self.shreg = _set_bit(self.shreg, self.sh_idx, _bit(pin_in, self.sh_pin))
        else:
            self.sh_phase = 0
            if self.cfg_clken:
                self.pinval = _set_bit(self.pinval, self.cfg_clkpin, self.cfg_clkidle)
            nxt = self._sh_idx_next()
            if self.sh_left == 1:
                self.st = ST_EXEC
            elif not self.sh_dir:
                self.pinval = _set_bit(self.pinval, self.sh_pin, _bit(self.shreg, nxt))
            self.sh_left -= 1
            self.sh_idx = nxt

    def _exec(self, pin_in, cycle):
        instr = self.imem[self.pc] & MASK16
        op = instr >> 13
        self.pc = (self.pc + 1) & (A.IMEM_DEPTH - 1)

        if op == A.OP_SET:
            value, delay = (instr >> 5) & MASK8, instr & 0x1F
            for i in range(NPIN):
                if _bit(self.pinmask, i):
                    self.pinval = _set_bit(self.pinval, i, _bit(value, i))
            if delay != 0:
                self.delay_cnt = delay
                self.st = ST_DELAY

        elif op == A.OP_WAITP:
            self.wp_mode = (instr >> 11) & 0x3
            self.wp_pin = (instr >> 8) & 0x7
            self.wp_timeout = instr & MASK8
            self.wp_prev = _bit(pin_in, self.wp_pin)
            self.st = ST_WAITP

        elif op == A.OP_WAITU:
            self.tgt = (self.tgt + (instr & 0x1FFF)) & MASK16
            self.st = ST_WAITU

        elif op == A.OP_SHIFT:
            nbits = (instr >> 5) & 0xF
            bits = 16 if nbits == 0 else nbits
            self.sh_dir = (instr >> 12) & 1
            self.sh_pin = (instr >> 9) & 0x7
            self.sh_left = bits
            self.sh_idx = self._sh_idx_first(bits)
            self.sh_delay = self.sh_cnt = instr & 0x1F
            self.sh_phase = 0
            if self.cfg_clken:
                self.pinval = _set_bit(self.pinval, self.cfg_clkpin, self.cfg_clkidle)
            if not self.sh_dir:
                self.pinval = _set_bit(self.pinval, self.sh_pin,
                                       _bit(self.shreg, self.sh_idx))
            self.st = ST_SHIFT

        elif op == A.OP_JMP:
            cond = (instr >> 10) & 0x7
            if self._branch_taken(cond):
                self.pc = instr & (A.IMEM_DEPTH - 1)
            if cond == A.CND_XNZ and self.x != 0:
                self.x = (self.x - 1) & MASK8
            if cond == A.CND_YNZ and self.y != 0:
                self.y = (self.y - 1) & MASK8
            if cond == A.CND_FAULT and self.fault:
                self.fault = 0

        elif op == A.OP_ALU:
            self._alu((instr >> 9) & 0xF, instr & 0x1FF)

        elif op == A.OP_LOAD:
            self._load((instr >> 10) & 0x7, instr & 0x3FF)

        else:                                    # OP_SYS
            fn, arg = (instr >> 10) & 0x7, instr & 0x3FF
            if fn == A.SYS_HALT:
                self.st = ST_HALT
            elif fn == A.SYS_IRQ:
                self.irq = 1
                if arg & 1:
                    self.st = ST_HALT
            elif fn == A.SYS_SYNC:
                self.tgt = cycle & MASK16
            elif fn == A.SYS_CLRFAULT:
                self.fault = 0
            elif fn == A.SYS_CAPARM:
                self.cap_mask = arg & MASK8
                self.cap_armed = bool(self.cap_mask)
                self.cap_fifo = []
                self.cap_overflow = 0
                self.cap_prev = pin_in
            elif fn == A.SYS_CAPPOP and self.cap_fifo:
                pins, stamp = self.cap_fifo.pop(0)
                self.x = pins
                self.shreg = stamp

    def _alu(self, fn, imm):
        imm8 = imm & MASK8
        if fn == A.ALU_XINC:    self.x = (self.x + 1) & MASK8
        elif fn == A.ALU_XDEC:  self.x = (self.x - 1) & MASK8
        elif fn == A.ALU_YINC:  self.y = (self.y + 1) & MASK8
        elif fn == A.ALU_YDEC:  self.y = (self.y - 1) & MASK8
        elif fn == A.ALU_XMOVY: self.x = self.y
        elif fn == A.ALU_YMOVX: self.y = self.x
        elif fn == A.ALU_XGETS: self.x = self.shreg & MASK8
        elif fn == A.ALU_SPUTX: self.shreg = (self.shreg & 0xFF00) | self.x
        elif fn == A.ALU_XADDI: self.x = (self.x + imm8) & MASK8
        elif fn == A.ALU_XANDI: self.x &= imm8
        elif fn == A.ALU_XORI:  self.x |= imm8
        elif fn == A.ALU_XXORI: self.x ^= imm8
        elif fn == A.ALU_PINX:
            for i in range(NPIN):
                if _bit(self.pinmask, i):
                    self.pinval = _set_bit(self.pinval, i, _bit(self.x, i))

    def _load(self, reg, imm):
        if reg == A.REG_PINMASK:     self.pinmask = imm & MASK8
        elif reg == A.REG_DRIVEMODE: self.drivemode = imm & MASK8
        elif reg == A.REG_X:         self.x = imm & MASK8
        elif reg == A.REG_Y:         self.y = imm & MASK8
        elif reg == A.REG_TGTLO:     self.tgt = (self.tgt & 0xFC00) | (imm & 0x3FF)
        elif reg == A.REG_TGTHI:     self.tgt = (self.tgt & 0x03FF) | ((imm & 0x3F) << 10)
        elif reg == A.REG_SHIFTCFG:
            self.cfg_clkpin = imm & 0x7
            self.cfg_clkidle = _bit(imm, 3)
            self.cfg_msbfirst = _bit(imm, 4)
            self.cfg_clken = _bit(imm, 5)
        else:                        self.shreg = imm & MASK8
