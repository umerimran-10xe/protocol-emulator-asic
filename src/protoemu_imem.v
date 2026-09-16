/*
 * Copyright (c) 2026 Umer Imran
 * SPDX-License-Identifier: Apache-2.0
 *
 * Program store: 128 x 16 bits in flip-flops, one synchronous write port and
 * two combinational read ports (the state machine's fetch, and SPI readback).
 *
 * Flops rather than an SRAM macro: docs/area-budget.md measures this at 11% of
 * the 6x4 die, which is cheaper overall than a macro's placement and routing
 * halo at this size, and it keeps the flow macro-free.
 */

`default_nettype none
`include "protoemu_isa.vh"

module protoemu_imem (
    input  wire                 clk,
    input  wire                 we,
    input  wire [`PE_PC_W-1:0]  waddr,
    input  wire [`PE_IW-1:0]    wdata,

    input  wire [`PE_PC_W-1:0]  raddr0,
    output wire [`PE_IW-1:0]    rdata0,
    input  wire [`PE_PC_W-1:0]  raddr1,
    output wire [`PE_IW-1:0]    rdata1
);

  localparam DEPTH = 1 << `PE_PC_W;

  reg [`PE_IW-1:0] mem [0:DEPTH-1];

  always @(posedge clk)
    if (we) mem[waddr] <= wdata;

  assign rdata0 = mem[raddr0];
  assign rdata1 = mem[raddr1];

endmodule
