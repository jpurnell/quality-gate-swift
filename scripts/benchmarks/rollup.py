#!/usr/bin/env python3
"""Roll up every run from bench2.sh: wall clock vs gate-reported total vs sum of checker durations.

The `outside-checkers` column is wall minus the sum of per-checker durations. In a SEQUENTIAL
run it is real unaccounted time. In a PARALLEL run it goes negative simply because durations
overlap, so it is only meaningful for the sequential rows.

Reads *.json / walls2.txt from $QG_BENCH_OUT (default $TMPDIR/qg-bench).
"""
import json
import os
import sys
import tempfile

S = os.environ.get("QG_BENCH_OUT") or os.path.join(tempfile.gettempdir(), "qg-bench")
LABELS = ["full_seq_first", "full_par_second",
          "ast_seq_1", "ast_par_1", "ast_par_2", "ast_seq_2"]

walls = {}
with open(os.path.join(S, "walls2.txt")) as f:
    for line in f:
        parts = line.split()
        if len(parts) >= 3 and parts[1] == "wall_seconds":
            walls[parts[0]] = float(parts[2])

for label in LABELS:
    path = os.path.join(S, label + ".json")
    if not os.path.exists(path):
        print(f"{label}: MISSING", file=sys.stderr)
        continue
    with open(path) as f:
        d = json.load(f)
    durs = {r["checkerId"]: r["duration"][0] + r["duration"][1] / 1e18
            for r in d["results"]}
    s = sum(durs.values())
    w = walls[label]
    gt = d["summary"]["totalDuration"]
    slow = max(durs.items(), key=lambda kv: kv[1])
    print(f"{label:<17} wall={w:7.2f}  gateTotal={gt:7.2f}  sumDur={s:7.2f}  "
          f"n={len(durs):2d}  slowest={slow[0]}@{slow[1]:.2f}  "
          f"outside-checkers={w - s:6.2f}")
