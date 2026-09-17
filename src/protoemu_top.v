/*
 * Copyright (c) 2026 Umer Imran
 * SPDX-License-Identifier: Apache-2.0
 *
 * Protocol emulator: program store, SPI loader, cycle counter and PE_NSM
 * protocol state machines sharing the 8 bidirectional pins.
 *
 * Control model: `run` low holds the machines stalled and `step` advances them
 * one cycle at a time. A 0->1 edge on `run` restarts every machine from its
 * configured start address and zeroes the cycle counter, so every run begins
 * from the same state.
 *
 * The machines share the pins through protoemu_arb, which gives each pin to the
 * lowest-numbered machine that claims it. src/protoemu_sm.v proves a machine
 * never drives outside its own PINMASK; formal/protoemu_arb_miter.v proves the
 * other half, that nothing a non-owner does can reach a pin it does not own.
 */

`default_nettype none
`include "protoemu_isa.vh"

module protoemu_top (
    input  wire                 clk,
    input  wire                 rst_n,

    // control / config
    input  wire                 cfg_sclk,
    input  wire                 cfg_mosi,
    input  wire                 cfg_cs_n,
    output wire                 cfg_miso,
    input  wire                 run_i,
    input  wire                 step_i,

    // protocol pins
    input  wire [`PE_NPIN-1:0]  pin_i,
    output wire [`PE_NPIN-1:0]  pin_o,
    output wire [`PE_NPIN-1:0]  pin_oe,

    input  wire                 trig_i,     // external arm for edge capture
    output wire                 cap_overflow,
    output wire                 irq,
    output wire                 halted,
    output wire                 active,
    output wire [2:0]           trace
);

  // ---- input conditioning -------------------------------------------------
  // Everything arriving from a pad is asynchronous to clk, so it is
  // double-synchronised before any logic looks at it.
  reg [`PE_NPIN-1:0] pin_s0, pin_s1;
  reg [1:0]          run_s, step_s;

  always @(posedge clk) begin
    if (!rst_n) begin
      pin_s0 <= {`PE_NPIN{1'b0}}; pin_s1 <= {`PE_NPIN{1'b0}};
      run_s  <= 2'b00;            step_s <= 2'b00;
    end else begin
      pin_s0 <= pin_i;  pin_s1 <= pin_s0;
      run_s  <= {run_s[0],  run_i};
      step_s <= {step_s[0], step_i};
    end
  end

  reg run_q, step_q;
  always @(posedge clk) begin
    if (!rst_n) begin run_q <= 1'b0; step_q <= 1'b0; end
    else        begin run_q <= run_s[1]; step_q <= step_s[1]; end
  end

  wire run       = run_s[1];
  wire run_rise  = run_s[1]  & ~run_q;    // restart edge
  wire step_pulse = step_s[1] & ~step_q;  // one instruction-cycle of progress

  // ---- shared cycle counter ----------------------------------------------
  // WAITU compares absolute counter values, so a program's timing does not
  // drift with however long earlier instructions happened to take.
  reg [`PE_CYC_W-1:0] cycle;
  always @(posedge clk) begin
    if (!rst_n || run_rise) cycle <= {`PE_CYC_W{1'b0}};
    else if (run)           cycle <= cycle + 1'b1;
  end

  // ---- control registers --------------------------------------------------
  // Every machine reads the same program store, so without its own start
  // address each would execute the same instructions in lockstep.
  wire                ctl_we;
  wire [7:0]          ctl_addr, ctl_raddr;
  wire [`PE_IW-1:0]   ctl_wdata;
  reg  [`PE_PC_W-1:0] startpc [0:`PE_NSM-1];

  integer si;
  always @(posedge clk) begin
    if (!rst_n) begin
      for (si = 0; si < `PE_NSM; si = si + 1)
        startpc[si] <= {`PE_PC_W{1'b0}};
    end else if (ctl_we && ctl_addr < `PE_NSM) begin
      startpc[ctl_addr[$clog2(`PE_NSM+1)-1:0]] <= ctl_wdata[`PE_PC_W-1:0];
    end
  end

  // Overlapping PINMASKs are a program error. The arbiter still resolves them
  // deterministically, but the overlap is latched here so the host can read
  // back which pins two machines fought over instead of guessing from a scope.
  wire [`PE_NPIN-1:0] pin_conflict;
  wire                conflict_we = ctl_we && (ctl_addr == `PE_CTL_CONFLICT);
  reg  [`PE_NPIN-1:0] conflict_sticky;

  always @(posedge clk) begin
    if (!rst_n || run_rise) conflict_sticky <= {`PE_NPIN{1'b0}};
    else conflict_sticky <= (conflict_sticky &
                             ~(conflict_we ? ctl_wdata[`PE_NPIN-1:0]
                                           : {`PE_NPIN{1'b0}}))
                            | pin_conflict;
  end

  // Only the low bits of a control write mean anything today; the rest are
  // reserved for control registers this design has not needed yet.
  wire _unused_ctl = &{1'b0, ctl_wdata[`PE_IW-1:`PE_NPIN], 1'b0};

  wire [`PE_IW-1:0] ctl_rdata =
      (ctl_raddr < `PE_NSM)
        ? {{(`PE_IW-`PE_PC_W){1'b0}}, startpc[ctl_raddr[$clog2(`PE_NSM+1)-1:0]]}
      : (ctl_raddr == `PE_CTL_CONFLICT)
        ? {{(`PE_IW-`PE_NPIN){1'b0}}, conflict_sticky}
        : {`PE_IW{1'b0}};

  // ---- program store ------------------------------------------------------
  wire                imem_we;
  wire [`PE_PC_W-1:0] imem_waddr, imem_raddr;
  wire [`PE_IW-1:0]   imem_wdata, cfg_rdata;

  wire [`PE_NSM*`PE_PC_W-1:0] sm_pc;
  wire [`PE_NSM*`PE_IW-1:0]   sm_instr;

  protoemu_imem #(.NRD(`PE_NSM)) u_imem (
      .clk    (clk),
      .we     (imem_we),
      .waddr  (imem_waddr),
      .wdata  (imem_wdata),
      .raddr  (sm_pc),
      .rdata  (sm_instr),
      .raddr1 (imem_raddr),
      .rdata1 (cfg_rdata)
  );

  protoemu_cfg u_cfg (
      .clk        (clk),
      .rst_n      (rst_n),
      .sclk_i     (cfg_sclk),
      .mosi_i     (cfg_mosi),
      .cs_n_i     (cfg_cs_n),
      .miso       (cfg_miso),
      .imem_we    (imem_we),
      .imem_waddr (imem_waddr),
      .imem_raddr (imem_raddr),
      .imem_wdata (imem_wdata),
      .imem_rdata (cfg_rdata),
      .ctl_we     (ctl_we),
      .ctl_addr   (ctl_addr),
      .ctl_raddr  (ctl_raddr),
      .ctl_wdata  (ctl_wdata),
      .ctl_rdata  (ctl_rdata)
  );

  // ---- timestamped edge capture ------------------------------------------
  wire                 cap_arm, cap_pop, cap_ready;
  wire [`PE_NPIN-1:0]  cap_arm_mask, cap_pins;
  wire [`PE_CYC_W-1:0] cap_time;

  // trig_in arms capture from outside the chip as well, so a capture can be
  // started by the event under observation rather than only by the program.
  reg [1:0] trig_s;
  reg       trig_q;
  always @(posedge clk) begin
    if (!rst_n) begin trig_s <= 2'b00; trig_q <= 1'b0; end
    else        begin trig_s <= {trig_s[0], trig_i}; trig_q <= trig_s[1]; end
  end
  wire trig_rise = trig_s[1] & ~trig_q;

  protoemu_capture u_cap (
      .clk      (clk),
      .rst_n    (rst_n),
      .clr      (run_rise),
      .arm      (cap_arm | trig_rise),
      .arm_mask (cap_arm ? cap_arm_mask : {`PE_NPIN{1'b1}}),
      .pin_in   (pin_s1),
      .cycle    (cycle),
      .pop      (cap_pop),
      .rd_pins  (cap_pins),
      .rd_time  (cap_time),
      .ready    (cap_ready),
      .overflow (cap_overflow)
  );

  // ---- state machines -----------------------------------------------------
  wire [`PE_NSM*`PE_NPIN-1:0] sm_claim, sm_out, sm_oe, sm_cap_arm_mask;
  wire [`PE_NSM-1:0]          sm_cap_arm, sm_cap_pop;
  wire [`PE_NSM-1:0]          sm_irq, sm_halted, sm_active;
  wire [`PE_NSM*3-1:0]        sm_trace;

  genvar m;
  generate
    for (m = 0; m < `PE_NSM; m = m + 1) begin : g_sm
      protoemu_sm u_sm (
          .clk       (clk),
          .rst_n     (rst_n),
          .run       (run),
          .step      (step_pulse),
          .clr       (run_rise),
          .start_pc  (startpc[m]),
          .imem_addr (sm_pc[m*`PE_PC_W +: `PE_PC_W]),
          .imem_data (sm_instr[m*`PE_IW +: `PE_IW]),
          .pin_in    (pin_s1),
          .pin_claim (sm_claim[m*`PE_NPIN +: `PE_NPIN]),
          .pin_out   (sm_out  [m*`PE_NPIN +: `PE_NPIN]),
          .pin_oe    (sm_oe   [m*`PE_NPIN +: `PE_NPIN]),
          .cycle     (cycle),
          // Capture belongs to machine 0. Letting every machine arm and pop one
          // shared FIFO races: two pops in the same cycle would retire one
          // entry between them. docs/scaling.md keeps the per-machine read
          // pointer that would fix that properly on the open list.
          .cap_arm      (sm_cap_arm[m]),
          .cap_arm_mask (sm_cap_arm_mask[m*`PE_NPIN +: `PE_NPIN]),
          .cap_pop      (sm_cap_pop[m]),
          .cap_ready    (m == 0 ? cap_ready : 1'b0),
          .cap_pins     (m == 0 ? cap_pins  : {`PE_NPIN{1'b0}}),
          .cap_time     (m == 0 ? cap_time  : {`PE_CYC_W{1'b0}}),
          .irq       (sm_irq[m]),
          .halted    (sm_halted[m]),
          .active    (sm_active[m]),
          .trace     (sm_trace[m*3 +: 3])
      );
    end
  endgenerate

  assign cap_arm      = sm_cap_arm[0];
  assign cap_arm_mask = sm_cap_arm_mask[0 +: `PE_NPIN];
  assign cap_pop      = sm_cap_pop[0];

  // `halted` means the whole chip is done, so it waits for the last machine;
  // `irq` and `active` are true of any of them.
  assign irq    = |sm_irq;
  assign halted = &sm_halted;
  assign active = |sm_active;
  assign trace  = sm_trace[0 +: 3];

  protoemu_arb #(.NSM(`PE_NSM), .NPIN(`PE_NPIN)) u_arb (
      .sm_mask  (sm_claim),
      .sm_out   (sm_out),
      .sm_oe    (sm_oe),
      .pin_out  (pin_o),
      .pin_oe   (pin_oe),
      .conflict (pin_conflict)
  );

  // The capture strobes of every machine but 0 are deliberately unread.
  wire _unused_cap = &{1'b0, sm_cap_arm, sm_cap_pop, sm_cap_arm_mask, 1'b0};

endmodule
