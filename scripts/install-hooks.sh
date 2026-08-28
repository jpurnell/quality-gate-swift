#!/bin/bash
# Installs a git pre-push hook that verifies a clean build and passing tests.
# Usage: ./scripts/install-hooks.sh [--force]
#
# Re-running updates hooks this script previously wrote. --force replaces hooks it
# did not write.

set -euo pipefail

HOOK_DIR="$(git rev-parse --show-toplevel)/.git/hooks"
HOOK_FILE="$HOOK_DIR/pre-push"

# Refusing outright to touch an existing hook made this script write-once: every
# repository that had ever run it was pinned to whatever the hook said that day, and a
# correction here reached none of them. That is how the pre-push hook stayed on the
# default checker set across the fleet. A hook this script wrote carries the marker
# below and is safe to replace; anything else is someone's own work and still needs
# --force.
MARKER="installed by scripts/install-hooks.sh"
FORCE="${1:-}"
if [ -f "$HOOK_FILE" ]; then
    if grep -q "$MARKER" "$HOOK_FILE" 2>/dev/null; then
        echo "Updating pre-push hook at $HOOK_FILE (previously installed by this script)"
    elif [ "$FORCE" = "--force" ]; then
        echo "Replacing pre-push hook at $HOOK_FILE (--force)"
    else
        echo "pre-push hook at $HOOK_FILE was not written by this script."
        echo "Inspect it, then re-run with --force to replace it."
        exit 1
    fi
fi

cat > "$HOOK_FILE" << 'HOOK'
#!/bin/bash
# quality-gate pre-push hook (installed by scripts/install-hooks.sh)
set -euo pipefail

# Drain the ref list git writes to our stdin, and keep the build tools off that
# pipe. Without this the hook runs, passes, prints its success line — and then
# git dies with SIGPIPE (exit 141) and the ref never moves. A push that reports
# success and does nothing is worse than one that fails, because the only
# evidence is a `git ls-remote` nobody runs.
#
# This is one of two mechanisms that produce that same silent failure, and it is
# not the one to remove if pushes start dying again. The other is the transport:
# git opens the ssh connection to the remote BEFORE running this hook, then
# leaves it idle for however long the build and tests take. The server drops an
# idle connection well before ten minutes, so git writes the pack to a closed
# socket and takes SIGPIPE after this hook has already printed success. The
# defence for that one lives in ~/.ssh/config, not here:
#
#     Host github.com
#         ServerAliveInterval 30
#         ServerAliveCountMax 40
#
# A push that landed under a hook WITHOUT this drain, but with those keepalives
# set, is on record (4470dfa) — so the two are complementary rather than
# alternatives. Keep both. Removing either leaves a failure whose only symptom
# is a ref that did not move.
#
# Related but distinct: `git push … | tail` reports tail's exit code, so the
# failure looks like a clean push. Verify by transfer — `git ls-remote origin
# <branch>` — never by exit status.
cat > /dev/null

# Run the gate, not a private copy of build+test.
#
# This hook used to invoke `swift build` and `swift test` directly. The gate runs both as
# checkers, so the coverage was duplicated — and because the hook never called the gate, it
# could not use the gate's result cache. Every push paid the full build and suite again,
# minutes after the pre-commit hook had just run them over the same tree. Measured at 308s on
# a push where nothing had changed since the commit.
#
# Running the gate instead is the same build and the same suite, plus the twenty-odd static
# checkers the raw commands never ran at all, and it is cache-aware.
#
# The fallback below matters: if the gate is not installed, verifying nothing is not an
# option, so the old commands still run.
QG_BIN="/usr/local/custom/bin/quality-gate"
if [[ ! -x "$QG_BIN" ]]; then
    echo "⚠️  quality-gate not found — falling back to build + test"
    swift build < /dev/null 2>&1 | tee /tmp/qg-build.log
    if grep -q "error:" /tmp/qg-build.log; then
        echo "ERROR: Build failed. Fix before pushing."
        exit 1
    fi
    if ! swift test < /dev/null 2>&1 | tee /tmp/qg-test.log; then
        echo "ERROR: Tests failed. Fix before pushing."
        exit 1
    fi
    echo "Pre-push passed (build + tests, no gate)."
    exit 0
fi

# `--check all`, not the default set.
#
# The default set omits the checkers that are opt-in on convention — `doc-run`,
# `doc-claims`, `doc-generated` — and `xcode-build`, which opts out on cost. A push
# is the last moment the omission is cheap to correct, and the omission is not
# theoretical: four iConquer repositories carried doc-run failures for two months
# (a crash, three hangs, one non-deterministic article) while every local gate run
# reported 0 errors, 0 warnings. Nothing was broken about the checker. It was simply
# never selected, and CI — which does pass `checks: "all"` — was disabled on two of
# the four and absent on a third.
#
# The cost is small where it is small: `xcode-build` is 1ms on a SwiftPM package with
# no project to build, and `doc-run` is ~0.65s per article on a healthy catalogue.
# Where it is expensive, it is expensive because there is something real to check.
echo "Pre-push: running quality gate (all checkers)..."
if "$QG_BIN" --check all < /dev/null 2>&1; then
    echo "Pre-push passed (quality gate)."
else
    echo ""
    echo "❌ Quality gate FAILED — push blocked."
    exit 1
fi
HOOK

chmod +x "$HOOK_FILE"
echo "Installed pre-push hook at $HOOK_FILE"

# ---------------------------------------------------------------------------
# pre-commit
#
# CLAUDE.md states that a pre-commit hook runs the gate on every commit. That was true of one
# machine and not of the repository: nothing here installed it, so a fresh clone had no
# pre-commit enforcement whatsoever while the documentation said otherwise. Installed here so
# the claim and the repository agree.
# ---------------------------------------------------------------------------
COMMIT_HOOK="$HOOK_DIR/pre-commit"
if [[ -f "$COMMIT_HOOK" ]] && ! grep -q "$MARKER" "$COMMIT_HOOK" 2>/dev/null && [ "$FORCE" != "--force" ]; then
    echo "pre-commit hook at $COMMIT_HOOK was not written by this script; left alone."
else
    cat > "$COMMIT_HOOK" << 'COMMITHOOK'
#!/bin/bash
# quality-gate pre-commit hook (installed by scripts/install-hooks.sh)
#
# Output is never truncated. This ran `| tail -3` for a time, which kept the summary line and
# discarded the findings above it — so a blocked commit reported only that it had been blocked.
# Reading three lines of a report is not reading the report.
set -uo pipefail

QG_BIN="/usr/local/custom/bin/quality-gate"
if [[ ! -x "$QG_BIN" ]]; then
    echo "⚠️  quality-gate not found — skipping pre-commit checks"
    exit 0
fi

echo "🔍 Running quality gate..."
if "$QG_BIN" 2>&1; then
    exit 0
else
    echo ""
    echo "❌ Quality gate FAILED — commit blocked."
    echo "   Fix the issues above. Never --no-verify."
    exit 1
fi
COMMITHOOK
    chmod +x "$COMMIT_HOOK"
    echo "Installed pre-commit hook at $COMMIT_HOOK"
fi
echo "pre-commit runs the default checker set; pre-push runs every checker."
echo "To remove: rm $HOOK_FILE"
