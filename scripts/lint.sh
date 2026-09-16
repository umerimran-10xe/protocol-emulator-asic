#!/usr/bin/env bash
# Run the same Verilator lint that the gds workflow runs, locally, in seconds.
#
# The CI "Linter output" step parses verilator-lint.log and turns %Error lines
# red. Catching those here means never burning a 15-minute hardening run on a
# lint failure.
#
#   source ~/eda/activate-eda.sh && ./scripts/lint.sh
set -euo pipefail
cd "$(dirname "$0")/.."

TOP=$(sed -n 's/^  top_module: *"\(.*\)".*/\1/p' info.yaml)
SOURCES=$(sed -n '/^  source_files:/,/^$/p' info.yaml | sed -n 's/^    - "\(.*\)"/src\/\1/p' | tr '\n' ' ')

echo "linting $TOP: $SOURCES"
# -Wno-fatal keeps warnings as warnings so we can count them rather than having
# verilator exit on the first one. DECLFILENAME is waived because Tiny Tapeout
# requires the top module to live in src/project.v, so the name can never match.
set +e
verilator --lint-only -Wall -Wno-fatal -Wno-DECLFILENAME \
    --top-module "$TOP" -Isrc $SOURCES 2>&1 | tee /tmp/lint_$$.log
set -e

if grep -qE "^%Error" /tmp/lint_$$.log; then
  echo; echo "LINT FAILED"; rm -f /tmp/lint_$$.log; exit 1
fi
warn=$(grep -cE "^%Warning" /tmp/lint_$$.log || true)
echo; echo "lint clean ($warn warning(s))"
rm -f /tmp/lint_$$.log
