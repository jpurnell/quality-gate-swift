#!/bin/bash
# Installs a git pre-push hook that verifies a clean build.
# Full quality gate runs in CI — the hook is kept fast to avoid SSH timeouts.
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
# Kept fast to avoid SSH timeouts. Full quality gate runs in CI.
set -euo pipefail

echo "Pre-push: verifying build compiles clean..."
swift build 2>&1 | tee /tmp/qg-build.log
if grep -q "error:" /tmp/qg-build.log; then
    echo "ERROR: Build failed. Fix before pushing."
    exit 1
fi

echo "Pre-push passed. Full quality gate will run in CI."
HOOK

chmod +x "$HOOK_FILE"
echo "Installed pre-push hook at $HOOK_FILE"
echo "The hook verifies a clean build. Full quality gate runs in CI."
echo "To remove: rm $HOOK_FILE"
