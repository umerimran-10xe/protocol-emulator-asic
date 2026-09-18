/*
 * Copyright (c) 2026 Umer Imran
 * SPDX-License-Identifier: Apache-2.0
 *
 * Program store: 64 x 16 bits in flip-flops, one synchronous write port, one
 * combinational fetch port per state machine, and one more for SPI readback.
 *
 * Flops rather than an SRAM macro: docs/area-budget.md measures this at 11% of
 * the 6x4 die, which is cheaper overall than a macro's placement and routing
 * halo at this size, and it keeps the flow macro-free.
 *
 * The fetch ports sit in parallel rather than in series, which is why
 * docs/scaling.md measures a second machine as costing nothing in timing.
 */

`default_nettype none
`include "protoemu_isa.vh"

module protoemu_imem #(
    parameter NRD = 1                       // fetch ports, one per machine
) (
    input  wire                 clk,
    input  wire                 we,
    input  wire [`PE_PC_W-1:0]  waddr,
    input  wire [`PE_IW-1:0]    wdata,

    input  wire [NRD*`PE_PC_W-1:0] raddr,   // machine fetch
    output wire [NRD*`PE_IW-1:0]   rdata,

    input  wire [`PE_PC_W-1:0]  raddr1,     // SPI readback
    output wire [`PE_IW-1:0]    rdata1
);

  localparam DEPTH = 1 << `PE_PC_W;

  reg [`PE_IW-1:0] mem [0:DEPTH-1];

  always @(posedge clk)
    if (we) mem[waddr] <= wdata;

  genvar r;
  generate
    for (r = 0; r < NRD; r = r + 1) begin : g_rd
      assign rdata[r*`PE_IW +: `PE_IW] = mem[raddr[r*`PE_PC_W +: `PE_PC_W]];
    end
  endgenerate

  assign rdata1 = mem[raddr1];

endmodule
