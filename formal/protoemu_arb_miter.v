/*
 * Copyright (c) 2026 Umer Imran
 * SPDX-License-Identifier: Apache-2.0
 *
 * Cross-machine non-interference for protoemu_arb, as a miter.
 *
 * The per-machine proof in src/protoemu_sm.v shows a machine never drives
 * outside its own PINMASK. That says nothing about what happens when several
 * machines share the pins: a correct-looking arbiter could still let machine 3's
 * output leak onto a pin machine 0 owns.
 *
 * So state it directly. Two copies of the arbiter get the same claims but
 * otherwise unconstrained, independently chosen drive requests. The only thing
 * assumed equal is what the *owner* of each pin asks for. If the pins still come
 * out identical, then nothing a non-owner does can reach any pin -- for every
 * combination of programs, not just the ones a test happened to run.
 *
 * Ownership is restated here from the claims rather than taken from the
 * arbiter's own priority chain, so a bug in that chain cannot make the proof
 * agree with itself.
 */

`default_nettype none

module protoemu_arb_miter #(
    parameter NSM  = 4,
    parameter NPIN = 8
) (
    input wire [NSM*NPIN-1:0] sm_mask,
    input wire [NSM*NPIN-1:0] a_out,
    input wire [NSM*NPIN-1:0] a_oe,
    input wire [NSM*NPIN-1:0] b_out,
    input wire [NSM*NPIN-1:0] b_oe
);

  wire [NPIN-1:0] a_pin_out, a_pin_oe, a_conflict;
  wire [NPIN-1:0] b_pin_out, b_pin_oe, b_conflict;

  protoemu_arb #(.NSM(NSM), .NPIN(NPIN)) u_a (
      .sm_mask (sm_mask), .sm_out (a_out), .sm_oe (a_oe),
      .pin_out (a_pin_out), .pin_oe (a_pin_oe), .conflict (a_conflict)
  );

  protoemu_arb #(.NSM(NSM), .NPIN(NPIN)) u_b (
      .sm_mask (sm_mask), .sm_out (b_out), .sm_oe (b_oe),
      .pin_out (b_pin_out), .pin_oe (b_pin_oe), .conflict (b_conflict)
  );

  genvar p, i;
  generate
    for (p = 0; p < NPIN; p = p + 1) begin : g_pin
      for (i = 0; i < NSM; i = i + 1) begin : g_sm
        // Machine i owns pin p if it claims it and no lower-numbered machine
        // does. `i` is a genvar, so the j < i test is elaborated away.
        integer j;
        reg lower;
        always @(*) begin
          lower = 1'b0;
          for (j = 0; j < NSM; j = j + 1)
            if (j < i) lower = lower | sm_mask[j*NPIN + p];
        end

        wire owns = sm_mask[i*NPIN + p] & ~lower;

        // The owner asks for the same thing in both copies. Every other
        // machine is free to differ, on this pin and on every other.
        always @(*)
          if (owns) assume (a_out[i*NPIN + p] == b_out[i*NPIN + p] &&
                            a_oe [i*NPIN + p] == b_oe [i*NPIN + p]);
      end

      // ...and the pin cannot tell the difference.
      always @(*) assert (a_pin_out[p] == b_pin_out[p] &&
                          a_pin_oe [p] == b_pin_oe [p]);
    end
  endgenerate

  // The claims are identical in both copies, so the conflict report -- which
  // depends on claims alone -- has to be identical too.
  always @(*) assert (a_conflict == b_conflict);

endmodule
