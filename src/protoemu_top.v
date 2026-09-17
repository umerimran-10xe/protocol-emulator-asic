/*
 * Copyright (c) 2026 Umer Imran
 * SPDX-License-Identifier: Apache-2.0
 *
 * Protocol emulator: program store, SPI loader, cycle counter and one
 * protocol state machine driving the 8 bidirectional pins.
 *
 * Control model: `run` low holds the machine stalled and `step` advances it one
 * cycle at a time. A 0->1 edge on `run` restarts the program from address 0 and
 * zeroes the cycle counter, so every run begins from the same state.
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

  // ---- program store ------------------------------------------------------
  wire                imem_we;
  wire [`PE_PC_W-1:0] imem_waddr, imem_raddr, sm_pc;
  wire [`PE_IW-1:0]   imem_wdata, sm_instr, cfg_rdata;

  protoemu_imem u_imem (
      .clk    (clk),
      .we     (imem_we),
      .waddr  (imem_waddr),
      .wdata  (imem_wdata),
      .raddr0 (sm_pc),
      .rdata0 (sm_instr),
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
      .imem_rdata (cfg_rdata)
  );

  protoemu_sm u_sm (
      .clk       (clk),
      .rst_n     (rst_n),
      .run       (run),
      .step      (step_pulse),
      .clr       (run_rise),
      .imem_addr (sm_pc),
      .imem_data (sm_instr),
      .pin_in    (pin_s1),
      .pin_out   (pin_o),
      .pin_oe    (pin_oe),
      .cycle     (cycle),
      .irq       (irq),
      .halted    (halted),
      .active    (active),
      .trace     (trace)
  );

endmodule
