"""A cycle-accurate Python model of the protocol engine.

Written from the RTL and deliberately mirroring its structure: one `step()` is
one clock with `advance` asserted, every read takes the pre-state, and the state
variables have the same names as the registers. That makes a mismatch easy to
localise -- the differing field names the register.

`Machine` is src/protoemu_sm.v. `ProtoEmu` is the chip around it: the shared
program store and cycle counter, the pin arbitration of src/protoemu_arb.v, the
rendezvous of src/protoemu_barrier.v, and the one capture record of
src/protoemu_capture.v with a cursor per machine. Everything shared lives on the
chip rather than on a machine, which is what makes the model say something at
more than one machine.

Within a step the machines are stepped from a snapshot of the pre-state -- the
barrier release, the capture cursors and the pins a machine reads are all
computed before any machine moves -- because that is what a clock edge does.

test_random_programs_match_the_model() runs randomised instruction streams
through both this and the RTL and compares the pins every cycle.
"""

import protoemu_asm as A

NPIN = 8
MASK8 = 0xFF
MASK16 = 0xFFFF

ST_EXEC, ST_DELAY, ST_WAITP, ST_WAITU, ST_SHIFT, ST_HALT, ST_BAR = range(7)


def _bit(value, index):
    return (value >> index) & 1


def _set_bit(value, index, bit):
    return (value | (1 << index)) if bit else (value & ~(1 << index))


class Machine:
    """One protocol state machine: src/protoemu_sm.v."""

    def __init__(self, index=0, start_pc=0):
        self.index = index
        self.reset(start_pc)

    def reset(self, start_pc=0):
        self.st = ST_EXEC
        self.pc = start_pc
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
        self.bar_mask = 0
        # capture: the record is the chip's, only the cursor is the machine's
        self.cap_rd = 0
        self.cap_pop_reg = 0      # the registered strobe, high the cycle after
        self.next_cap_pop = 0

    # ------------------------------------------------------------ outputs --
    # What this machine *asks* for. The chip decides what reaches the pad --
    # src/protoemu_arb.v gates each request with the machine's ownership of the
    # pin, so an unowned pin is released and quiet however hard a non-owner
    # drives it.
    @property
    def req_out(self):
        out = 0
        for i in range(NPIN):
            out = _set_bit(out, i, 0 if _bit(self.drivemode, i) else _bit(self.pinval, i))
        return out

    @property
    def req_oe(self):
        oe = 0
        for i in range(NPIN):
            drive = _bit(self.pinmask, i) and (
                (not _bit(self.pinval, i)) if _bit(self.drivemode, i) else 1)
            oe = _set_bit(oe, i, drive)
        return oe

    @property
    def halted(self):
        return self.st == ST_HALT

    @property
    def at_barrier(self):
        return self.st == ST_BAR

    def state(self):
        """A dict for reporting the first differing field on a mismatch."""
        return dict(vars(self))

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
            A.CND_CAPRDY: self.cap_head is not None,
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
    def step(self, chip, pin_in, cycle, bar_go, cap_head):
        """One clock with `advance` asserted.

        `pin_in` is the synchronised pin sample the RTL sees and `cycle` the
        shared counter's value. `bar_go` and `cap_head` are the chip's, computed
        from the pre-state before any machine moved -- they are combinational in
        the RTL, so they must not see this cycle's changes.
        """
        self.chip = chip
        self.cap_head = cap_head
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
        elif self.st == ST_BAR:
            if bar_go:
                self.st = ST_EXEC
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
        instr = self.chip.imem[self.pc] & MASK16
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
                # The strobe is registered in the RTL, so the capture block acts
                # on it next cycle. Arming from any machine but 0 is dropped.
                if self.index == 0:
                    self.chip.next_cap_arm = arg & MASK8
            elif fn == A.SYS_BARRIER:
                self.bar_mask = arg & ((1 << A.BAR_W) - 1)
                self.st = ST_BAR
            elif fn == A.SYS_CAPPOP and self.cap_head is not None:
                # The entry is read now; `cap_pop` is registered, so the cursor
                # does not move until the end of the *next* cycle -- which means
                # a second CAPPOP right behind this one reads the same entry,
                # exactly as the RTL does.
                pins, stamp = self.cap_head
                self.next_cap_pop = 1
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


