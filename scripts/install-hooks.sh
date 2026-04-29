#!/bin/bash
# Installs a git pre-push hook that runs the full quality gate.
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

echo "Running quality gate before push..."

swift build -c release 2>&1 | tee /tmp/qg-build.log
if grep -q "warning:" /tmp/qg-build.log; then
    echo "ERROR: Build produced compiler warnings. Fix before pushing."
    exit 1
fi

.build/release/quality-gate --check all --exclude disk-clean --exclude unreachable --strict --continue-on-failure

echo "Quality gate passed."
HOOK

chmod +x "$HOOK_FILE"
echo "Installed pre-push hook at $HOOK_FILE"
echo "The hook runs: quality-gate --check all --exclude disk-clean --exclude unreachable --strict"
echo "To remove: rm $HOOK_FILE"
