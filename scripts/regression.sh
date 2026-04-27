#!/usr/bin/env bash
#
# AstroSharper regression harness.
#
# Walks TESTIMAGES/ recursively and runs two CLI subcommands per SER
# file:
#
#   1. `analyze --json`  → metadata baseline (frame count, dims,
#                          colourID, capture date, …). Stable across
#                          algorithm changes — drift here means the
#                          SER reader broke.
#
#   2. `stack --keep N`  → real lucky-stack output + metrics JSON
#                          (input/output filenames, keepPercent,
#                          outputBytes). Drift here means a stacking
#                          algorithm change altered the output. The
#                          non-deterministic `elapsedSeconds` field is
#                          stripped before diffing so timing variance
#                          doesn't trigger false-positive drift.
#
# Both per-SER metric files land in `Tests/Regression/baselines/` and
# are diffed against the committed baseline; the diff exits non-zero
# on any drift.
#
# Usage:
#   scripts/regression.sh                  diff vs committed baselines
#   scripts/regression.sh --update-baseline overwrite baselines from
#                                          the current run (use after
#                                          intentional algorithm changes)
#   scripts/regression.sh --skip-stack     analyze only — fast path for
#                                          the metadata-only sanity check
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
STACK_OUT_DIR="$WORK_DIR/stack-output"

# Stack defaults — chosen for speed (low keep-% on long captures runs
# the stacking phase fast). Override per-environment if needed.
STACK_KEEP="${STACK_KEEP:-25}"

UPDATE_BASELINE=0
SKIP_STACK=0
for arg in "$@"; do
  case "$arg" in
    --update-baseline) UPDATE_BASELINE=1 ;;
    --skip-stack)      SKIP_STACK=1 ;;
    *) echo "regression: unknown flag '$arg'" >&2; exit 64 ;;
  esac
done

mkdir -p "$CURRENT_DIR" "$BASELINE_DIR" "$STACK_OUT_DIR"

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
echo "Skip stack: $SKIP_STACK"
echo "Stack keep: $STACK_KEEP%"
echo

if [[ ! -d "$TESTIMAGES" ]]; then
  echo "TESTIMAGES dir missing — nothing to validate (this is OK)."
  exit 0
fi

# --- Helpers --------------------------------------------------------------

# Stable slug for a TESTIMAGES-relative path: replace "/" with "__"
# and spaces with "_".
slug_for() {
  local rel="$1"
  rel="${rel//\//__}"
  rel="${rel// /_}"
  printf '%s' "$rel"
}

# Strip the elapsedSeconds field (and any other non-deterministic
# fields) from a stack metrics JSON before diffing. Falls back to a
# simple grep filter when jq isn't available.
strip_volatile_fields() {
  local in_path="$1"
  local out_path="$2"
  if command -v jq >/dev/null 2>&1; then
    jq 'del(.elapsedSeconds)' "$in_path" > "$out_path"
  else
    grep -v '"elapsedSeconds"' "$in_path" > "$out_path"
  fi
}

run_compare() {
  # $1 = current file, $2 = baseline file, $3 = label, $4 = "stable"
  # to apply strip_volatile_fields before diffing AND before writing
  # the baseline (so committed baselines are deterministic across
  # machines / runs).
  local cur="$1"
  local base="$2"
  local label="$3"
  local mode="${4:-direct}"

  local toCompare="$cur"
  local toCommit="$cur"
  if [[ "$mode" == "stable" ]]; then
    # Strip volatile fields into a scratch file under WORK_DIR (NOT
    # under BASELINE_DIR — that one is committed and stays clean).
    local scratch="$WORK_DIR/scratch-$(basename "${cur%.json}").stable.json"
    strip_volatile_fields "$cur" "$scratch"
    toCompare="$scratch"
    toCommit="$scratch"
  fi

  if (( UPDATE_BASELINE )); then
    cp "$toCommit" "$base"
    echo "[BASE  ] ${label}"
    return 2
  fi

  if [[ -f "$base" ]]; then
    if diff -q "$base" "$toCompare" >/dev/null 2>&1; then
      echo "[OK    ] ${label}"
      return 0
    else
      echo "[DRIFT ] ${label}"
      diff "$base" "$toCompare" | sed 's/^/         /' | head -20
      return 1
    fi
  else
    cp "$toCommit" "$base"
    echo "[NEW   ] ${label} — baseline written"
    return 2
  fi
}

# --- Walk SERs ------------------------------------------------------------

PASSED=0
REGRESSED=0
NEW_BASELINES=0
ERRORED=0

while IFS= read -r ser; do
  rel="${ser#$TESTIMAGES/}"
  slug="$(slug_for "$rel")"

  # 1. analyze
  analyze_cur="$CURRENT_DIR/$slug.analyze.json"
  analyze_base="$BASELINE_DIR/$slug.json"   # legacy filename — keep for back-compat
  if ! "$CLI_BIN" analyze --json "$ser" > "$analyze_cur" 2>>"$RUN_LOG"; then
    echo "[ERROR ] $rel — analyze exited non-zero (see log)"
    ERRORED=$((ERRORED + 1))
    continue
  fi
  set +e
  run_compare "$analyze_cur" "$analyze_base" "$rel (analyze)" "direct"
  rc=$?
  set -e
  case $rc in
    0) PASSED=$((PASSED + 1)) ;;
    1) REGRESSED=$((REGRESSED + 1)) ;;
    2) NEW_BASELINES=$((NEW_BASELINES + 1)) ;;
  esac

  # 2. stack (skipped via --skip-stack for fast metadata-only runs)
  if (( ! SKIP_STACK )); then
    stack_out="$STACK_OUT_DIR/$slug.stack.tif"
    metrics_cur="$CURRENT_DIR/$slug.stack.json"
    metrics_base="$BASELINE_DIR/$slug.stack.json"
    if ! "$CLI_BIN" stack "$ser" "$stack_out" \
          --keep "$STACK_KEEP" \
          --metrics "$metrics_cur" \
          --quiet >>"$RUN_LOG" 2>&1
    then
      echo "[ERROR ] $rel — stack exited non-zero (see log)"
      ERRORED=$((ERRORED + 1))
      continue
    fi
    set +e
    run_compare "$metrics_cur" "$metrics_base" "$rel (stack p${STACK_KEEP})" "stable"
    rc=$?
    set -e
    case $rc in
      0) PASSED=$((PASSED + 1)) ;;
      1) REGRESSED=$((REGRESSED + 1)) ;;
      2) NEW_BASELINES=$((NEW_BASELINES + 1)) ;;
    esac
  fi
done < <(find "$TESTIMAGES" -type f -name '*.ser' 2>/dev/null | sort)

echo
TOTAL=$((PASSED + REGRESSED + NEW_BASELINES + ERRORED))
echo "Summary: ${TOTAL} comparisons; ${PASSED} ok, ${REGRESSED} drift, ${NEW_BASELINES} new, ${ERRORED} errors"
echo "Results: $CURRENT_DIR"
if (( ! SKIP_STACK )); then
  echo "Stack outputs: $STACK_OUT_DIR"
fi

if (( ERRORED > 0 )); then
  exit 2
fi
if (( REGRESSED > 0 )); then
  exit 1
fi
exit 0
