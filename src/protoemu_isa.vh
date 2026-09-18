// Protocol emulator instruction encoding.
//
// One 16-bit instruction, opcode in [15:13]. Every field is fixed-position so
// the decoder is pure wiring -- no shifting, no variable extraction.
// See docs/architecture.md for the rationale behind each opcode.
`ifndef PROTOEMU_ISA_VH
`define PROTOEMU_ISA_VH

`define PE_IW      16   // instruction width
`define PE_PC_W     6   // 64-instruction program store
`define PE_NPIN     8   // protocol pins (uio[7:0])
`define PE_CYC_W   16   // free-running cycle counter / deadline width

// ---------------------------------------------------------------- opcodes --
// instr[15:13]
`define PE_OP_SET   3'b000  // value[7:0]=[12:5], delay[4:0]=[4:0]
`define PE_OP_WAITP 3'b001  // mode[1:0]=[12:11], pin[2:0]=[10:8], timeout[7:0]=[7:0]
`define PE_OP_WAITU 3'b010  // delta[12:0]=[12:0]
`define PE_OP_SHIFT 3'b011  // dir=[12], pin[2:0]=[11:9], nbits[3:0]=[8:5], delay[4:0]=[4:0]
`define PE_OP_JMP   3'b100  // cond[2:0]=[12:10], addr[6:0]=[6:0]
`define PE_OP_ALU   3'b101  // fn[3:0]=[12:9], imm[8:0]=[8:0]
`define PE_OP_LOAD  3'b110  // reg[2:0]=[12:10], imm[9:0]=[9:0]
`define PE_OP_SYS   3'b111  // fn[2:0]=[12:10], arg[9:0]=[9:0]

// ------------------------------------------------------------ WAITP modes --
// A timeout of 0 means "wait forever"; any other value arms the fault vector.
`define PE_WP_LOW   2'd0  // wait while pin is high
`define PE_WP_HIGH  2'd1  // wait while pin is low
`define PE_WP_RISE  2'd2  // wait for a 0->1 transition
`define PE_WP_FALL  2'd3  // wait for a 1->0 transition

// -------------------------------------------------------- JMP conditions ---
`define PE_CND_ALWAYS 3'd0
`define PE_CND_XNZ    3'd1  // X != 0, post-decrement X
`define PE_CND_YNZ    3'd2  // Y != 0, post-decrement Y
`define PE_CND_XZ     3'd3  // X == 0
`define PE_CND_YZ     3'd4  // Y == 0
`define PE_CND_FAULT  3'd5  // a WAITP timeout is pending; taking the branch clears it
`define PE_CND_NFAULT 3'd6  // no fault pending
`define PE_CND_CAPRDY 3'd7  // the capture FIFO has an entry waiting

// --------------------------------------------------------- ALU functions ---
`define PE_ALU_XINC  4'd0
`define PE_ALU_XDEC  4'd1
`define PE_ALU_YINC  4'd2
`define PE_ALU_YDEC  4'd3
`define PE_ALU_XMOVY 4'd4   // X <- Y
`define PE_ALU_YMOVX 4'd5   // Y <- X
`define PE_ALU_XGETS 4'd6   // X <- SHIFT[7:0]
`define PE_ALU_SPUTX 4'd7   // SHIFT[7:0] <- X
`define PE_ALU_XADDI 4'd8   // X <- X + imm[7:0]
`define PE_ALU_XANDI 4'd9
`define PE_ALU_XORI  4'd10
`define PE_ALU_XXORI 4'd11
`define PE_ALU_PINX  4'd12  // drive the masked pins from X

// ------------------------------------------------------ LOAD destinations --
`define PE_REG_PINMASK   3'd0  // which pins this machine may drive
`define PE_REG_DRIVEMODE 3'd1  // 1 = open-drain, 0 = push-pull, per pin
`define PE_REG_X         3'd2
`define PE_REG_Y         3'd3
`define PE_REG_TGTLO     3'd4  // TGT[9:0]   <- imm[9:0]
`define PE_REG_TGTHI     3'd5  // TGT[15:10] <- imm[5:0]
`define PE_REG_SHIFTCFG  3'd6  // clkpin[2:0]=[2:0], clkidle=[3], msbfirst=[4], clken=[5]
`define PE_REG_SHIFTDAT  3'd7  // SHIFT <- {8'b0, imm[7:0]}

// --------------------------------------------------------- SYS functions ---
`define PE_SYS_NOP      3'd0
`define PE_SYS_HALT     3'd1
`define PE_SYS_IRQ      3'd2  // pulse irq; arg[0] also halts
`define PE_SYS_SYNC     3'd3  // TGT <- CYCLE, re-anchoring the deadline to now
`define PE_SYS_CLRFAULT 3'd4
`define PE_SYS_CAPARM   3'd5  // arm edge capture; arg[7:0] selects the pins
`define PE_SYS_CAPPOP   3'd6  // X <- captured pin state, SHIFT <- its timestamp
`define PE_SYS_BARRIER  3'd7  // wait until every machine in arg[3:0] is here too

// ------------------------------------------------------------- barrier ----
// Width of the participant mask in a SYS BARRIER. Fixed by the encoding, not
// by PE_NSM, so a program assembled for four machines still decodes on one.
`define PE_BAR_W        4

// ------------------------------------------------------------- capture ----
`define PE_NSM          4     // state machines sharing the store and pins

// ----------------------------------------------------- control registers --
// Written over SPI with the control bit set in the frame header.
`define PE_CTL_STARTPC   8'd0  // 0 .. PE_NSM-1: each machine's start address
`define PE_CTL_CONFLICT  8'd8  // read: pins claimed by more than one machine
                               // write: 1 clears that bit
`define PE_CTL_CAPARM    8'd9  // read: machines that tried to arm capture
                               // without owning it; write: 1 clears that bit

`define PE_CAP_DEPTH_W  4     // 16 entries of {pins[7:0], timestamp[15:0]}

`endif
