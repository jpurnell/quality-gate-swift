#!/bin/bash
# quality-gate-swift git hook installer
# Installs pre-commit and pre-push hooks for quality gate enforcement.
# Idempotent: safe to re-run. Updates managed hooks, skips custom hooks.
#
# Usage: ./development-guidelines/scripts/install-hooks.sh

set -euo pipefail

MARKER="# quality-gate-swift managed hook"
HOOK_DIR="$(git rev-parse --show-toplevel 2>/dev/null)/.git/hooks" || {
    echo "ERROR: Not in a git repository. Run from inside a git project."
    exit 1
}

install_hook() {
    local hook_name="$1"
    local hook_content="$2"
    local hook_file="$HOOK_DIR/$hook_name"

    if [ -f "$hook_file" ]; then
        if head -3 "$hook_file" | grep -q "$MARKER"; then
            echo "  Updating $hook_name hook (managed by quality-gate-swift)..."
        else
            echo "  SKIPPED $hook_name — custom hook exists. Remove it first to install managed hook."
            return
        fi
    else
        echo "  Installing $hook_name hook..."
    fi

    echo "$hook_content" > "$hook_file"
    chmod +x "$hook_file"
}

# --- Pre-commit hook ---
PRE_COMMIT_HOOK=$(cat << 'HOOK'
#!/bin/bash
# quality-gate-swift managed hook
# Runs fast AST-based quality checks before every commit.
# Matches the CI self-validation config (excludes slow process-spawning checks).
# Escape hatch: QG_SKIP=1 git commit -m "..."
set -euo pipefail

if [ "${QG_SKIP:-0}" = "1" ]; then
    echo ""
    echo "⚠️  QUALITY GATE SKIPPED (QG_SKIP=1)"
    echo "    You must follow up with a commit that passes the gate."
    echo ""
    exit 0
fi

# Find quality-gate binary
QG=""
if command -v quality-gate &>/dev/null; then
    QG="quality-gate"
elif [ -f ".build/debug/quality-gate" ]; then
    QG=".build/debug/quality-gate"
elif [ -f ".build/release/quality-gate" ]; then
    QG=".build/release/quality-gate"
fi

if [ -z "$QG" ]; then
    echo ""
    echo "ERROR: quality-gate not found."
    echo ""
    echo "Install it:"
    echo "  Option 1: Run ./scripts/install.sh (if quality-gate-swift is this repo)"
    echo "  Option 2: Clone and install globally:"
    echo "    git clone https://github.com/jpurnell/quality-gate-swift.git ~/.quality-gate-swift"
    echo "    cd ~/.quality-gate-swift && ./scripts/install.sh"
    echo ""
    exit 1
fi

echo "Pre-commit: running quality gate..."
$QG --check all \
    --exclude build \
    --exclude test \
    --exclude doc-lint \
    --exclude disk-clean \
    --exclude memory-builder \
    --exclude swift-version \
    --exclude unreachable \
    --strict \
    --continue-on-failure

exit $?
HOOK
)

# --- Pre-push hook ---
PRE_PUSH_HOOK=$(cat << 'HOOK'
#!/bin/bash
# quality-gate-swift managed hook
# Verifies a clean build before pushing. Full quality gate runs in CI.
set -euo pipefail

echo "Pre-push: verifying build compiles clean..."
swift build 2>&1 | tee /tmp/qg-build.log
if grep -q "error:" /tmp/qg-build.log; then
    echo "ERROR: Build failed. Fix before pushing."
    exit 1
fi

echo "Pre-push passed. Full quality gate will run in CI."
HOOK
)

echo ""
echo "=== Installing quality-gate git hooks ==="
echo ""

install_hook "pre-commit" "$PRE_COMMIT_HOOK"
install_hook "pre-push" "$PRE_PUSH_HOOK"

echo ""
echo "Done. Hooks installed at $HOOK_DIR"
echo ""
echo "The pre-commit hook runs fast AST checks (~5-10 seconds)."
echo "The pre-push hook verifies swift build compiles clean."
echo "CI runs the full quality gate on push/PR."
echo ""
echo "To remove: rm $HOOK_DIR/pre-commit $HOOK_DIR/pre-push"
