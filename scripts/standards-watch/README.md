# Scheduling `standards-watch` (roseclub)

Runs `quality-gate standards-watch` on a weekly schedule so regulatory drift in
the compliance catalogs surfaces as a dated alert instead of a surprise at audit
time. **Detect + alert only** — the job never edits a catalog; a human
reconciles.

## What it does each run

- Hashes the live HIPAA §164.312 text from the eCFR API and compares it to the
  catalog's `upstreamHash` → `unchanged` / `drifted`.
- Surfaces recent **proposed** rules touching 45 CFR 164 from the Federal
  Register (early warning, before the eCFR text changes).
- Reports SOC 2 / ISO as `manual` (copyrighted; not machine-readable).
- Exits non-zero on drift; the wrapper appends drift to `…/standards-watch-DRIFT.log`.

## Deploy (on roseclub — needs your SSH + sudo)

> The Swift toolchains drift (local 6.4 vs server 6.3.3) — build **on** the
> server, don't cross-compile. These steps are manual; run them yourself.

```bash
# 1. Build + install the binary on the server (from the repo checkout there)
make build && sudo make install        # -> /usr/local/custom/bin/quality-gate

# 2. Install the wrapper
sudo install -d /usr/local/custom/share/quality-gate
sudo install -m 755 scripts/standards-watch/run-standards-watch.sh \
    /usr/local/custom/share/quality-gate/run-standards-watch.sh

# 3. Load the launchd job (per-user LaunchAgent)
cp scripts/standards-watch/org.roseclub.quality-gate.standards-watch.plist \
    ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/org.roseclub.quality-gate.standards-watch.plist

# 4. Verify it runs now (one-off), then check the log
launchctl start org.roseclub.quality-gate.standards-watch
cat ~/Library/Logs/quality-gate/standards-watch-latest.log
```

## Reacting to drift

`DRIFTED` means the upstream regulation text changed since it was last observed.
Reconcile before trusting the mapping:

1. Diff the eCFR text; update the catalog's control text and the rule→control
   mapping as needed.
2. Re-seed the catalog's `upstreamHash` (run `standards-watch` once → it reports
   `seeded` with the new hash → record it).
3. Bump the catalog's `reviewed` / `reviewedBy`; clear any `superseded` flag.
4. Commit through the gate.

## Notes

- Network only — never in the gate's enforcement path.
- The eCFR source URL carries a `{date}` the binary fills with today's UTC date;
  the versioner normalizes the date out of the content, so the hash is stable
  day-to-day and changes only on a real amendment.
