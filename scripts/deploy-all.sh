#!/bin/bash
# Deploy the whole quality-gate ecosystem in one pass:
#   1. Push every repo that is ahead of its remote (hooks gate each push).
#   2. Build + install the quality-gate binary (scripts/deploy-local.sh, sudo).
#   3. Verify what's installed with `quality-gate doctor`.
#
# Usage: ./scripts/deploy-all.sh [--push-only|--install-only]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QG_DIR="$(dirname "$SCRIPT_DIR")"
TOOLS_DIR="$(dirname "$QG_DIR")"

MODE="${1:-all}"

# Repos to push. The branch is not hardcoded: each repo pushes whatever branch it
# is currently on, measured against that branch's own upstream. Pinning these to
# "main" meant a feature branch reported "up to date with origin/main" and pushed
# nothing, which reads as success and is not.
REPOS=(
    "$QG_DIR"
    "$TOOLS_DIR/quality-gate-corpus-kit"
    "$TOOLS_DIR/org-judgement-system"
    "$TOOLS_DIR/org-judgement-system/development-guidelines"
)

push_repos() {
    for dir in "${REPOS[@]}"; do
        name="$(basename "$dir")"
        if [ ! -d "$dir/.git" ] && [ ! -f "$dir/.git" ]; then
            echo "── $name: not a git checkout — skipped"
            continue
        fi
        if ! git -C "$dir" diff --quiet || ! git -C "$dir" diff --cached --quiet; then
            echo "── $name: UNCOMMITTED CHANGES — commit or stash before deploying"
            exit 1
        fi
        branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
        if [ "$branch" = "HEAD" ]; then
            echo "── $name: detached HEAD — skipped"
            continue
        fi
        if ! git -C "$dir" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
            echo "── $name: $branch has no upstream — skipped (push once with -u to set it)"
            continue
        fi
        upstream="$(git -C "$dir" rev-parse --abbrev-ref '@{upstream}')"
        ahead="$(git -C "$dir" rev-list --count '@{upstream}..HEAD')"
        if [ "$ahead" = "0" ]; then
            echo "── $name: $branch up to date with $upstream"
        else
            echo "── $name: pushing $branch → $upstream ($ahead commit(s) ahead)..."
            git -C "$dir" push origin "$branch" --follow-tags
        fi
    done
}

install_binary() {
    echo "── installing quality-gate binary (sudo will prompt)..."
    "$SCRIPT_DIR/deploy-local.sh"
    echo ""
    echo "── post-install check:"
    /usr/local/custom/bin/quality-gate doctor || true
    echo ""
    echo "Reminder: ratchet minimumGateVersion in .quality-gate.yml to today's"
    echo "date so stale binaries fail loudly from here on."
}

case "$MODE" in
    --push-only)    push_repos ;;
    --install-only) install_binary ;;
    all)            push_repos; install_binary ;;
    *)              echo "usage: $0 [--push-only|--install-only]"; exit 2 ;;
esac
