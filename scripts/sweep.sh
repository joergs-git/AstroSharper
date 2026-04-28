#!/usr/bin/env bash
#
# Stacking parameter sweep for empirical comparison against an external
# reference (e.g. BiggSky / Registax raw frame). Produces 20 RAW (no
# post-stack sharpen) TIFFs in `.regression/sweep/` so the only thing
# varying between outputs is the stacking algorithm itself — colour
# casts and sharpening artifacts are off the table.
#
# Sweep matrix (20 = 7 + 7 + 4 + 2):
#   1.  lightspeed mode, keep% in {10, 15, 20, 25, 30, 40, 50}
#   2.  scientific mode, keep% in {10, 15, 20, 25, 30, 40, 50}
#   3.  lightspeed + sigma-clip, k=25, sigma in {1.5, 2.0, 2.5, 3.0}
#   4.  scientific + sigma-clip, k=25, sigma in {2.0, 2.5}
#
# Drizzle / multi-AP / two-stage are deliberately OFF — empirical data
# from earlier rounds showed all three were net-negative on smooth
# planetary OSC. Re-add them to the matrix for lunar / solar captures
# where local feature contrast favours multi-AP.
#
# Usage:
#   scripts/sweep.sh <input.ser>         # run sweep on the given SER
#   scripts/sweep.sh                     # default to the BiggSky Jupiter

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SER="${1:-$REPO_ROOT/TESTIMAGES/biggsky/jupiter_2022-09-10-0649_2-GB-L-Jup_ZWO ASI224MC.ser}"
OUT="$REPO_ROOT/.regression/sweep"
mkdir -p "$OUT"
rm -f "$OUT"/*.tif 2>/dev/null || true

# Locate the CLI (build first if not present).
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

for k in 10 15 20 25 30 40 50; do
  run "lightspeed_k${k}" --keep "$k"
done
for k in 10 15 20 25 30 40 50; do
  run "scientific_k${k}" --keep "$k" --mode scientific
done
for s in 1.5 2.0 2.5 3.0; do
  run "lightspeed_k25_sigma${s/./_}" --keep 25 --sigma "$s"
done
for s in 2.0 2.5; do
  run "scientific_k25_sigma${s/./_}" --keep 25 --mode scientific --sigma "$s"
done

echo
echo "Done. ${n} outputs in $OUT/"
echo "Compare them in Preview against your external reference (BiggSky /"
echo "Registax raw frame). The pure stacking differences are now visible"
echo "without sharpening artifacts masking the algorithm."
