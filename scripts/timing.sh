#!/usr/bin/env bash
# Pre-layout static timing: what is the critical path, and which module is it in?
#
#   source ~/eda/activate-eda.sh && ./scripts/timing.sh
#   ./scripts/timing.sh -n 12      # show the worst 12 endpoints
#
# Synthesises with hierarchy preserved so the report names modules and runs
# OpenSTA from the LibreLane environment. Takes seconds, against three hours
# for a hardening run.
#
# READ THE NUMBERS AS RELATIVE, NOT ABSOLUTE. There is no placement, no wire
# load model and no resizing, and hierarchy is kept so paths can be named --
# which also blocks the cross-module optimisation the real flow does. Together
# those make it badly pessimistic: it reports about -14 ns of slack on a design
# that signs off at +1.63 ns in the slow corner.
#
# What it is good for is naming which module the critical path runs through,
# and showing whether a change made that path longer or shorter. For a number
# you can quote, use the gds workflow.
set -euo pipefail
cd "$(dirname "$0")/.."

ENDPOINTS=8
while getopts "n:" opt; do
  case $opt in
    n) ENDPOINTS=$OPTARG ;;
    *) echo "usage: $0 [-n endpoints]" >&2; exit 2 ;;
  esac
done

EDA=$HOME/eda
PDK_ROOT=${PDK_ROOT:-$EDA/pdk}
LIB=$PDK_ROOT/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib
PERIOD=$(sed -n 's/.*"CLOCK_PERIOD": *\([0-9.]*\).*/\1/p' src/config.json | head -1)
PERIOD=${PERIOD:-20}

TOP=$(sed -n 's/^  top_module: *"\(.*\)".*/\1/p' info.yaml)
SOURCES=$(sed -n '/^  source_files:/,/^$/p' info.yaml | sed -n 's/^    - "\(.*\)"/src\/\1/p' | tr '\n' ' ')

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

command -v yosys >/dev/null || { echo "yosys not on PATH; source ~/eda/activate-eda.sh" >&2; exit 1; }
[ -r "$LIB" ] || { echo "liberty not found at $LIB" >&2; exit 1; }

# Hierarchy is kept deliberately: a flattened netlist reports paths as _12345_
# with no clue which module they are in.
yosys -q -p "
  read_verilog -I src $SOURCES
  hierarchy -top $TOP
  synth -top $TOP
  dfflibmap -liberty $LIB
  abc -liberty $LIB -D $(python3 -c "print(int(float('$PERIOD')*1000))")
  opt_clean
  write_verilog -noattr $WORK/netlist.v
"

cat > "$WORK/sta.tcl" <<TCL
read_liberty $LIB
read_verilog $WORK/netlist.v
link_design $TOP
create_clock -name clk -period $PERIOD [get_ports clk]
set_input_delay 2 -clock clk {ui_in uio_in ena rst_n}
set_output_delay 2 -clock clk {uo_out uio_out uio_oe}
puts "######## CRITICAL PATH ########"
report_checks -path_delay max -digits 3
puts "######## WORST $ENDPOINTS ENDPOINTS ########"
report_checks -path_delay max -group_path_count $ENDPOINTS -format summary -digits 3
TCL

STA_STORE=$(ls -d "$EDA"/.nix-portable/nix/store/*-opensta 2>/dev/null | head -1)
[ -n "$STA_STORE" ] || { echo "OpenSTA not in the local nix store; see docs/local-hardening.md" >&2; exit 1; }
STA_STORE=/nix/store/$(basename "$STA_STORE")

export NP_LOCATION=$EDA NP_RUNTIME=proot
"$EDA"/nix-portable nix shell --extra-experimental-features nix-command \
  "$STA_STORE" --command sta -exit "$WORK/sta.tcl" 2>&1 | sed -n '/CRITICAL PATH/,$p'
