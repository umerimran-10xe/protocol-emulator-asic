/*
 * Copyright (c) 2026 Umer Imran
 * SPDX-License-Identifier: Apache-2.0
 *
 * Timestamped edge capture.
 *
 * Every time a watched pin changes, the whole pin state and the current cycle
 * count are pushed into a FIFO. That is what lets the chip *measure* a
 * protocol rather than only replay one: a program can arm capture, wait, and
 * then read back when each edge happened to the cycle -- bit period, pulse
 * width, inter-frame gap -- without being told the protocol in advance.
 *
 * The whole pin state is recorded rather than an index of which pin moved, so
 * simultaneous edges on several pins cost one entry instead of being lost.
 */

`default_nettype none
`include "protoemu_isa.vh"

module protoemu_capture (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 clr,          // synchronous restart, with the machine

    input  wire                 arm,          // one-cycle pulse
    input  wire [`PE_NPIN-1:0]  arm_mask,     // which pins are watched
    input  wire [`PE_NPIN-1:0]  pin_in,       // synchronised pin samples
    input  wire [`PE_CYC_W-1:0] cycle,

    input  wire                 pop,
    output wire [`PE_NPIN-1:0]  rd_pins,
    output wire [`PE_CYC_W-1:0] rd_time,
    output wire                 ready,        // an entry is waiting
    output reg                  overflow      // an edge was dropped
);

  localparam DEPTH = 1 << `PE_CAP_DEPTH_W;
  localparam W     = `PE_NPIN + `PE_CYC_W;

  reg [W-1:0]              fifo [0:DEPTH-1];
  reg [`PE_CAP_DEPTH_W:0]  wptr, rptr;        // one extra bit distinguishes full from empty
  reg                      armed;
  reg [`PE_NPIN-1:0]       capmask, prev;

  wire [`PE_NPIN-1:0] changed = (pin_in ^ prev) & capmask;
  wire                push    = armed && |changed;
  wire                full    = (wptr[`PE_CAP_DEPTH_W] != rptr[`PE_CAP_DEPTH_W]) &&
                                (wptr[`PE_CAP_DEPTH_W-1:0] == rptr[`PE_CAP_DEPTH_W-1:0]);

  assign ready   = (wptr != rptr);
  assign rd_pins = fifo[rptr[`PE_CAP_DEPTH_W-1:0]][W-1:`PE_CYC_W];
  assign rd_time = fifo[rptr[`PE_CAP_DEPTH_W-1:0]][`PE_CYC_W-1:0];

  always @(posedge clk) begin
    if (!rst_n || clr) begin
      wptr <= {(`PE_CAP_DEPTH_W+1){1'b0}};
      rptr <= {(`PE_CAP_DEPTH_W+1){1'b0}};
      armed <= 1'b0;
      capmask <= {`PE_NPIN{1'b0}};
      prev <= {`PE_NPIN{1'b0}};
      overflow <= 1'b0;
    end else begin
      prev <= pin_in;

      if (arm) begin
        // Arming resets the window: the first edge after it is entry zero, so
        // timestamps are comparable against the moment capture started.
        armed    <= |arm_mask;
        capmask  <= arm_mask;
        prev     <= pin_in;
        wptr     <= {(`PE_CAP_DEPTH_W+1){1'b0}};
        rptr     <= {(`PE_CAP_DEPTH_W+1){1'b0}};
        overflow <= 1'b0;
      end else if (push) begin
        if (full) begin
          overflow <= 1'b1;   // keep the oldest entries; report the loss
        end else begin
          fifo[wptr[`PE_CAP_DEPTH_W-1:0]] <= {pin_in, cycle};
          wptr <= wptr + 1'b1;
        end
      end

      if (pop && ready) rptr <= rptr + 1'b1;
    end
  end

endmodule
