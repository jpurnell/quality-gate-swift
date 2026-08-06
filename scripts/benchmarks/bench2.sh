#!/bin/zsh
# Experiment 2: control for the run-order / build-cache confound that ruins bench.sh.
#  (a) full set, REVERSE order (sequential first)
#  (b) AST-only set (no checker that touches .build), alternating order
#
# Repeats must agree for the result to be believable — in the recorded run the two
# sequential AST runs differed by 0.24s.
set -u
zmodload zsh/datetime
REPO="${0:A:h}/../.."
OUT="${QG_BENCH_OUT:-${TMPDIR:-/tmp}/qg-bench}"
mkdir -p "$OUT"
cd "$REPO" || exit 1

run_one() {
  local label="$1"; shift
  local mode="$1"; shift
  local out="$OUT/${label}.json"
  local t0=$EPOCHREALTIME
  if [[ "$mode" == "seq" ]]; then
    QG_BENCH_CONCURRENCY=1 quality-gate "$@" --summary-output "$out" >"$OUT/${label}.log" 2>&1
  else
    quality-gate "$@" --summary-output "$out" >"$OUT/${label}.log" 2>&1
  fi
  local rc=$?
  local t1=$EPOCHREALTIME
  echo "$label wall_seconds $(printf '%.3f' $((t1 - t0))) rc=$rc" | tee -a "$OUT/walls2.txt"
}

: > "$OUT/walls2.txt"

FULL=(--check all --exclude disk-clean --exclude test --continue-on-failure --no-cache)
# AST-only: drop every checker that shells out to swift/xcodebuild/git-heavy work
AST=(--check all --exclude disk-clean --exclude test --exclude build --exclude doc-lint
     --exclude unreachable --exclude xcode-build --exclude status --exclude memory-builder
     --continue-on-failure --no-cache)

echo "=== (a) FULL set, reverse order: sequential first  $(date +%T) ==="
run_one full_seq_first seq "${FULL[@]}"
run_one full_par_second par "${FULL[@]}"

echo "=== (b) AST-only set, alternating  $(date +%T) ==="
run_one ast_seq_1 seq "${AST[@]}"
run_one ast_par_1 par "${AST[@]}"
run_one ast_par_2 par "${AST[@]}"
run_one ast_seq_2 seq "${AST[@]}"

echo "=== done $(date +%T) ==="
cat "$OUT/walls2.txt"
echo "results in $OUT"
