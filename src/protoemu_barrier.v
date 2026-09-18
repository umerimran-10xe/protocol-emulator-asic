/*
 * Copyright (c) 2026 Umer Imran
 * SPDX-License-Identifier: Apache-2.0
 *
 * Rendezvous between state machines.
 *
 * A machine executing `SYS BARRIER` names the machines it is waiting for and
 * stops. Every machine whose participants have all arrived is released in the
 * same cycle, so they resume in step -- which is the point. `SYS SYNC` can only
 * re-anchor one machine's deadline against the shared cycle counter; it cannot
 * make two machines start a transfer on the same edge, and a full-duplex
 * protocol with a transmitter and a receiver on separate machines needs exactly
 * that.
 *
 * A halted machine counts as arrived. Without that, one machine finishing its
 * part of a protocol would wedge every machine still waiting on it, and the
 * usual answer -- a timeout -- would turn a program bug into a silent timing
 * glitch. A machine that is running but never reaches the barrier does hang the
 * others, but that is an infinite loop, and no arbitration can fix one.
 *
 * NSM is a parameter rather than `PE_NSM so the proofs in formal/ can run it at
 * four machines while the chip is still built with one.
 */

`default_nettype none

module protoemu_barrier #(
    parameter NSM = 1
) (
    input  wire [NSM-1:0]     req,      // machine is stopped at a barrier
    input  wire [NSM*NSM-1:0] mask,     // per machine: who it is waiting for
    input  wire [NSM-1:0]     halted,   // a halted machine is never coming

    output wire [NSM-1:0]     go        // may leave the barrier this cycle
);

  wire [NSM-1:0] arrived = req | halted;

  genvar m;
  generate
    for (m = 0; m < NSM; m = m + 1) begin : g_bar
      wire [NSM-1:0] want = mask[m*NSM +: NSM];
      // Release is a pure function of who is waiting, so every machine with the
      // same participant set sees the same answer on the same cycle.
      assign go[m] = req[m] && ((arrived & want) == want);
    end
  endgenerate

`ifdef FORMAL
  // ------------------------------------------------------------- formal ----
  // Combinational, so BMC at depth 1 is exhaustive over every input.
  genvar fa, fb;
  generate
    for (fa = 0; fa < NSM; fa = fa + 1) begin : g_fb

      // Nobody leaves a barrier they are not at.
      always @(*) if (go[fa]) assert (req[fa]);

      // Nobody leaves early: every participant has arrived or will never come.
      for (fb = 0; fb < NSM; fb = fb + 1) begin : g_fb_p
        always @(*)
          if (go[fa] && mask[fa*NSM + fb]) assert (req[fb] || halted[fb]);
      end

      // Nobody is left waiting once its participants are all there. Without
      // this the barrier could satisfy everything above by never releasing.
      always @(*)
        if (req[fa] && (((req | halted) & mask[fa*NSM +: NSM])
                        == mask[fa*NSM +: NSM]))
          assert (go[fa]);

      // Two machines waiting on the same set leave together -- the property the
      // whole block exists for.
      for (fb = 0; fb < NSM; fb = fb + 1) begin : g_fb_pair
        always @(*)
          if (req[fa] && req[fb] &&
              mask[fa*NSM +: NSM] == mask[fb*NSM +: NSM]) assert (go[fa] == go[fb]);
      end
    end
  endgenerate
`endif

endmodule
