#!/bin/zsh
# Concurrency comparison for quality-gate: default (core count) vs forced sequential.
# Both runs use --no-cache so every checker actually executes.
#
# NOTE: this script runs A-then-B once and is therefore CONFOUNDED by SwiftPM's build cache.
# It is kept because it demonstrates the trap — see bench2.sh for the corrected experiment
# and BLOG_POST_SUBPROCESS_MEASUREMENT.md for the analysis.
set -u
zmodload zsh/datetime
REPO="${0:A:h}/../.."
OUT="${QG_BENCH_OUT:-${TMPDIR:-/tmp}/qg-bench}"
mkdir -p "$OUT"
cd "$REPO" || exit 1

COMMON=(--check all --exclude disk-clean --exclude test --continue-on-failure --no-cache)

run_one() {
  local label="$1"; shift
  local out="$OUT/${label}.json"
  echo "=== $label starting $(date +%T) ==="
  local t0=$EPOCHREALTIME
  "$@" quality-gate "${COMMON[@]}" --summary-output "$out" >"$OUT/${label}.log" 2>&1
  local rc=$?
  local t1=$EPOCHREALTIME
  echo "$label wall=$(printf '%.2f' $((t1 - t0))) rc=$rc"
  echo "$label wall_seconds $(printf '%.3f' $((t1 - t0)))" >> "$OUT/walls.txt"
}

: > "$OUT/walls.txt"

# Warm any shared build state first so run A doesn't pay a one-time cost run B avoids.
# (Insufficient in practice — that is the point of this script.)
echo "=== warmup $(date +%T) ==="
quality-gate --check safety --continue-on-failure >/dev/null 2>&1

run_one parallel  env
run_one sequential env QG_BENCH_CONCURRENCY=1

echo "=== done $(date +%T) ==="
cat "$OUT/walls.txt"
echo "results in $OUT"
