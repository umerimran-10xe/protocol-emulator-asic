#!/usr/bin/env bash
# Prove the state machine's safety properties with SymbiYosys.
#
#   source ~/eda/activate-eda.sh && ./scripts/formal.sh
#
# The properties live in the `ifdef FORMAL block at the bottom of
# src/protoemu_sm.v, next to the logic they constrain.
set -euo pipefail
cd "$(dirname "$0")/../formal"

rm -rf protoemu_sm
sby -f protoemu_sm.sby
