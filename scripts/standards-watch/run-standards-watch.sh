#!/bin/bash
# Wrapper for the scheduled `quality-gate standards-watch` run (roseclub).
#
# Runs the drift monitor, archives each run's output, keeps a `-latest` copy,
# and on drift (non-zero exit) appends to a DRIFT log a human is expected to
# watch. Detect + alert only — it never edits a catalog.
#
# Env overrides: QG_BIN (binary path), LOG_DIR (log directory).
set -uo pipefail

QG_BIN="${QG_BIN:-/usr/local/custom/bin/quality-gate}"
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/quality-gate}"
mkdir -p "$LOG_DIR"

if [ ! -x "$QG_BIN" ]; then
    echo "quality-gate not found at $QG_BIN — build + install it first (see README.md)." >&2
    exit 127
fi

STAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
OUT="$LOG_DIR/standards-watch-$STAMP.log"

"$QG_BIN" standards-watch > "$OUT" 2>&1
CODE=$?

cp "$OUT" "$LOG_DIR/standards-watch-latest.log"

if [ "$CODE" -ne 0 ]; then
    {
        echo "=== DRIFT DETECTED $STAMP (exit $CODE) ==="
        cat "$OUT"
        echo ""
    } >> "$LOG_DIR/standards-watch-DRIFT.log"
    echo "DRIFT detected — see $LOG_DIR/standards-watch-DRIFT.log" >&2
fi

exit "$CODE"
