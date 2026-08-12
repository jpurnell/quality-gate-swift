// Placeholder. Do not commit a real commit hash here — see below.
//
// A file that records its own commit hash cannot be correct inside that commit: stamping commit
// X and committing the result produces commit Y, whose stamp says X. The tracked value is wrong
// by construction, so it is deliberately not a hash at all.
//
// `scripts/deploy-local.sh` and `make build` overwrite this before compiling and restore it
// afterwards, so the binary carries a real stamp and the working tree stays clean. It has been
// committed with a real hash twice — `d644d35` (Makefile, which had no restore) and `d0278e9`
// (after a deploy whose restore did not run) — which is why `house.build-stamp-committed` in
// `.quality-gate.yml` now fails the gate if a hash reappears here.
enum BuildStamp {
    static let gitCommit = "unstamped"
    static let buildDate = "unstamped"
}
