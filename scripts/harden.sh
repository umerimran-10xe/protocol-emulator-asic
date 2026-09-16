#!/usr/bin/env bash
# Local RTL-to-GDS hardening with a live progress bar.
#
# Runs the same LibreLane invocation as the Tiny Tapeout gds workflow, but on
# this machine, via rootless Nix (nix-portable) -- no Docker, no root.
#
#   ./scripts/harden.sh              # full flow, same checks as CI
#   ./scripts/harden.sh -f           # fast: skip Magic DRC (~80% of runtime)
#   ./scripts/harden.sh -j 16        # cap threads/processes (be kind on shared machines)
#
# Magic DRC over the whole 6x4 die is the bottleneck: 17m50s of CI's ~22m, and
# single-threaded, so more cores do not help. -f is for iterating; the gds
# workflow still runs full DRC before anything is submitted.
#
# Results land in runs/wokwi/ (final/metrics.json, final/gds/, ...).
set -euo pipefail
cd "$(dirname "$0")/.."

JOBS=""
FAST=0
while getopts "j:f" opt; do
  case $opt in
    j) JOBS=$OPTARG ;;
    f) FAST=1 ;;
    *) echo "usage: $0 [-f] [-j threads]" >&2; exit 2 ;;
  esac
done

EDA=$HOME/eda
NP=$EDA/nix-portable
ENV_LINK=$EDA/librelane-env                  # GC root: keeps nix from deleting the env
export NP_LOCATION=$EDA NP_RUNTIME=proot     # bwrap cannot nest namespaces here
export PDK_ROOT=${PDK_ROOT:-$EDA/pdk} PDK=ihp-sg13cmos5l
TOTAL=72                                     # steps LibreLane Classic ran for this design (was measured, not guessed)
LOG=runs/local-harden.log

die() { echo "$1 -- see docs/local-hardening.md" >&2; exit 1; }
[ -x "$NP" ] || die "nix-portable missing"
[ -L "$ENV_LINK" ] || die "LibreLane GC root $ENV_LINK missing"
STORE_PATH=$(readlink "$ENV_LINK")
# STORE_PATH is a /nix path that only resolves inside the proot sandbox. On the
# host the same tree lives under $NP_LOCATION/.nix-portable, so check it there.
[ -d "$NP_LOCATION/.nix-portable$STORE_PATH" ] || die "LibreLane env $STORE_PATH is not in the local store"

# Regenerate the LibreLane config from info.yaml + src/config.json, as CI does.
PATH=$EDA/lrvenv/bin:$PATH python ./tt/tt_tool.py --create-user-config --ihp >/dev/null

JOB_ARGS=()
[ -n "$JOBS" ] && JOB_ARGS=(-j "$JOBS")
if (( FAST )); then
  JOB_ARGS+=(-c RUN_MAGIC_DRC=false)
  TOTAL=$(( TOTAL - 1 ))
  echo "fast mode: Magic DRC skipped -- CI still runs it"
fi

rm -rf runs/wokwi && mkdir -p runs/wokwi
start=$(date +%s)

# nix-portable can only exec its own nix binaries, so enter the env with
# `nix shell <store path>`. Using the store path (not github:...) skips flake
# evaluation and never re-downloads the flake sources.
"$NP" nix shell --extra-experimental-features nix-command "$STORE_PATH" --command \
  librelane --pdk-root "$PDK_ROOT" --pdk "$PDK" --manual-pdk \
  --run-tag wokwi --force-run-dir runs/wokwi --hide-progress-bar \
  "${JOB_ARGS[@]}" src/config_merged.json >"$LOG" 2>&1 &
pid=$!

draw() {
  local done step elapsed width=40 fill eta
  done=$(find runs/wokwi -maxdepth 1 -type d -name '[0-9]*-*' 2>/dev/null | wc -l)
  step=$(find runs/wokwi -maxdepth 1 -type d -name '[0-9]*-*' 2>/dev/null | sort -V | tail -1 | xargs -r basename)
  elapsed=$(( $(date +%s) - start ))
  (( done > TOTAL )) && done=$TOTAL
  fill=$(( done * width / TOTAL ))
  if (( done > 0 )); then eta=$(( elapsed * (TOTAL - done) / done )); else eta=0; fi
  printf '\r[%-*s] %3d%%  %2d/%d  %02d:%02d elapsed  ~%02d:%02d left  %-32.32s' \
    "$width" "$(printf '%*s' "$fill" '' | tr ' ' '#')" $(( done * 100 / TOTAL )) \
    "$done" "$TOTAL" $((elapsed/60)) $((elapsed%60)) $((eta/60)) $((eta%60)) "${step:-starting}"
}

while kill -0 "$pid" 2>/dev/null; do draw; sleep 2; done
wait "$pid" && rc=0 || rc=$?
draw; echo

elapsed=$(( $(date +%s) - start ))
if (( rc != 0 )); then
  echo "HARDEN FAILED after $((elapsed/60))m$((elapsed%60))s -- last lines of $LOG:"
  tail -20 "$LOG"
  exit "$rc"
fi

echo "hardened in $((elapsed/60))m$((elapsed%60))s"
python3 - <<'PY'
import json
m = json.load(open("runs/wokwi/final/metrics.json"))
rows = [
    ("utilisation",   "design__instance__utilization", lambda v: f"{100*v:.2f}%"),
    ("setup slack",   "timing__setup__ws",             lambda v: f"{v:+.2f} ns"),
    ("hold slack",    "timing__hold__ws",              lambda v: f"{v:+.2f} ns"),
    ("routing DRC",   "route__drc_errors",             str),
    ("magic DRC",     "magic__drc_error__count",       str),
    ("LVS errors",    "design__lvs_error__count",      str),
    ("antenna",       "route__antenna_violation__count", str),
]
for label, key, fmt in rows:
    if key in m:
        print(f"  {label:12s} {fmt(m[key])}")
PY
