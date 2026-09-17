/*
 * Copyright (c) 2026 Umer Imran
 * SPDX-License-Identifier: Apache-2.0
 *
 * Tiny Tapeout wrapper. Pin assignments match docs/info.md and info.yaml.
 */

`default_nettype none
`include "protoemu_isa.vh"

module tt_um_umerimran_protoemu (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  wire       cfg_miso, irq, halted, active, cap_overflow;
  wire [2:0] trace;

  protoemu_top u_top (
      .clk      (clk),
      .rst_n    (rst_n),
      .cfg_sclk (ui_in[0]),
      .cfg_mosi (ui_in[1]),
      .cfg_cs_n (ui_in[2]),
      .cfg_miso (cfg_miso),
      .run_i    (ui_in[3]),
      .step_i   (ui_in[7]),
      .trig_i   (ui_in[4]),
      .pin_i    (uio_in),
      .pin_o    (uio_out),
      .pin_oe   (uio_oe),
      .cap_overflow (cap_overflow),
      .irq      (irq),
      .halted   (halted),
      .active   (active),
      .trace    (trace)
  );

  assign uo_out = {halted, trace, cap_overflow, active, irq, cfg_miso};

  // ui_in[6:5] (aux_in0, aux_in1) are still reserved.
  wire _unused = &{ena, ui_in[6:5], 1'b0};

endmodule
