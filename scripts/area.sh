#!/usr/bin/env bash
# Fast local area check: synthesize against the CMOS5L standard cell library and
# report cell count and area against the 6x4 tile budget.
#
# CI gives the authoritative number, but takes ~20 minutes. This takes seconds.
#
#   source ~/eda/activate-eda.sh && ./scripts/area.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PDK_ROOT="${PDK_ROOT:-$HOME/eda/pdk}"
TOP=$(sed -n 's/^  top_module: *"\(.*\)".*/\1/p' info.yaml)
SOURCES=$(sed -n '/^  source_files:/,/^$/p' info.yaml | sed -n 's/^    - "\(.*\)"/src\/\1/p' | tr '\n' ' ')

LIB=$(ls "$PDK_ROOT"/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/*typ*.lib 2>/dev/null | head -1)
[ -n "$LIB" ] || { echo "No liberty found under $PDK_ROOT/ihp-sg13cmos5l/.../lib/" >&2; exit 1; }

# 6x4 tile die = 1289.28 x 710.64 um. Usable core is less after the power grid
# and margins, so treat this as an upper bound, not a target.
DIE_AREA=$(python3 -c "print(1289.28*710.64)")

echo "top      : $TOP"
echo "sources  : $SOURCES"
echo "liberty  : $(basename "$LIB")"
echo

yosys -q -p "
  read_verilog -sv $SOURCES
  hierarchy -check -top $TOP
  synth -top $TOP -flatten
  dfflibmap -liberty $LIB
  abc -liberty $LIB
  opt_clean -purge
  tee -o /dev/stdout stat -liberty $LIB
" 2>&1 | tee /tmp/area_$$.log | sed -n '/Printing statistics/,$p'

CHIP_AREA=$(sed -n 's/.*Chip area for module.*: *\([0-9.]*\).*/\1/p' /tmp/area_$$.log | tail -1)
if [ -n "$CHIP_AREA" ]; then
  python3 - "$CHIP_AREA" "$DIE_AREA" <<'PY'
import sys
cell, die = float(sys.argv[1]), float(sys.argv[2])
print(f"\ncell area   : {cell:,.0f} um^2")
print(f"6x4 die     : {die:,.0f} um^2")
print(f"utilisation : {100*cell/die:.1f}%  (place-and-route needs headroom; "
      f"LibreLane targets 60% density)")
PY
fi
rm -f /tmp/area_$$.log