class ProtoEmu:
    """The chip: a shared program store, the machines, and everything between.

    `nsm` machines fetch from one store, share the eight pins through the
    arbiter, meet at barriers, and read one capture record through a cursor
    each. With `nsm` at 1 this is the design as built; the parameter is what
    lets the randomised comparison keep meaning something once it is 4.
    """

    CAP_DEPTH = 16

    def __init__(self, program, nsm=1, start_pc=None):
        self.imem = list(program) + [0] * (A.IMEM_DEPTH - len(program))
        self.nsm = nsm
        self.start_pc = list(start_pc) if start_pc else [0] * nsm
        self.machines = [Machine(i, self.start_pc[i]) for i in range(nsm)]
        self.reset()

    def reset(self):
        for i, m in enumerate(self.machines):
            m.reset(self.start_pc[i])
        self.cap_record = []
        self.cap_armed = False
        self.cap_mask = 0
        self.cap_prev = 0
        self.cap_overflow = 0
        self.cap_arm_reg = None
        self.next_cap_arm = None

    # ------------------------------------------------------------ outputs --
    def _arbitrate(self):
        """src/protoemu_arb.v: lowest claimant owns the pin, and only it."""
        out = oe = conflict = taken = 0
        for m in self.machines:
            own = m.pinmask & ~taken
            out |= own & m.req_out
            oe |= own & m.req_oe
            conflict |= m.pinmask & taken
            taken |= m.pinmask
        return out, oe, conflict

    @property
    def pin_out(self):
        return self._arbitrate()[0]

    @property
    def pin_oe(self):
        return self._arbitrate()[1]

    @property
    def conflict(self):
        return self._arbitrate()[2]

    @property
    def halted(self):
        """The chip is done when the last machine is."""
        return all(m.halted for m in self.machines)

    @property
    def irq(self):
        return int(any(m.irq for m in self.machines))

    # ------------------------------------------------------------- barrier --
    def _barrier_go(self):
        """src/protoemu_barrier.v, including the halted-counts-as-arrived rule
        that stops one machine finishing early from wedging the rest."""
        built = (1 << self.nsm) - 1
        arrived = 0
        for i, m in enumerate(self.machines):
            if m.at_barrier or m.halted:
                arrived |= 1 << i
        go = []
        for m in self.machines:
            want = m.bar_mask & built
            go.append(m.at_barrier and (arrived & want) == want)
        return go

    # ---------------------------------------------------------------- step --
    def step(self, pin_in, cycle):
        """One clock with `advance` asserted, for every machine at once.

        `cap_arm` and `cap_pop` are registered in src/protoemu_sm.v, so the
        strobe a machine raises is high during the *following* cycle and the
        capture block acts on it at the end of that one. Everything a machine
        reads this cycle -- the entry at its cursor, whether one is ready --
        therefore still sees the state from before. Getting this wrong makes
        `JMP CAPRDY` branch a cycle early, which a 400-program soak found.
        """
        arm_now = self.cap_arm_reg
        pop_now = [m.cap_pop_reg for m in self.machines]
        self.cap_arm_reg = self.next_cap_arm
        self.next_cap_arm = None
        for m in self.machines:
            m.cap_pop_reg = m.next_cap_pop
            m.next_cap_pop = 0

        # everything combinational, from the pre-state
        bar_go = self._barrier_go()
        ready = [m.cap_rd < len(self.cap_record) for m in self.machines]
        heads = [self.cap_record[m.cap_rd] if r else None
                 for m, r in zip(self.machines, ready)]

        for m, go, head in zip(self.machines, bar_go, heads):
            m.step(self, pin_in, cycle, go, head)

        # the capture block's own registers, which all land on this edge
        if arm_now is not None:
            self.cap_mask = arm_now
            self.cap_armed = bool(arm_now)
            self.cap_record = []
            self.cap_overflow = 0
            for m in self.machines:
                m.cap_rd = 0
        elif self.cap_armed and ((pin_in ^ self.cap_prev) & self.cap_mask):
            # Reading does not make room -- the window holds the first
            # CAP_DEPTH edges after each arm, because with a cursor per
            # machine there is no coherent oldest-unread entry to retire.
            if len(self.cap_record) >= self.CAP_DEPTH:
                self.cap_overflow = 1
            else:
                self.cap_record.append((pin_in, cycle & MASK16))
        self.cap_prev = pin_in

        if arm_now is None:
            for m, p, r in zip(self.machines, pop_now, ready):
                if p and r:
                    m.cap_rd += 1
