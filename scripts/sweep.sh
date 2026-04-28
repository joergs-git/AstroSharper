#!/usr/bin/env bash
#
# Stacking parameter sweep for empirical comparison against an external
# reference (e.g. BiggSky / Registax raw frame). Produces RAW (no
# post-stack sharpen) TIFFs in `.regression/sweep/` so the only thing
# varying between outputs is the stacking algorithm itself — colour
# casts and sharpening artifacts are off the table.
#
# WIDE-RANGE matrix (the previous narrow-step matrix produced
# essentially identical outputs because keep% 10..50 doesn't change
# enough on a typical planetary SER). This version stretches every
# axis to its extremes so output differences become visually obvious:
#
#   1. keep%     1, 5, 10, 25, 50, 99     (lucky imaging vs averaging)
#   2. mode      lightspeed, scientific
#   3. sigma     off, 1.0 (aggressive ≈ median), 1.5, 2.5, 4.0 (≈ no clip)
#   4. drizzle   1x, 2x, 3x
#   5. two-stage off, AP grid 4 / 8 / 16
#
# Pure cartesian would be 6×2×5×3×4 = 720; the matrix below picks 20
# combinations that span the parameter space with minimal redundancy.
# Multi-AP is left OFF — empirical data showed it's net-negative on
# smooth planetary OSC and adds nothing to the comparison.
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

# Axis 1: keep% spread (lightspeed mode, the proven baseline). Tests
# whether 'lucky imaging' (k=1) genuinely beats the averaged stack.
run "lightspeed_k01"           --keep 1
run "lightspeed_k05"           --keep 5
run "lightspeed_k10"           --keep 10
run "lightspeed_k25"           --keep 25
run "lightspeed_k50"           --keep 50
run "lightspeed_k99"           --keep 99

# Axis 2: scientific mode at the same keep% extremes. Tests whether
# the cleaner-reference build is doing real work vs lightspeed.
run "scientific_k01"           --keep 1   --mode scientific
run "scientific_k05"           --keep 5   --mode scientific
run "scientific_k25"           --keep 25  --mode scientific
run "scientific_k99"           --keep 99  --mode scientific

# Axis 3: sigma-clip extremes. sigma 1.0 ≈ median, sigma 4.0 ≈ no
# clipping. If aggressive sigma is sharper, frame-level outlier
# rejection is doing useful work.
run "lightspeed_k25_sigma10"   --keep 25  --sigma 1.0
run "lightspeed_k25_sigma15"   --keep 25  --sigma 1.5
run "lightspeed_k25_sigma25"   --keep 25  --sigma 2.5
run "lightspeed_k25_sigma40"   --keep 25  --sigma 4.0

# Axis 4: drizzle reconstruction. 2x output is 2x larger; 3x is 3x
# larger. Tests whether reverse-mapping recovers detail averaging
# loses on this SER.
run "lightspeed_k25_drizzle2"  --keep 25  --drizzle 2
run "lightspeed_k25_drizzle3"  --keep 25  --drizzle 3
run "lightspeed_k05_drizzle2"  --keep 5   --drizzle 2

# Axis 5: two-stage per-AP keep at different grid sizes. AP grid 4
# is coarse (16 cells), 16 is fine (256 cells).
run "lightspeed_k25_twostage4"  --keep 25  --two-stage --two-stage-grid 4
run "lightspeed_k25_twostage16" --keep 25  --two-stage --two-stage-grid 16

# Combos: lucky-imaging (low k) + sigma-clip = strict 'best frames
# only, then reject pixel outliers within them'.
run "lightspeed_k05_sigma15"   --keep 5   --sigma 1.5

echo
echo "Done. ${n} outputs in $OUT/"
echo "Compare them in Preview against your external reference (BiggSky /"
echo "Registax raw frame). Wide-range axes mean every output should now"
echo "look visibly distinct from its neighbours."
