#!/usr/bin/env bash
#
# AstroSharper regression harness (F3 v0).
#
# Walks TESTIMAGES/ recursively, runs `astrosharper analyze --json` on
# every .ser file, writes the per-file metrics JSON to
# .regression/current/, and diffs the result against the committed
# baselines under Tests/Regression/baselines/.
#
# v0 covers SER metadata (header parsing, frame count, capture date,
# bytes per frame). Once Block A's quality intelligence + the CLI
# `stack` subcommand land, the same harness picks up sharpness, SNR,
# alignment RMS, and runtime metrics — same diff-against-baseline
# pattern.
#
# Usage:
#   scripts/regression.sh                  diff vs committed baselines
#   scripts/regression.sh --update-baseline overwrite baselines from
#                                          the current run (use after
#                                          intentional algorithm changes)
#
# Exit codes:
#   0  all SERs match baseline (or first run, baselines established)
#   1  regression detected on at least one file
#   2  setup / build failure

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTIMAGES="$REPO_ROOT/TESTIMAGES"
BASELINE_DIR="$REPO_ROOT/Tests/Regression/baselines"
WORK_DIR="$REPO_ROOT/.regression"
CURRENT_DIR="$WORK_DIR/current"
RUN_LOG="$WORK_DIR/run-$(date -u +%Y%m%dT%H%M%SZ).log"

UPDATE_BASELINE=0
if [[ "${1:-}" == "--update-baseline" ]]; then
  UPDATE_BASELINE=1
fi

mkdir -p "$CURRENT_DIR" "$BASELINE_DIR"

# --- Locate / build the CLI binary ---------------------------------------

find_cli() {
  find "$HOME/Library/Developer/Xcode/DerivedData" \
       -name astrosharper -type f -path '*Debug*' 2>/dev/null | head -1
}

CLI_BIN="$(find_cli)"
if [[ -z "${CLI_BIN:-}" || ! -x "$CLI_BIN" ]]; then
  echo "Building astrosharper CLI (Debug, arm64)..."
  if ! xcodebuild \
        -project "$REPO_ROOT/AstroSharper.xcodeproj" \
        -scheme AstroSharperCLI \
        -configuration Debug \
        -destination 'platform=macOS,arch=arm64' \
        build > "$WORK_DIR/last-build.log" 2>&1
  then
    echo "BUILD FAILED — see $WORK_DIR/last-build.log" >&2
    exit 2
  fi
  CLI_BIN="$(find_cli)"
fi

if [[ -z "${CLI_BIN:-}" || ! -x "$CLI_BIN" ]]; then
  echo "Could not locate astrosharper CLI binary after build." >&2
  exit 2
fi

echo "CLI:        $CLI_BIN"
echo "TESTIMAGES: $TESTIMAGES"
echo "Baselines:  $BASELINE_DIR"
echo "Run log:    $RUN_LOG"
echo

if [[ ! -d "$TESTIMAGES" ]]; then
  echo "TESTIMAGES dir missing — nothing to validate (this is OK)."
  exit 0
fi

# --- Walk SERs and run analyze ------------------------------------------

PASSED=0
REGRESSED=0
NEW_BASELINES=0
ERRORED=0

# Stable slug for a TESTIMAGES-relative path: replace "/" with "__" and
# spaces with "_". Encoded into the baseline / current filename so we
# don't lose the structure under TESTIMAGES.
slug_for() {
  local rel="$1"
  rel="${rel//\//__}"
  rel="${rel// /_}"
  printf '%s' "$rel"
}

while IFS= read -r ser; do
  rel="${ser#$TESTIMAGES/}"
  slug="$(slug_for "$rel")"
  out="$CURRENT_DIR/$slug.json"
  base="$BASELINE_DIR/$slug.json"

  if ! "$CLI_BIN" analyze --json "$ser" > "$out" 2>>"$RUN_LOG"; then
    echo "[ERROR ] $rel — analyze exited non-zero (see log)"
    ERRORED=$((ERRORED + 1))
    continue
  fi

  if (( UPDATE_BASELINE )); then
    cp "$out" "$base"
    echo "[BASE  ] $rel"
    NEW_BASELINES=$((NEW_BASELINES + 1))
    continue
  fi

  if [[ -f "$base" ]]; then
    if diff -q "$base" "$out" >/dev/null 2>&1; then
      echo "[OK    ] $rel"
      PASSED=$((PASSED + 1))
    else
      echo "[DRIFT ] $rel"
      diff "$base" "$out" | sed 's/^/         /' | head -20
      REGRESSED=$((REGRESSED + 1))
    fi
  else
    cp "$out" "$base"
    echo "[NEW   ] $rel — baseline written"
    NEW_BASELINES=$((NEW_BASELINES + 1))
  fi
done < <(find "$TESTIMAGES" -type f -name '*.ser' 2>/dev/null | sort)

echo
TOTAL=$((PASSED + REGRESSED + NEW_BASELINES + ERRORED))
echo "Summary: ${TOTAL} files; ${PASSED} ok, ${REGRESSED} drift, ${NEW_BASELINES} new, ${ERRORED} errors"
echo "Results: $CURRENT_DIR"

if (( ERRORED > 0 )); then
  exit 2
fi
if (( REGRESSED > 0 )); then
  exit 1
fi
exit 0
