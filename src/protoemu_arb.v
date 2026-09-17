/*
 * Copyright (c) 2026 Umer Imran
 * SPDX-License-Identifier: Apache-2.0
 *
 * Pin arbitration between state machines.
 *
 * Each machine publishes the pins it claims (its `PINMASK`) alongside what it
 * wants to drive. A pin belongs to the lowest-numbered machine that claims it,
 * and *only* that machine: a non-owner's drive request is discarded here rather
 * than merged, so no combination of programs can make one machine's output
 * appear on another machine's pin.
 *
 * Overlapping claims are a program error, not a runtime mode. They are still
 * resolved deterministically -- silently letting two machines fight would be
 * worse -- but every overlap is reported in `conflict`, which the top level
 * latches into a status register the host can read back over SPI.
 *
 * NSM is a parameter rather than `PE_NSM` so the proofs in formal/ can run it
 * at four machines while the chip is still built with one.
 */

`default_nettype none

module protoemu_arb #(
    parameter NSM  = 1,
    parameter NPIN = 8
) (
    input  wire [NSM*NPIN-1:0] sm_mask,   // per machine: pins claimed (PINMASK)
    input  wire [NSM*NPIN-1:0] sm_out,    // per machine: value driven
    input  wire [NSM*NPIN-1:0] sm_oe,     // per machine: drive enable

    output wire [NPIN-1:0]     pin_out,
    output wire [NPIN-1:0]     pin_oe,
    output wire [NPIN-1:0]     conflict   // more than one machine claims this pin
);

  // Prefix chains, one stage per machine. Index [i] is the value before machine
  // i has been folded in, so [NSM] is the final result.
  wire [(NSM+1)*NPIN-1:0] taken;    // some machine below i claims this pin
  wire [(NSM+1)*NPIN-1:0] clash;    // some pin was claimed twice below i
  wire [(NSM+1)*NPIN-1:0] out_acc;
  wire [(NSM+1)*NPIN-1:0] oe_acc;

  // Ownership, flattened out of the generate block so the proofs below can
  // index it without reaching into a generate scope.
  wire [NSM*NPIN-1:0] owner;

  assign taken  [NPIN-1:0] = {NPIN{1'b0}};
  assign clash  [NPIN-1:0] = {NPIN{1'b0}};
  assign out_acc[NPIN-1:0] = {NPIN{1'b0}};
  assign oe_acc [NPIN-1:0] = {NPIN{1'b0}};

  genvar i;
  generate
    for (i = 0; i < NSM; i = i + 1) begin : g_own
      wire [NPIN-1:0] claim = sm_mask[i*NPIN +: NPIN];
      wire [NPIN-1:0] prior = taken  [i*NPIN +: NPIN];

      // Ownership: claimed here, and not already claimed by a lower machine.
      // `own` is one-hot per pin across machines, which is what turns the OR
      // below into a mux.
      wire [NPIN-1:0] own = claim & ~prior;
      assign owner[i*NPIN +: NPIN] = own;

      assign taken  [(i+1)*NPIN +: NPIN] = prior | claim;
      assign clash  [(i+1)*NPIN +: NPIN] = clash[i*NPIN +: NPIN] | (claim & prior);
      assign out_acc[(i+1)*NPIN +: NPIN] = out_acc[i*NPIN +: NPIN] |
                                           (own & sm_out[i*NPIN +: NPIN]);
      assign oe_acc [(i+1)*NPIN +: NPIN] = oe_acc [i*NPIN +: NPIN] |
                                           (own & sm_oe [i*NPIN +: NPIN]);
    end
  endgenerate

  assign pin_out  = out_acc[NSM*NPIN +: NPIN];
  assign pin_oe   = oe_acc [NSM*NPIN +: NPIN];
  assign conflict = clash  [NSM*NPIN +: NPIN];

  // The last `taken` stage and `owner` exist for the proofs below; the chip
  // gets its answers from the accumulator chains instead.
  wire _unused = &{1'b0, taken[NSM*NPIN +: NPIN], owner, 1'b0};

`ifdef FORMAL
  // ------------------------------------------------------------- formal ----
  // Combinational, so `formal/protoemu_arb.sby` runs plain BMC at depth 1:
  // one step already covers every input combination.
  genvar fp, fi;
  generate
    for (fp = 0; fp < NPIN; fp = fp + 1) begin : g_fa_pin

      // A pin no machine claims is released, and released pins read as 0 rather
      // than as whatever the last owner happened to be driving.
      always @(*)
        if (!taken[NSM*NPIN + fp]) assert (!pin_oe[fp] && !pin_out[fp]);

      // `conflict` is exactly "claimed more than once" -- no missed overlap and
      // no false report, which is what makes it usable as a program error.
      integer c;
      reg [31:0] nclaim;
      always @(*) begin
        nclaim = 32'd0;
        for (c = 0; c < NSM; c = c + 1)
          nclaim = nclaim + {31'd0, sm_mask[c*NPIN + fp]};
      end
      always @(*) assert (conflict[fp] == (nclaim > 32'd1));

      for (fi = 0; fi < NSM; fi = fi + 1) begin : g_fa_sm
        // What the pin shows is the owner's request, unchanged.
        always @(*)
          if (owner[fi*NPIN + fp])
            assert (pin_out[fp] == sm_out[fi*NPIN + fp] &&
                    pin_oe [fp] == sm_oe [fi*NPIN + fp]);
      end
    end
  endgenerate
`endif

endmodule
