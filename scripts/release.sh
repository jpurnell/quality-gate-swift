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
# Tags here carry a `v` (v3.4.0, v3.3.0 …) and CHANGELOG sections do not (`## [3.4.0]`).
# Comparing them raw fails whichever form is passed, so the prefix is stripped for the
# CHANGELOG lookup and kept for the tag itself.
VERSION="${TAG#v}"
if ! grep -q "## \[${VERSION}\]" CHANGELOG.md; then
    echo "✗ CHANGELOG.md has no '## [${VERSION}]' section. Add the release entry first." >&2
    exit 1
fi

# The binary prints a hand-written literal from QualityGateCLI.swift, and
# `release-readiness` checks CHANGELOG-against-tag parity without ever reading it — so 3.4.0
# survived a day of deploys past its tag. Checked here, before the build, because a binary
# that misreports its own version makes every bug report ambiguous.
LITERAL="$(grep -oE 'version: "[0-9]+\.[0-9]+\.[0-9]+"' Sources/QualityGateCLI/QualityGateCLI.swift | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
if [ "$LITERAL" != "$VERSION" ]; then
    echo "✗ QualityGateCLI.swift reports '${LITERAL}' but this release is '${VERSION}'." >&2
    echo "  Update the literal first; the formula's test compares them and so does this." >&2
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
    # The bundles, not just the binary.
    #
    # This packaged `quality-gate` alone. SwiftPM resolves a resource bundle relative to the
    # running executable, so the published artifact crashed — not failed, crashed — the moment
    # anyone selected a checker that reads its resources:
    #
    #   ControlMapping/resource_bundle_accessor.swift:44: Fatal error:
    #   unable to find bundle named quality-gate-swift_ControlMapping
    #
    # `--check safety` works without them, which is how this survived: the checkers people
    # reach for first need nothing from disk. Same shape as the README's install line, which
    # copied 40 of 44 bundles and passed as correct for exactly the same reason.
    BUNDLES=()
    while IFS= read -r b; do BUNDLES+=("$b"); done < <(cd "$BIN_DIR" && ls -d *.bundle 2>/dev/null)
    if [ ${#BUNDLES[@]} -eq 0 ]; then
        echo "✗ No resource bundles beside the binary in ${BIN_DIR}." >&2
        echo "  A release without them crashes on any checker that reads its resources." >&2
        exit 1
    fi
    echo "  ${#BUNDLES[@]} resource bundle(s)"
    tar -czf "$DIST/quality-gate-macos-${ARCH}.tar.gz" -C "$BIN_DIR" quality-gate "${BUNDLES[@]}"

    # Unpack it somewhere else and run a checker that needs its resources. Packaging is a claim
    # about what the artifact contains; running it is the only thing that checks the claim, and
    # the arm64 slice is the one this machine can actually execute.
    if [ "$ARCH" = "arm64" ]; then
        VERIFY="$(mktemp -d)"
        tar -xzf "$DIST/quality-gate-macos-${ARCH}.tar.gz" -C "$VERIFY"
        mkdir -p "$VERIFY/probe/Sources/Demo"
        cat > "$VERIFY/probe/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Demo", targets: [.target(name: "Demo")])
SWIFT
        echo 'public struct Demo { public init() {} }' > "$VERIFY/probe/Sources/Demo/Demo.swift"
        echo "→ Verifying the artifact runs a resource-reading checker"
        ( cd "$VERIFY/probe" && "$VERIFY/quality-gate" --check control-mapping >/dev/null 2>&1 ) || {
            echo "✗ The packaged artifact cannot run \`--check control-mapping\`." >&2
            echo "  Its resource bundles are missing or unreadable; do not publish it." >&2
            exit 1
        }
        rm -rf "$VERIFY"
    fi
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
