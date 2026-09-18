#!/usr/bin/env bash
# Prove the design's safety properties with SymbiYosys.
#
#   source ~/eda/activate-eda.sh && ./scripts/formal.sh
#
# Five tasks:
#   protoemu_sm         per-machine properties, k-induction over all reachable
#                       states. Properties live in the `ifdef FORMAL block at
#                       the bottom of src/protoemu_sm.v.
#   protoemu_arb        pin arbitration, combinational, at four machines.
#   protoemu_arb_miter  cross-machine non-interference, as a two-copy miter.
#   protoemu_barrier    rendezvous between machines, at four machines.
#   protoemu_capture    edge capture, k-induction, at four read cursors.
set -euo pipefail
cd "$(dirname "$0")/../formal"

for task in protoemu_sm protoemu_arb protoemu_arb_miter protoemu_barrier \
            protoemu_capture; do
  echo "== ${task}"
  rm -rf "${task}"
  sby -f "${task}.sby"
done
