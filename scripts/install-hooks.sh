#!/bin/bash
# Installs a git pre-push hook that verifies a clean build and passing tests.
# Usage: ./scripts/install-hooks.sh

set -euo pipefail

HOOK_DIR="$(git rev-parse --show-toplevel)/.git/hooks"
HOOK_FILE="$HOOK_DIR/pre-push"

if [ -f "$HOOK_FILE" ]; then
    echo "pre-push hook already exists at $HOOK_FILE"
    echo "Remove it first if you want to reinstall."
    exit 1
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

echo "Pre-push: running quality gate..."
if "$QG_BIN" < /dev/null 2>&1; then
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
if [[ -f "$COMMIT_HOOK" ]]; then
    echo "pre-commit hook already exists at $COMMIT_HOOK"
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
echo "The hook verifies a clean build and passing tests before push."
echo "To remove: rm $HOOK_FILE"
