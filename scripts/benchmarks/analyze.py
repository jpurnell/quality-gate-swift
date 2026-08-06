#!/usr/bin/env python3
"""Per-checker comparison of the two runs produced by bench.sh.

Reads parallel.json / sequential.json / walls.txt from $QG_BENCH_OUT
(default $TMPDIR/qg-bench).
"""
import json
import os
import tempfile

S = os.environ.get("QG_BENCH_OUT") or os.path.join(tempfile.gettempdir(), "qg-bench")


def load(label):
    with open(os.path.join(S, label + ".json")) as f:
        d = json.load(f)
    out = {}
    for r in d["results"]:
        sec, atto = r["duration"]
        out[r["checkerId"]] = (sec + atto / 1e18, r["status"])
    return out, d["summary"]


walls = {}
with open(os.path.join(S, "walls.txt")) as f:
    for line in f:
        parts = line.split()
        if len(parts) == 3:
            walls[parts[0]] = float(parts[2])

par, psum = load("parallel")
seq, ssum = load("sequential")

print(f"{'checker':<28} {'parallel':>10} {'sequential':>11}  status")
print("-" * 64)
rows = sorted(par.items(), key=lambda kv: -kv[1][0])
for cid, (dur, st) in rows:
    sdur = seq.get(cid, (float("nan"),))[0]
    print(f"{cid:<28} {dur:>10.3f} {sdur:>11.3f}  {st}")

psum_dur = sum(d for d, _ in par.values())
ssum_dur = sum(d for d, _ in seq.values())
print("-" * 64)
print(f"{'SUM of checker durations':<28} {psum_dur:>10.3f} {ssum_dur:>11.3f}")
print(f"{'gate-reported total':<28} {psum['totalDuration']:>10.3f} {ssum['totalDuration']:>11.3f}")
print(f"{'WALL CLOCK':<28} {walls.get('parallel', float('nan')):>10.3f} "
      f"{walls.get('sequential', float('nan')):>11.3f}")
print()
print(f"checkers run: parallel={len(par)} sequential={len(seq)}")
wp, ws = walls.get("parallel"), walls.get("sequential")
if wp and ws:
    print(f"speedup from concurrency (wall): {ws / wp:.2f}x  (saved {ws - wp:.1f}s)")
    print(f"parallel-phase efficiency: sum/wall = {psum_dur / wp:.2f}x effective parallelism")
slowest = rows[0]
print(f"slowest single checker: {slowest[0]} @ {slowest[1][0]:.2f}s")
print(f"ideal wall if perfectly parallel (>= slowest checker): {slowest[1][0]:.2f}s")
