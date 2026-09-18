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

  // Bits of the control address that select a machine. Verilog has no
  // zero-width part-select, so a single machine still takes one bit.
  localparam SMIDX_W = (`PE_NSM > 1) ? $clog2(`PE_NSM) : 1;

  integer si;
  always @(posedge clk) begin
    if (!rst_n) begin
      for (si = 0; si < `PE_NSM; si = si + 1)
        startpc[si] <= {`PE_PC_W{1'b0}};
    end else if (ctl_we && ctl_addr < `PE_NSM) begin
      startpc[ctl_addr[SMIDX_W-1:0]] <= ctl_wdata[`PE_PC_W-1:0];
    end
  end

  // Two program errors are latched rather than acted on, so the host can read
  // back what a program did wrong instead of inferring it from a scope. Both
  // clear on a rising edge of `run`, and writing a 1 clears that bit.
  //
  //   conflict     two machines claimed the same pin
  //   caparm_deny  a machine that does not own capture tried to arm it
  wire [`PE_NPIN-1:0] pin_conflict;
  wire [`PE_NSM-1:0]  caparm_denied;
  wire                conflict_we = ctl_we && (ctl_addr == `PE_CTL_CONFLICT);
  wire                caparm_we   = ctl_we && (ctl_addr == `PE_CTL_CAPARM);
  reg  [`PE_NPIN-1:0] conflict_sticky;
  reg  [`PE_NSM-1:0]  caparm_sticky;

  always @(posedge clk) begin
    if (!rst_n || run_rise) begin
      conflict_sticky <= {`PE_NPIN{1'b0}};
      caparm_sticky   <= {`PE_NSM{1'b0}};
    end else begin
      conflict_sticky <= (conflict_sticky &
                          ~(conflict_we ? ctl_wdata[`PE_NPIN-1:0]
                                        : {`PE_NPIN{1'b0}}))
                         | pin_conflict;
      caparm_sticky   <= (caparm_sticky &
                          ~(caparm_we ? ctl_wdata[`PE_NSM-1:0]
                                      : {`PE_NSM{1'b0}}))
                         | caparm_denied;
    end
  end

  // Only the low bits of a control write mean anything today; the rest are
  // reserved for control registers this design has not needed yet.
  wire _unused_ctl = &{1'b0, ctl_wdata[`PE_IW-1:`PE_NPIN], 1'b0};

  wire [`PE_IW-1:0] ctl_rdata =
      (ctl_raddr < `PE_NSM)
        ? {{(`PE_IW-`PE_PC_W){1'b0}}, startpc[ctl_raddr[SMIDX_W-1:0]]}
      : (ctl_raddr == `PE_CTL_CONFLICT)
        ? {{(`PE_IW-`PE_NPIN){1'b0}}, conflict_sticky}
      : (ctl_raddr == `PE_CTL_CAPARM)
        ? {{(`PE_IW-`PE_NSM){1'b0}}, caparm_sticky}
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
  // One record of the edges, one read cursor per machine, so every machine can
  // measure the shared pins without one machine's pop retiring an entry another
  // is midway through reading.
  wire                            cap_arm;
  wire [`PE_NPIN-1:0]             cap_arm_mask;
  wire [`PE_NSM-1:0]              cap_pop, cap_ready;
  wire [`PE_NSM*`PE_NPIN-1:0]     cap_pins;
  wire [`PE_NSM*`PE_CYC_W-1:0]    cap_time;

  // trig_in arms capture from outside the chip as well, so a capture can be
  // started by the event under observation rather than only by the program.
  reg [1:0] trig_s;
  reg       trig_q;
  always @(posedge clk) begin
    if (!rst_n) begin trig_s <= 2'b00; trig_q <= 1'b0; end
    else        begin trig_s <= {trig_s[0], trig_i}; trig_q <= trig_s[1]; end
  end
  wire trig_rise = trig_s[1] & ~trig_q;

  protoemu_capture #(.NRD(`PE_NSM)) u_cap (
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
  wire [`PE_NSM-1:0]          sm_bar_req, sm_bar_go;
  wire [`PE_NSM*`PE_BAR_W-1:0] sm_bar_mask;
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
          .bar_req   (sm_bar_req[m]),
          .bar_mask  (sm_bar_mask[m*`PE_BAR_W +: `PE_BAR_W]),
          .bar_go    (sm_bar_go[m]),
          // Every machine reads at its own pace; only machine 0 may arm,
          // because arming resets the window for everyone.
          .cap_arm      (sm_cap_arm[m]),
          .cap_arm_mask (sm_cap_arm_mask[m*`PE_NPIN +: `PE_NPIN]),
          .cap_pop      (sm_cap_pop[m]),
          .cap_ready    (cap_ready[m]),
          .cap_pins     (cap_pins[m*`PE_NPIN  +: `PE_NPIN]),
          .cap_time     (cap_time[m*`PE_CYC_W +: `PE_CYC_W]),
          .irq       (sm_irq[m]),
          .halted    (sm_halted[m]),
          .active    (sm_active[m]),
          .trace     (sm_trace[m*3 +: 3])
      );
    end
  endgenerate

  assign cap_arm      = sm_cap_arm[0];
  assign cap_arm_mask = sm_cap_arm_mask[0 +: `PE_NPIN];
  assign cap_pop      = sm_cap_pop;

  // An arm from any other machine is dropped and reported. Acting on it would
  // reset the window under whichever machines were reading it.
  generate
    if (`PE_NSM > 1) begin : g_caparm_deny
      assign caparm_denied = {sm_cap_arm[`PE_NSM-1:1], 1'b0};
    end else begin : g_caparm_deny
      assign caparm_denied = 1'b0;
    end
  endgenerate

  // `halted` means the whole chip is done, so it waits for the last machine;
  // `irq` and `active` are true of any of them.
  assign irq    = |sm_irq;
  assign halted = &sm_halted;
  assign active = |sm_active;
  assign trace  = sm_trace[0 +: 3];

  // The participant mask is `PE_BAR_W bits in the encoding however many
  // machines are built, so a program assembled for four still decodes on one.
  // Naming a machine that does not exist drops out of the mask here, which
  // releases the barrier rather than hanging on a machine that can never come.
  wire [`PE_NSM*`PE_NSM-1:0] bar_mask_built;
  genvar b;
  generate
    for (b = 0; b < `PE_NSM; b = b + 1) begin : g_bar_mask
      assign bar_mask_built[b*`PE_NSM +: `PE_NSM] =
          sm_bar_mask[b*`PE_BAR_W +: `PE_NSM];
    end
  endgenerate

  protoemu_barrier #(.NSM(`PE_NSM)) u_bar (
      .req    (sm_bar_req),
      .mask   (bar_mask_built),
      .halted (sm_halted),
      .go     (sm_bar_go)
  );

  protoemu_arb #(.NSM(`PE_NSM), .NPIN(`PE_NPIN)) u_arb (
      .sm_mask  (sm_claim),
      .sm_out   (sm_out),
      .sm_oe    (sm_oe),
      .pin_out  (pin_o),
      .pin_oe   (pin_oe),
      .conflict (pin_conflict)
  );

  // Only machine 0's arm mask reaches the capture block -- the rest are dropped
  // along with the arms that carried them -- and only machine 0's state reaches
  // the trace pins, which are three bits wide however many machines there are.
  wire _unused_cap = &{1'b0, sm_cap_arm_mask, sm_trace, sm_bar_mask, 1'b0};

endmodule
