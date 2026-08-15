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

echo "Pre-push: verifying build compiles clean..."
swift build < /dev/null 2>&1 | tee /tmp/qg-build.log
if grep -q "error:" /tmp/qg-build.log; then
    echo "ERROR: Build failed. Fix before pushing."
    exit 1
fi

echo "Pre-push: running test suite..."
if ! swift test < /dev/null 2>&1 | tee /tmp/qg-test.log; then
    echo "ERROR: Tests failed. Fix before pushing."
    exit 1
fi

echo "Pre-push passed (build + tests)."
HOOK

chmod +x "$HOOK_FILE"
echo "Installed pre-push hook at $HOOK_FILE"
echo "The hook verifies a clean build and passing tests before push."
echo "To remove: rm $HOOK_FILE"
