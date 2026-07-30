#!/bin/bash
# Deploy quality-gate to /usr/local/custom/bin on BOTH this machine and a remote
# host (roseclub.org), building natively on each (local arm64, roseclub x86_64 —
# a copied binary won't run cross-arch). Reuses scripts/deploy-local.sh verbatim
# on both sides, so build/stamp/codesign/install logic lives in exactly one place.
#
# The remote build is pinned to the swiftly-managed toolchain (roseclub's default
# /usr/bin/swift is too old to build the gate). Remote install uses sudo over an
# SSH TTY, so you'll be prompted for the remote password — run this interactively.
#
# Usage:
#   ./scripts/deploy-remote.sh                 # deploy local + roseclub
#   ./scripts/deploy-remote.sh --remote-only   # skip local
#   ./scripts/deploy-remote.sh --local-only    # same as deploy-local.sh
#
# Env overrides:
#   REMOTE_HOST   ssh host (default: roseclub.org)
#   REMOTE_DIR    remote checkout dir (default: ~/quality-gate-swift)
#   REMOTE_BRANCH branch to deploy on remote (default: current local branch)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
REMOTE_HOST="${REMOTE_HOST:-roseclub.org}"
REMOTE_DIR="${REMOTE_DIR:-\$HOME/quality-gate-swift}"
REMOTE_BRANCH="${REMOTE_BRANCH:-$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)}"
REPO_URL="https://github.com/jpurnell/quality-gate-swift.git"

MODE="${1:-all}"

deploy_local() {
    echo "======================================================================"
    echo "  LOCAL deploy ($(hostname -s), $(uname -m)) -> /usr/local/custom/bin"
    echo "======================================================================"
    "$SCRIPT_DIR/deploy-local.sh"
}

deploy_remote() {
    echo "======================================================================"
    echo "  REMOTE deploy (${REMOTE_HOST}) -> /usr/local/custom/bin"
    echo "  branch: ${REMOTE_BRANCH}   (sudo will prompt on the remote TTY)"
    echo "======================================================================"
    # -t: allocate a TTY so remote `sudo` in deploy-local.sh can prompt.
    ssh -t "$REMOTE_HOST" "bash -lc '
        set -euo pipefail
        # Resolve the swiftly-managed toolchain and put it first on PATH so the
        # gate builds with a new-enough Swift (roseclub default is too old).
        TC=\$(swiftly use --print-location 2>/dev/null)
        if [ -n \"\$TC\" ] && [ -d \"\$TC/usr/bin\" ]; then
            export PATH=\"\$TC/usr/bin:\$PATH\"
        fi
        echo \"remote swift: \$(swift --version 2>&1 | head -1)\"

        # Clone on first run, otherwise fetch + hard-reset to the target branch.
        if [ ! -d \"${REMOTE_DIR}/.git\" ]; then
            git clone \"${REPO_URL}\" \"${REMOTE_DIR}\"
        fi
        cd \"${REMOTE_DIR}\"
        git fetch origin \"${REMOTE_BRANCH}\"
        git checkout \"${REMOTE_BRANCH}\"
        git reset --hard \"origin/${REMOTE_BRANCH}\"

        # Reuse the exact same deploy logic (build + stamp + sudo install + codesign).
        ./scripts/deploy-local.sh
    '"
}

case "$MODE" in
    --local-only)  deploy_local ;;
    --remote-only) deploy_remote ;;
    all)           deploy_local; echo; deploy_remote ;;
    *)             echo "usage: $0 [--local-only|--remote-only]"; exit 2 ;;
esac

echo ""
echo "=== Done. Verify installed builds match: ==="
echo "  local:    quality-gate build-info"
echo "  roseclub: ssh ${REMOTE_HOST} 'bash -lc \"/usr/local/custom/bin/quality-gate build-info\"'"
