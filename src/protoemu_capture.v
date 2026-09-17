/*
 * Copyright (c) 2026 Umer Imran
 * SPDX-License-Identifier: Apache-2.0
 *
 * Timestamped edge capture, shared by every state machine.
 *
 * Every time a watched pin changes, the whole pin state and the current cycle
 * count are recorded. That is what lets the chip *measure* a protocol rather
 * than only replay one: a program can arm capture, wait, and then read back
 * when each edge happened to the cycle -- bit period, pulse width, inter-frame
 * gap -- without being told the protocol in advance.
 *
 * The whole pin state is recorded rather than an index of which pin moved, so
 * simultaneous edges on several pins cost one entry instead of being lost.
 *
 * One record, one read cursor per machine. The pins are shared, so the edges on
 * them are shared too, and duplicating the storage per machine would cost four
 * times the area to hold four copies of the same thing. Giving each machine its
 * own cursor instead means every machine reads every edge, at its own pace, and
 * no machine's read retires an entry out from under another's -- which is
 * exactly the race docs/scaling.md flagged.
 *
 * Arming is machine 0's alone. Arming resets the window, so letting any machine
 * do it would put back the race in a worse place: a machine could discard edges
 * another machine was midway through reading. protoemu_top reports an arm from
 * any other machine as a program error rather than acting on it.
 *
 * The window holds the first DEPTH edges after each arm and reports the loss
 * after that. Reading does not make room: with several independent cursors
 * there is no coherent "oldest unread" entry, and one machine that stopped
 * reading would otherwise stall capture for all of them.
 */

`default_nettype none
`include "protoemu_isa.vh"

module protoemu_capture #(
    parameter NRD = 1                             // read cursors, one per machine
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 clr,              // synchronous restart, with the machines

    input  wire                 arm,              // one-cycle pulse
    input  wire [`PE_NPIN-1:0]  arm_mask,         // which pins are watched
    input  wire [`PE_NPIN-1:0]  pin_in,           // synchronised pin samples
    input  wire [`PE_CYC_W-1:0] cycle,

    input  wire [NRD-1:0]           pop,
    output wire [NRD*`PE_NPIN-1:0]  rd_pins,
    output wire [NRD*`PE_CYC_W-1:0] rd_time,
    output wire [NRD-1:0]           ready,        // this cursor has an entry waiting
    output reg                      overflow      // an edge was dropped
);

  localparam DEPTH = 1 << `PE_CAP_DEPTH_W;
  localparam W     = `PE_NPIN + `PE_CYC_W;

  reg [W-1:0]              record [0:DEPTH-1];
  // One bit wider than the depth, so `wptr == DEPTH` is a full window rather
  // than an empty one that has wrapped.
  reg [`PE_CAP_DEPTH_W:0]  wptr;
  reg [`PE_CAP_DEPTH_W:0]  rptr [0:NRD-1];
  reg                      armed;
  reg [`PE_NPIN-1:0]       capmask, prev;

  wire [`PE_NPIN-1:0] changed = (pin_in ^ prev) & capmask;
  wire                edge_now = armed && |changed;
  wire                full     = wptr[`PE_CAP_DEPTH_W];

  genvar r;
  generate
    for (r = 0; r < NRD; r = r + 1) begin : g_rd
      assign ready[r] = (rptr[r] != wptr);
      assign rd_pins[r*`PE_NPIN +: `PE_NPIN] =
          record[rptr[r][`PE_CAP_DEPTH_W-1:0]][W-1:`PE_CYC_W];
      assign rd_time[r*`PE_CYC_W +: `PE_CYC_W] =
          record[rptr[r][`PE_CAP_DEPTH_W-1:0]][`PE_CYC_W-1:0];
    end
  endgenerate

  integer i;
  always @(posedge clk) begin
    if (!rst_n || clr) begin
      wptr <= {(`PE_CAP_DEPTH_W+1){1'b0}};
      for (i = 0; i < NRD; i = i + 1)
        rptr[i] <= {(`PE_CAP_DEPTH_W+1){1'b0}};
      armed <= 1'b0;
      capmask <= {`PE_NPIN{1'b0}};
      prev <= {`PE_NPIN{1'b0}};
      overflow <= 1'b0;
    end else begin
      prev <= pin_in;

      if (arm) begin
        // Arming resets the window: the first edge after it is entry zero, so
        // timestamps are comparable against the moment capture started, and
        // every cursor starts from that same entry.
        armed    <= |arm_mask;
        capmask  <= arm_mask;
        prev     <= pin_in;
        wptr     <= {(`PE_CAP_DEPTH_W+1){1'b0}};
        for (i = 0; i < NRD; i = i + 1)
          rptr[i] <= {(`PE_CAP_DEPTH_W+1){1'b0}};
        overflow <= 1'b0;
      end else if (edge_now) begin
        if (full) begin
          overflow <= 1'b1;   // keep the first entries; report the loss
        end else begin
          record[wptr[`PE_CAP_DEPTH_W-1:0]] <= {pin_in, cycle};
          wptr <= wptr + 1'b1;
        end
      end

      if (!arm)
        for (i = 0; i < NRD; i = i + 1)
          if (pop[i] && ready[i]) rptr[i] <= rptr[i] + 1'b1;
    end
  end

endmodule
