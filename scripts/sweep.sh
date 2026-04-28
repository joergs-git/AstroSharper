#!/usr/bin/env bash
#
# RADICAL stacking sweep — tries combinations that span the full
# parameter space, with extra emphasis on drizzle (which empirically
# was the only knob that visibly helped in earlier rounds).
#
# Output: 20 raw TIFFs (no post-stack sharpen) in `.regression/sweep/`.
# Drizzle 2× outputs are 4× larger, drizzle 3× are 9× larger — that
# size difference alone tells you which file is which without opening
# them.
#
# Matrix:
#
#   Block A — Drizzle pixfrac sweep (the knob that helped most):
#     1. drizzle 2x pixfrac 0.3  k=25
#     2. drizzle 2x pixfrac 0.5  k=25
#     3. drizzle 2x pixfrac 0.7  k=25  (current default)
#     4. drizzle 2x pixfrac 1.0  k=25
#     5. drizzle 3x pixfrac 0.5  k=25
#     6. drizzle 3x pixfrac 0.7  k=25
#
#   Block B — Lucky drizzle (low keep% + drizzle):
#     7. drizzle 2x pixfrac 0.5  k=5
#     8. drizzle 2x pixfrac 0.7  k=10
#     9. drizzle 3x pixfrac 0.5  k=5
#
#   Block C — Drizzle + scientific cleaner-reference build:
#    10. drizzle 2x scientific  k=25
#    11. drizzle 2x scientific  k=10
#
#   Block D — Drizzle + sigma-clip outlier rejection:
#    12. drizzle 2x sigma 1.5   k=25
#    13. drizzle 2x sigma 2.5   k=10
#
#   Block E — Extreme keep-% (lucky imaging vs averaging):
#    14. lightspeed k=2          (close to single-best-frame)
#    15. lightspeed k=99         (almost full averaging — control)
#    16. scientific k=2
#
#   Block F — Aggressive sigma-clip:
#    17. sigma 0.8 k=25          (very aggressive, ≈ median rejection)
#    18. sigma 1.0 k=10
#
#   Block G — Kitchen sinks (combined heavy lifters):
#    19. drizzle 2x scientific sigma 1.5 k=10  (lucky scientific drizzle clipped)
#    20. drizzle 3x scientific             k=5  (lucky scientific 3x drizzle)
#
# Multi-AP and two-stage are not in the matrix — empirical data
# proved they're net-negative on smooth planetary OSC.
#
# Usage:
#   scripts/sweep.sh <input.ser>     # run sweep on the given SER
#   scripts/sweep.sh                 # default to the BiggSky Jupiter

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SER="${1:-$REPO_ROOT/TESTIMAGES/biggsky/jupiter_2022-09-10-0649_2-GB-L-Jup_ZWO ASI224MC.ser}"
OUT="$REPO_ROOT/.regression/sweep"
mkdir -p "$OUT"
rm -f "$OUT"/*.tif 2>/dev/null || true

CLI=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -name astrosharper -type f -path '*Debug*' 2>/dev/null | head -1)
if [[ -z "${CLI:-}" || ! -x "$CLI" ]]; then
  echo "Building astrosharper CLI..." >&2
  xcodebuild -project "$REPO_ROOT/AstroSharper.xcodeproj" \
             -scheme AstroSharperCLI -configuration Debug \
             -destination 'platform=macOS,arch=arm64' build > /dev/null 2>&1
  CLI=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -name astrosharper -type f -path '*Debug*' 2>/dev/null | head -1)
fi

[[ -f "$SER" ]] || { echo "SER not found: $SER" >&2; exit 1; }
echo "CLI:    $CLI"
echo "SER:    $SER"
echo "Output: $OUT"
echo

n=0
run() {
  n=$((n + 1))
  local label=$1; shift
  local outfile=$(printf "%s/sweep_%02d_%s.tif" "$OUT" "$n" "$label")
  echo "==> $n  $label"
  "$CLI" stack "$SER" "$outfile" "$@" --quiet
}

# Block A — drizzle pixfrac sweep
run "drizzle2_pf03_k25"        --keep 25 --drizzle 2 --pixfrac 0.3
run "drizzle2_pf05_k25"        --keep 25 --drizzle 2 --pixfrac 0.5
run "drizzle2_pf07_k25"        --keep 25 --drizzle 2 --pixfrac 0.7
run "drizzle2_pf10_k25"        --keep 25 --drizzle 2 --pixfrac 1.0
run "drizzle3_pf05_k25"        --keep 25 --drizzle 3 --pixfrac 0.5
run "drizzle3_pf07_k25"        --keep 25 --drizzle 3 --pixfrac 0.7

# Block B — lucky drizzle (low keep%)
run "drizzle2_pf05_k05"        --keep 5  --drizzle 2 --pixfrac 0.5
run "drizzle2_pf07_k10"        --keep 10 --drizzle 2 --pixfrac 0.7
run "drizzle3_pf05_k05"        --keep 5  --drizzle 3 --pixfrac 0.5

# Block C — drizzle + scientific
run "drizzle2_scientific_k25"  --keep 25 --drizzle 2 --mode scientific
run "drizzle2_scientific_k10"  --keep 10 --drizzle 2 --mode scientific

# Block D — drizzle + sigma
run "drizzle2_sigma15_k25"     --keep 25 --drizzle 2 --sigma 1.5
run "drizzle2_sigma25_k10"     --keep 10 --drizzle 2 --sigma 2.5

# Block E — extreme keep-%
run "lightspeed_k02"           --keep 2
run "lightspeed_k99"           --keep 99
run "scientific_k02"           --keep 2  --mode scientific

# Block F — aggressive sigma
run "lightspeed_sigma08_k25"   --keep 25 --sigma 0.8
run "lightspeed_sigma10_k10"   --keep 10 --sigma 1.0

# Block G — kitchen sinks
run "kitchen_drizzle2_sci_sigma15_k10"  --keep 10 --drizzle 2 --mode scientific --sigma 1.5
run "kitchen_drizzle3_sci_k05"          --keep 5  --drizzle 3 --mode scientific

echo
echo "Done. ${n} outputs in $OUT/"
echo "File sizes are a quick orientation: 2.2MB ≈ 1x output, 8.9MB ≈"
echo "drizzle 2x (4x larger), 20MB ≈ drizzle 3x (9x larger)."
