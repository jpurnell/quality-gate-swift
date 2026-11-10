#!/bin/bash
# Point the Homebrew formula at a published quality-gate release, and (with --publish) update the tap.
#
# Homebrew installs the artifacts `scripts/release.sh` publishes to GitHub Releases, not the
# working tree, so a tap update follows a release and cannot follow `deploy-local.sh`, which
# installs an untagged build. Run this after `release.sh <tag>`, or let `deploy-all.sh --release <tag>`
# run both.
#
# What it does, in order:
#   1. Downloads both release tarballs and computes their SHA-256 itself. It does not read the
#      checksums out of the release notes: those are what the formula is meant to be checked against.
#   2. Rewrites `packaging/homebrew/quality-gate.rb` (version, two URLs, two checksums), which stays the
#      authoritative copy, and syntax-checks it with `ruby -c`.
#   3. Copies it to the tap checkout as `Formula/quality-gate.rb` and shows the diff.
#   4. With --publish only: commits and pushes the tap, then confirms the remote has the commit.
#
# Without --publish nothing leaves this machine, and the tap checkout is left with the copied formula
# uncommitted so the diff can be reviewed.
#
# The repo copy of the formula is left modified, not committed: commit it with the release's
# housekeeping so the repository and the tap say the same thing.
#
# Usage: scripts/update-formula.sh <tag> [--publish]        e.g. scripts/update-formula.sh v3.11.0
# Env:   TAP_DIR   the homebrew-tap checkout (default: ../homebrew-tap beside this repository)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
TAP_DIR="${TAP_DIR:-$(dirname "$REPO_DIR")/homebrew-tap}"
FORMULA="$REPO_DIR/packaging/homebrew/quality-gate.rb"
SLUG="jpurnell/quality-gate-swift"

TAG="${1:-}"
PUBLISH="no"
[ "${2:-}" = "--publish" ] && PUBLISH="yes"
if [ -z "$TAG" ] || { [ -n "${2:-}" ] && [ "${2:-}" != "--publish" ]; }; then
    echo "usage: $0 <tag> [--publish]" >&2
    exit 2
fi
case "$TAG" in v*) ;; *) echo "✗ Tags carry a 'v' (v3.10.0); got '$TAG'." >&2; exit 2 ;; esac
VERSION="${TAG#v}"

[ -f "$FORMULA" ] || { echo "✗ $FORMULA not found." >&2; exit 1; }
[ -d "$TAP_DIR/.git" ] || [ -f "$TAP_DIR/.git" ] || { echo "✗ No tap checkout at $TAP_DIR (set TAP_DIR)." >&2; exit 1; }

# The tap must be clean before anything is copied into it, or the commit would carry someone else's work.
if [ "$PUBLISH" = "yes" ]; then
    [ "$(git -C "$TAP_DIR" rev-parse --abbrev-ref HEAD)" = "main" ] \
        || { echo "✗ The tap is not on main." >&2; exit 1; }
    git -C "$TAP_DIR" diff --quiet && git -C "$TAP_DIR" diff --cached --quiet \
        || { echo "✗ The tap has uncommitted changes; commit or discard them first." >&2; exit 1; }
    git -C "$TAP_DIR" pull -q --ff-only
fi

gh release view "$TAG" --repo "$SLUG" >/dev/null 2>&1 \
    || { echo "✗ Release $TAG is not published on $SLUG. Run scripts/release.sh $TAG first." >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
sha_of() {
    local arch="$1"
    gh release download "$TAG" --repo "$SLUG" --pattern "quality-gate-macos-${arch}.tar.gz" --dir "$WORK" >&2
    shasum -a 256 "$WORK/quality-gate-macos-${arch}.tar.gz" | cut -d' ' -f1
}
echo "→ Fetching $TAG artifacts and computing checksums"
ARM_SHA="$(sha_of arm64)"
INTEL_SHA="$(sha_of x86_64)"
for s in "$ARM_SHA" "$INTEL_SHA"; do
    [[ "$s" =~ ^[0-9a-f]{64}$ ]] || { echo "✗ Not a SHA-256: '$s'" >&2; exit 1; }
done

echo "→ Rewriting $FORMULA"
# Anchored on the lines that exist today; each substitution is counted, because a perl that
# matches nothing exits 0 and the formula would silently keep the old release.
VERSION="$VERSION" TAG="$TAG" ARM_SHA="$ARM_SHA" INTEL_SHA="$INTEL_SHA" perl -0pi -e '
    my $n = 0;
    $n += s{^(\s*version\s+)"[^"]*"}{$1"$ENV{VERSION}"}m;
    $n += s{(on_arm do\s+url ")[^"]*(quality-gate-macos-arm64\.tar\.gz"\s+sha256 ")[0-9a-f]{64}}{$1https://github.com/jpurnell/quality-gate-swift/releases/download/$ENV{TAG}/$2$ENV{ARM_SHA}}s;
    $n += s{(on_intel do\s+url ")[^"]*(quality-gate-macos-x86_64\.tar\.gz"\s+sha256 ")[0-9a-f]{64}}{$1https://github.com/jpurnell/quality-gate-swift/releases/download/$ENV{TAG}/$2$ENV{INTEL_SHA}}s;
    die "expected 3 substitutions, made $n\n" unless $n == 3;
' "$FORMULA"
ruby -c "$FORMULA" >/dev/null
grep -q "version \"$VERSION\"" "$FORMULA" || { echo "✗ The formula does not say version $VERSION." >&2; exit 1; }

echo "→ Copying to the tap"
cp "$FORMULA" "$TAP_DIR/Formula/quality-gate.rb"
git -C "$TAP_DIR" --no-pager diff --stat -- Formula/quality-gate.rb
git -C "$TAP_DIR" --no-pager diff -- Formula/quality-gate.rb | grep -E '^[+-] ' || true

if [ "$PUBLISH" != "yes" ]; then
    echo ""
    echo "Not published. The tap checkout has the new formula uncommitted ($TAP_DIR)."
    echo "Publish with: $0 $TAG --publish   (after discarding the uncommitted copy: git -C $TAP_DIR checkout -- Formula)"
    echo "Commit the repo copy too: git add packaging/homebrew/quality-gate.rb"
    exit 0
fi

git -C "$TAP_DIR" add Formula/quality-gate.rb
git -C "$TAP_DIR" commit -q -m "quality-gate ${VERSION}"
git -C "$TAP_DIR" push origin main
LOCAL="$(git -C "$TAP_DIR" rev-parse HEAD)"
REMOTE="$(git -C "$TAP_DIR" ls-remote origin main | cut -f1)"
[ "$LOCAL" = "$REMOTE" ] || { echo "✗ Push not confirmed: local $LOCAL, remote $REMOTE." >&2; exit 1; }

echo ""
echo "✓ Tap updated to ${VERSION} (${LOCAL:0:8}). Verify with: brew update && brew upgrade quality-gate && quality-gate --version"
echo "  Commit the repo copy: git add packaging/homebrew/quality-gate.rb"
