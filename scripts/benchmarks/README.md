# Gate benchmarks

Scripts backing `project/summaries/BLOG_POST_SUBPROCESS_MEASUREMENT.md`, which asked whether
adopting [swift-subprocess 1.0](https://github.com/swiftlang/swift-subprocess) would speed up the
gate. It would not, on macOS — measured benefit was 0%.

Keep these runnable: the writeup is only useful if its numbers can be re-derived.

## Output location

Every script reads and writes `$QG_BENCH_OUT`, defaulting to `$TMPDIR/qg-bench`. Nothing is
written into the repo. Set it explicitly to keep a run around:

```
export QG_BENCH_OUT=~/qg-bench-2026-08-06
```

## The scripts

| Script | What it does |
|---|---|
| `bench.sh` | Full gate, default concurrency vs `QG_BENCH_CONCURRENCY=1`, A-then-B **once** |
| `analyze.py` | Per-checker table for the two `bench.sh` runs |
| `bench2.sh` | The corrected experiment: reversed order + an AST-only set, alternating |
| `rollup.py` | Wall vs gate-reported total vs sum-of-checker-durations for each `bench2.sh` run |
| `starve.swift` | Micro-benchmark: does a blocking `Process` wait starve the cooperative pool? |

`bench.sh` is **deliberately confounded** and kept as a demonstration. It runs A-then-B once, so
SwiftPM's build cache leaks from the first run into the second. In the recorded session it reported
concurrency as 26% *slower* — the exact opposite of the truth. `--no-cache` disables quality-gate's
result cache; it does nothing to `.build`. Use `bench2.sh` for real answers, and check that its
repeated runs agree before believing anything.

## Running them

```
./bench.sh   && ./analyze.py     # ~4 min — the trap
./bench2.sh  && ./rollup.py      # ~4 min — the corrected experiment

swiftc -O -parse-as-library -o "${QG_BENCH_OUT:-${TMPDIR}/qg-bench}/starve" starve.swift
CPU_TASKS=26 SPAWN_TASKS=4  "${QG_BENCH_OUT:-${TMPDIR}/qg-bench}/starve"   # ~25s
CPU_TASKS=20 SPAWN_TASKS=20 "${QG_BENCH_OUT:-${TMPDIR}/qg-bench}/starve"   # ~40s
```

`starve.swift` is tunable via `CPU_TASKS`, `SPAWN_TASKS`, `CPU_ITERS`, `SLEEP`, `TRIALS`.

## Two traps worth remembering

1. **`-O` deletes benchmark workloads whose results are unused.** The first draft of
   `starve.swift` discarded its CPU result and the optimizer removed the loop entirely; every
   trial then measured nothing but the sleeps. The `sink` mutex and `@inline(never)` defeat that.
   Suspiciously round numbers usually mean the work vanished.
2. **Task plans must match their labels.** An intermediate version printed `spawnTasks=14` while
   actually spawning 20. `taskPlan()` now distributes exactly `SPAWN_TASKS` and the program prints
   what it actually ran.

## Headline results (M1 Max, 10 cores, Swift 6.4, quality-gate 2.0.1)

- Blocking vs async subprocess waits: **1.00x**, 6 trials, even with 20 tasks blocked on a 10-wide
  pool. Darwin's pthread workqueue replaces workers blocked in syscalls, so the pool doesn't starve.
- `CheckerRunner` concurrency: 1.37x full set, ~2.0x AST-only — but per-checker work inflates ~1.9x
  under contention, so effective parallelism is ~3.0, not 10. Cause is redundant tree parsing.
- ~35s of a 92s sequential run is attributed to no checker at all. Biggest open lead.
