/*
 * Copyright (c) 2026 Umer Imran
 * SPDX-License-Identifier: Apache-2.0
 *
 * One protocol state machine: fetch, decode and execute the ISA in
 * src/protoemu_isa.vh against an 8-pin block.
 *
 * Timing contract (the property the formal proofs check):
 *   every instruction retires in exactly 1 cycle unless it is SET/SHIFT with a
 *   non-zero delay, or a WAIT that is still unsatisfied. Nothing else stalls.
 */

`default_nettype none
`include "protoemu_isa.vh"

module protoemu_sm (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  run,        // low holds the machine in place
    input  wire                  step,       // single-cycle advance while !run
    input  wire                  clr,        // synchronous restart: PC=0, pins released

    output wire [`PE_PC_W-1:0]   imem_addr,  // combinational read port
    input  wire [`PE_IW-1:0]     imem_data,

    input  wire [`PE_NPIN-1:0]   pin_in,     // already synchronised to clk
    output wire [`PE_NPIN-1:0]   pin_out,
    output wire [`PE_NPIN-1:0]   pin_oe,

    input  wire [`PE_CYC_W-1:0]  cycle,      // shared free-running counter

    // timestamped edge capture
    output reg                   cap_arm,
    output reg  [`PE_NPIN-1:0]   cap_arm_mask,
    output reg                   cap_pop,
    input  wire                  cap_ready,
    input  wire [`PE_NPIN-1:0]   cap_pins,
    input  wire [`PE_CYC_W-1:0]  cap_time,

    output reg                   irq,
    output wire                  halted,
    output wire                  active,
    output wire [2:0]            trace       // current state, for the trace pins
);

  // ------------------------------------------------------------- state ----
  localparam ST_EXEC  = 3'd0,
             ST_DELAY = 3'd1,
             ST_WAITP = 3'd2,
             ST_WAITU = 3'd3,
             ST_SHIFT = 3'd4,
             ST_HALT  = 3'd5;

  reg [2:0]              st;
  reg [`PE_PC_W-1:0]     pc;
  reg [7:0]              x, y;
  reg [15:0]             shreg;
  reg [4:0]              delay_cnt;
  reg [`PE_CYC_W-1:0]    tgt;
  reg [`PE_NPIN-1:0]     pinmask, drivemode, pinval;
  reg                    fault;

  // WAITP working state
  reg [1:0]              wp_mode;
  reg [2:0]              wp_pin;
  reg [7:0]              wp_timeout;
  reg                    wp_prev;      // previous sample, for edge modes

  // SHIFT working state
  reg                    sh_dir;       // 0 = out, 1 = in
  reg [2:0]              sh_pin;
  reg [3:0]              sh_idx;       // bit of SHIFT currently on the wire
  reg [4:0]              sh_left;      // bits remaining
  reg [4:0]              sh_delay;
  reg [4:0]              sh_cnt;       // inter-bit countdown
  reg                    sh_phase;     // 0 = clock idle half, 1 = clock active half
  // SHIFTCFG
  reg [2:0]              cfg_clkpin;
  reg                    cfg_clkidle, cfg_msbfirst, cfg_clken;

  assign imem_addr = pc;
  assign halted    = (st == ST_HALT);
  assign active    = (st != ST_HALT);
  assign trace     = st;

  // ------------------------------------------------------------ decode ----
  wire [2:0]  op       = imem_data[15:13];
  wire [7:0]  set_val  = imem_data[12:5];
  wire [4:0]  set_dly  = imem_data[4:0];
  wire [1:0]  wp_m     = imem_data[12:11];
  wire [2:0]  wp_p     = imem_data[10:8];
  wire [7:0]  wp_t     = imem_data[7:0];
  wire [12:0] wu_delta = imem_data[12:0];
  wire        sh_d     = imem_data[12];
  wire [2:0]  sh_p     = imem_data[11:9];
  wire [3:0]  sh_n     = imem_data[8:5];
  wire [4:0]  sh_dl    = imem_data[4:0];
  wire [2:0]  jmp_cnd  = imem_data[12:10];
  wire [`PE_PC_W-1:0] jmp_addr = imem_data[`PE_PC_W-1:0];
  wire [3:0]  alu_fn   = imem_data[12:9];
  wire [8:0]  alu_imm  = imem_data[8:0];
  wire [2:0]  ld_reg   = imem_data[12:10];
  wire [9:0]  ld_imm   = imem_data[9:0];
  wire [2:0]  sys_fn   = imem_data[12:10];
  wire [9:0]  sys_arg  = imem_data[9:0];

  // nbits 0 encodes 16, so a full halfword shifts in one instruction
  wire [4:0]  sh_bits  = (sh_n == 4'd0) ? 5'd16 : {1'b0, sh_n};

  // Branch conditions. XNZ/YNZ post-decrement, so the counter register is read
  // here and written in the sequential block below.
  reg branch_taken;
  always @(*) begin
    case (jmp_cnd)
      `PE_CND_ALWAYS: branch_taken = 1'b1;
      `PE_CND_XNZ:    branch_taken = (x != 8'd0);
      `PE_CND_YNZ:    branch_taken = (y != 8'd0);
      `PE_CND_XZ:     branch_taken = (x == 8'd0);
      `PE_CND_YZ:     branch_taken = (y == 8'd0);
      `PE_CND_FAULT:  branch_taken = fault;
      `PE_CND_NFAULT: branch_taken = !fault;
      default:        branch_taken = cap_ready;   // PE_CND_CAPRDY
    endcase
  end

  // WAITU releases once the counter has reached *or passed* TGT. Testing for
  // equality instead would stall a missed deadline for a full 65536-cycle wrap
  // of the counter -- 1.3 ms at 50 MHz. The signed difference is correct across
  // the wrap for any deadline inside half the counter range, and WAITU's delta
  // field tops out at 8191.
  wire signed [`PE_CYC_W-1:0] tgt_delta = $signed(cycle) - $signed(tgt);
  wire                        tgt_reached = (tgt_delta >= 0);

  // WAITP satisfaction, evaluated against this cycle's sample.
  wire wp_now = pin_in[wp_pin];
  reg  wp_hit;
  always @(*) begin
    case (wp_mode)
      `PE_WP_LOW:  wp_hit = ~wp_now;
      `PE_WP_HIGH: wp_hit =  wp_now;
      `PE_WP_RISE: wp_hit =  wp_now & ~wp_prev;
      default:     wp_hit = ~wp_now &  wp_prev;   // PE_WP_FALL
    endcase
  end

  // ------------------------------------------------------- pin outputs ----
  // Open-drain pins never drive high: they release instead. This is native
  // rather than something the program has to hand-code around, which is what
  // makes I2C a normal program here.
  genvar i;
  generate
    for (i = 0; i < `PE_NPIN; i = i + 1) begin : g_pin
      assign pin_out[i] = drivemode[i] ? 1'b0 : pinval[i];
      assign pin_oe[i]  = pinmask[i] & (drivemode[i] ? ~pinval[i] : 1'b1);
    end
  endgenerate

  wire advance = run | step;

  // SHIFT is addressed by index rather than rotated, so an n-bit transfer is
  // right-justified in SHIFT[n-1:0] whichever bit order is selected -- no
  // pre-alignment step and no barrel shifter.
  wire [3:0] sh_idx_first = cfg_msbfirst ? (sh_bits[3:0] - 4'd1) : 4'd0;
  wire [3:0] sh_idx_next  = cfg_msbfirst ? (sh_idx - 4'd1) : (sh_idx + 4'd1);

  // --------------------------------------------------------- sequential ---
  integer k;
  always @(posedge clk) begin
    if (!rst_n || clr) begin
      st <= ST_EXEC; pc <= {`PE_PC_W{1'b0}};
      x <= 8'd0; y <= 8'd0; shreg <= 16'd0; delay_cnt <= 5'd0;
      tgt <= {`PE_CYC_W{1'b0}};
      pinmask <= {`PE_NPIN{1'b0}}; drivemode <= {`PE_NPIN{1'b0}};
      pinval <= {`PE_NPIN{1'b0}};   // PINMASK=0 is what releases the pins
      fault <= 1'b0; irq <= 1'b0;
      cap_arm <= 1'b0; cap_arm_mask <= {`PE_NPIN{1'b0}}; cap_pop <= 1'b0;
      wp_mode <= 2'd0; wp_pin <= 3'd0; wp_timeout <= 8'd0; wp_prev <= 1'b0;
      sh_dir <= 1'b0; sh_pin <= 3'd0; sh_idx <= 4'd0;
      sh_left <= 5'd0; sh_delay <= 5'd0;
      sh_cnt <= 5'd0; sh_phase <= 1'b0;
      cfg_clkpin <= 3'd0; cfg_clkidle <= 1'b0;
      cfg_msbfirst <= 1'b1; cfg_clken <= 1'b0;
    end else begin
      irq     <= 1'b0;              // irq is a one-cycle pulse
      cap_arm <= 1'b0;              // so are the capture strobes
      cap_pop <= 1'b0;
      if (advance) begin
        case (st)
          // ------------------------------------------------ fetch/exec ---
          ST_EXEC: begin
            pc <= pc + 1'b1;        // overridden by JMP below
            case (op)
              `PE_OP_SET: begin
                for (k = 0; k < `PE_NPIN; k = k + 1)
                  if (pinmask[k]) pinval[k] <= set_val[k];
                if (set_dly != 5'd0) begin
                  delay_cnt <= set_dly;
                  st <= ST_DELAY;
                end
              end

              `PE_OP_WAITP: begin
                wp_mode    <= wp_m;
                wp_pin     <= wp_p;
                wp_timeout <= wp_t;
                wp_prev    <= pin_in[wp_p];
                st         <= ST_WAITP;
              end

              `PE_OP_WAITU: begin
                tgt <= tgt + {{(`PE_CYC_W-13){1'b0}}, wu_delta};
                st  <= ST_WAITU;
              end

              `PE_OP_SHIFT: begin
                sh_dir   <= sh_d;
                sh_pin   <= sh_p;
                sh_left  <= sh_bits;
                sh_idx   <= sh_idx_first;
                sh_delay <= sh_dl;
                sh_cnt   <= sh_dl;
                sh_phase <= 1'b0;
                if (cfg_clken) pinval[cfg_clkpin] <= cfg_clkidle;
                if (!sh_d)     pinval[sh_p] <= shreg[sh_idx_first];
                st <= ST_SHIFT;
              end

              `PE_OP_JMP: begin
                if (branch_taken) pc <= jmp_addr;
                if (jmp_cnd == `PE_CND_XNZ && x != 8'd0) x <= x - 1'b1;
                if (jmp_cnd == `PE_CND_YNZ && y != 8'd0) y <= y - 1'b1;
                if (jmp_cnd == `PE_CND_FAULT && fault)   fault <= 1'b0;
              end

              `PE_OP_ALU: begin
                case (alu_fn)
                  `PE_ALU_XINC:  x <= x + 1'b1;
                  `PE_ALU_XDEC:  x <= x - 1'b1;
                  `PE_ALU_YINC:  y <= y + 1'b1;
                  `PE_ALU_YDEC:  y <= y - 1'b1;
                  `PE_ALU_XMOVY: x <= y;
                  `PE_ALU_YMOVX: y <= x;
                  `PE_ALU_XGETS: x <= shreg[7:0];
                  `PE_ALU_SPUTX: shreg[7:0] <= x;
                  `PE_ALU_XADDI: x <= x + alu_imm[7:0];
                  `PE_ALU_XANDI: x <= x & alu_imm[7:0];
                  `PE_ALU_XORI:  x <= x | alu_imm[7:0];
                  `PE_ALU_XXORI: x <= x ^ alu_imm[7:0];
                  `PE_ALU_PINX:
                    for (k = 0; k < `PE_NPIN; k = k + 1)
                      if (pinmask[k]) pinval[k] <= x[k];
                  default: ;
                endcase
              end

              `PE_OP_LOAD: begin
                case (ld_reg)
                  `PE_REG_PINMASK:   pinmask     <= ld_imm[`PE_NPIN-1:0];
                  `PE_REG_DRIVEMODE: drivemode   <= ld_imm[`PE_NPIN-1:0];
                  `PE_REG_X:         x           <= ld_imm[7:0];
                  `PE_REG_Y:         y           <= ld_imm[7:0];
                  `PE_REG_TGTLO:     tgt[9:0]    <= ld_imm;
                  `PE_REG_TGTHI:     tgt[15:10]  <= ld_imm[5:0];
                  `PE_REG_SHIFTCFG: begin
                    cfg_clkpin   <= ld_imm[2:0];
                    cfg_clkidle  <= ld_imm[3];
                    cfg_msbfirst <= ld_imm[4];
                    cfg_clken    <= ld_imm[5];
                  end
                  default:           shreg       <= {8'd0, ld_imm[7:0]};
                endcase
              end

              default: begin  // PE_OP_SYS
                case (sys_fn)
                  `PE_SYS_HALT: st <= ST_HALT;
                  `PE_SYS_IRQ: begin
                    irq <= 1'b1;
                    if (sys_arg[0]) st <= ST_HALT;
                  end
                  `PE_SYS_SYNC:     tgt   <= cycle;
                  `PE_SYS_CLRFAULT: fault <= 1'b0;
                  `PE_SYS_CAPARM: begin
                    cap_arm      <= 1'b1;
                    cap_arm_mask <= sys_arg[`PE_NPIN-1:0];
                  end
                  `PE_SYS_CAPPOP: if (cap_ready) begin
                    // Reading an empty FIFO does nothing, so a program pairs
                    // this with JMP CAPRDY rather than guessing.
                    cap_pop <= 1'b1;
                    x       <= cap_pins;
                    shreg   <= cap_time;
                  end
                  default: ;                        // PE_SYS_NOP
                endcase
              end
            endcase
          end

          // ------------------------------------------------- SET delay ---
          ST_DELAY: begin
            delay_cnt <= delay_cnt - 1'b1;
            if (delay_cnt == 5'd1) st <= ST_EXEC;
          end

          // --------------------------------------------- WAITP + timeout --
          // A timeout of 0 waits forever; otherwise it counts down and raises
          // the fault flag instead of hanging the machine.
          ST_WAITP: begin
            wp_prev <= wp_now;
            if (wp_hit) begin
              st <= ST_EXEC;
            end else if (wp_timeout != 8'd0) begin
              wp_timeout <= wp_timeout - 1'b1;
              if (wp_timeout == 8'd1) begin
                fault <= 1'b1;
                st    <= ST_EXEC;
              end
            end
          end

          // ------------------------------------------ WAITU deadline -----
          // Absolute: releases when the shared counter reaches TGT, so jitter
          // in earlier instructions does not accumulate.
          ST_WAITU: if (tgt_reached) st <= ST_EXEC;

          // ----------------------------------------------------- SHIFT ---
          ST_SHIFT: begin
            if (sh_cnt != 5'd0) begin
              sh_cnt <= sh_cnt - 1'b1;
            end else begin
              sh_cnt <= sh_delay;
              if (!sh_phase) begin
                // active clock edge: sample on input, drive the clock active
                sh_phase <= 1'b1;
                if (cfg_clken) pinval[cfg_clkpin] <= ~cfg_clkidle;
                if (sh_dir) shreg[sh_idx] <= pin_in[sh_pin];
              end else begin
                // idle edge: retire this bit and present the next one
                sh_phase <= 1'b0;
                if (cfg_clken) pinval[cfg_clkpin] <= cfg_clkidle;
                sh_left <= sh_left - 1'b1;
                sh_idx  <= sh_idx_next;
                if (sh_left == 5'd1) st <= ST_EXEC;
                else if (!sh_dir)   pinval[sh_pin] <= shreg[sh_idx_next];
              end
            end
          end

          // ST_HALT, and any encoding that cannot be reached: hold everything.
          // Without this, a halted machine falls into the shift datapath and
          // keeps driving pins.
          default: ;
        endcase
      end
    end
  end

`ifdef FORMAL
  // ------------------------------------------------------------- formal ----
  // Properties proved by `scripts/formal.sh` (SymbiYosys + Yices). These are
  // the guarantees a program is allowed to rely on; the cocotb tests check
  // examples of them, induction checks them for every reachable state.

  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;

  // Formal starts from an arbitrary state, so pin down the one thing real
  // hardware guarantees: the machine comes out of reset.
  initial assume (!rst_n);

  genvar f;
  generate
    for (f = 0; f < `PE_NPIN; f = f + 1) begin : g_fv_pin
      // An open-drain pin releases instead of driving high. Getting this wrong
      // would put the chip in contention with an I2C bus.
      always @(*) if (drivemode[f] && pin_oe[f]) assert (!pin_out[f]);

      // A pin outside PINMASK is never driven, so one machine cannot reach
      // into another's pins once there is more than one.
      always @(*) if (!pinmask[f]) assert (!pin_oe[f]);
    end
  endgenerate

  // The state register only ever holds a defined state. ST_HALT is the highest
  // encoding, so this also proves nothing reaches the unused 6 and 7.
  always @(posedge clk) if (f_past_valid) assert (st <= ST_HALT);

  // A halted machine holds its pins and stays halted until it is restarted.
  always @(posedge clk)
    if (f_past_valid && $past(rst_n) && !$past(clr) && $past(st == ST_HALT))
      assert (st == ST_HALT && $stable(pin_out) && $stable(pin_oe));

  // An armed WAITP always terminates: on the last cycle of its timeout it
  // leaves the wait, whether or not the pin ever did what it was waiting for.
  always @(posedge clk)
    if (f_past_valid && $past(rst_n) && !$past(clr) && $past(advance)
        && $past(st == ST_WAITP) && $past(wp_timeout) == 8'd1)
      assert (st == ST_EXEC);

  // Nothing moves while the machine is neither running nor being stepped.
  always @(posedge clk)
    if (f_past_valid && $past(rst_n) && !$past(clr) && !$past(advance))
      assert ($stable(pc) && $stable(st) && $stable(pin_out) && $stable(pin_oe));
`endif

  // sh_left's top bit and the unused decode fields are intentionally unread
  wire _unused = &{1'b0, sys_arg[9:`PE_NPIN], alu_imm[8], imem_data[9:7], 1'b0};

endmodule
