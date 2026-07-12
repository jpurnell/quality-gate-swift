#!/bin/zsh
# Build, sign, package, and publish a pinned quality-gate release.
#
# Sovereignty (Phase 2 §3c): releases are built on our own hardware —
# GitHub Releases is distribution, never build infrastructure. The
# quality-gate-action downloads these artifacts by pinned tag; there is
# deliberately no floating "latest".
#
# Usage: scripts/release.sh [tag]       default tag: today (YYYY.MM.DD)
set -euo pipefail

TAG="${1:-$(date -u +%Y.%m.%d)}"
DIST=".build/release-dist"

# The ReleaseReadinessAuditor requires the tag to have a CHANGELOG section —
# enforce it here, before five minutes of building, not after.
if ! grep -q "## \[${TAG}\]" CHANGELOG.md; then
    echo "✗ CHANGELOG.md has no '## [${TAG}]' section. Add the release entry first." >&2
    exit 1
fi

# Releases are immutable; the git tag may legitimately pre-exist (the gate's
# release-untagged-version rule requires tagging before the CHANGELOG commit).
if gh release view "${TAG}" >/dev/null 2>&1; then
    echo "✗ Release ${TAG} is already published — pinned releases are immutable. Pick a new tag." >&2
    exit 1
fi

echo "→ Stamping build identity"
make stamp

rm -rf "$DIST"
mkdir -p "$DIST"

for ARCH in arm64 x86_64; do
    echo "→ Building release binary (${ARCH})"
    swift build -c release --product quality-gate --arch "$ARCH"
    # Ask SPM where the products landed — the path differs between the
    # classic (.build/<triple>/release) and swiftbuild (.build/out/Products)
    # backends, and hardcoding either broke once already.
    BIN_DIR="$(swift build -c release --product quality-gate --arch "$ARCH" --show-bin-path | tail -1)"
    BIN="${BIN_DIR}/quality-gate"
    echo "→ Signing (${ARCH})"
    codesign -s - --force --options runtime "$BIN"
    echo "→ Packaging (${ARCH})"
    tar -czf "$DIST/quality-gate-macos-${ARCH}.tar.gz" -C "$BIN_DIR" quality-gate
done

echo "→ Verifying artifacts"
ls -lh "$DIST"
CHECKSUMS="$(cd "$DIST" && shasum -a 256 quality-gate-macos-*.tar.gz)"
echo "$CHECKSUMS"

echo "→ Publishing release ${TAG}"
gh release create "$TAG" \
    --title "quality-gate ${TAG}" \
    --notes "Pinned release for quality-gate-action. Built $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(hostname) at $(git rev-parse --short HEAD).

SHA-256:
\`\`\`
${CHECKSUMS}
\`\`\`" \
    "$DIST"/quality-gate-macos-arm64.tar.gz \
    "$DIST"/quality-gate-macos-x86_64.tar.gz

echo "✓ Release ${TAG} published. Pin it in workflows as: version: \"${TAG}\""
