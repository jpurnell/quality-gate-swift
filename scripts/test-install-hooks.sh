#!/bin/bash
# Tests for the pre-push hook written by install-hooks.sh.
# Usage: ./scripts/test-install-hooks.sh
#
# Each case builds a scratch repository with a bare local remote, installs the hooks, and
# pushes. The gate is stubbed with `true` (QG_BIN) so only the hook's own logic is exercised.

set -uo pipefail

INSTALLER="$(cd "$(dirname "$0")" && pwd)/install-hooks.sh"
PASS=0
FAIL=0

check() {
    local name="$1" ok="$2"
    if [ "$ok" = 1 ]; then PASS=$((PASS + 1)); echo "  ✓ $name"; else FAIL=$((FAIL + 1)); echo "  ✗ $name"; fi
}

# Fresh repo with one real commit already on the remote. Echoes the work-tree path.
setup() {
    local root
    root="$(mktemp -d)"
    git init -q --bare "$root/remote.git"
    git init -q -b main "$root/work"
    (
        cd "$root/work" || exit 1
        git config user.email test@example.com
        git config user.name test
        git config commit.gpgsign false
        git remote add origin "$root/remote.git"
        echo one > file.txt
        git add file.txt
        git commit -q -m "first"
        git push -q origin main
        "$INSTALLER" > /dev/null
    )
    echo "$root/work"
}

remote_head() { git -C "$1" ls-remote origin "${2:-main}" | cut -f1; }

export QG_BIN=/usr/bin/true

echo "pre-push: empty commits"

# An empty commit on top of the remote is refused, and the ref does not move.
work="$(setup)"
before="$(remote_head "$work")"
git -C "$work" commit -q --allow-empty --no-verify -m "Add ORCID references"
out="$(git -C "$work" push origin main 2>&1)"
check "empty commit blocks the push" "$([ "$(remote_head "$work")" = "$before" ] && echo 1 || echo 0)"
check "the message names the commit" "$(grep -q 'Add ORCID references' <<<"$out" && echo 1 || echo 0)"

# An empty commit buried under a real one is still found.
work="$(setup)"
before="$(remote_head "$work")"
git -C "$work" commit -q --allow-empty --no-verify -m "empty"
echo two >> "$work/file.txt"
git -C "$work" commit -q -am "real" --no-verify
git -C "$work" push -q origin main > /dev/null 2>&1
check "empty commit under a real one blocks" "$([ "$(remote_head "$work")" = "$before" ] && echo 1 || echo 0)"

# A commit that changes files pushes normally.
work="$(setup)"
echo two >> "$work/file.txt"
git -C "$work" commit -q -am "real" --no-verify
git -C "$work" push -q origin main > /dev/null 2>&1
check "commit with changes pushes" "$([ "$(remote_head "$work")" = "$(git -C "$work" rev-parse HEAD)" ] && echo 1 || echo 0)"

# A new branch is judged on its own commits, not on history the remote already has.
work="$(setup)"
git -C "$work" commit -q --allow-empty --no-verify -m "old empty"
QG_BIN=/usr/bin/true git -C "$work" push -q --no-verify origin main > /dev/null 2>&1
git -C "$work" switch -q -c feature
echo three >> "$work/file.txt"
git -C "$work" commit -q -am "feature work" --no-verify
git -C "$work" push -q origin feature > /dev/null 2>&1
check "new branch ignores empty commits already on the remote" \
    "$([ "$(remote_head "$work" feature)" = "$(git -C "$work" rev-parse HEAD)" ] && echo 1 || echo 0)"

# Deleting a remote branch has no commits to inspect and must not be blocked.
git -C "$work" push -q origin --delete feature > /dev/null 2>&1
check "branch deletion is allowed" "$([ -z "$(remote_head "$work" feature)" ] && echo 1 || echo 0)"

# `git diff-tree` prints nothing for a merge commit, so an ordinary merge must not be mistaken
# for an empty commit.
work="$(setup)"
git -C "$work" switch -q -c side
echo side > "$work/side.txt"
git -C "$work" add side.txt
git -C "$work" commit -q -m "side" --no-verify
git -C "$work" switch -q main
echo main >> "$work/file.txt"
git -C "$work" commit -q -am "main change" --no-verify
git -C "$work" merge -q --no-edit --no-verify side
git -C "$work" push -q origin main > /dev/null 2>&1
check "merge commits are not treated as empty" "$([ "$(remote_head "$work")" = "$(git -C "$work" rev-parse HEAD)" ] && echo 1 || echo 0)"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
