#!/bin/bash
# quality-gate-swift global installer
# Builds from GitHub main and installs to /usr/local/bin/quality-gate.
# Usage: ./scripts/install.sh
#
# Re-run to update: cd ~/.quality-gate-swift && git pull && ./scripts/install.sh

set -euo pipefail

REPO_URL="https://github.com/jpurnell/quality-gate-swift.git"
LOCAL_DIR="${QUALITY_GATE_HOME:-$HOME/.quality-gate-swift}"
INSTALL_DIR="/usr/local/bin"
BINARY_NAME="quality-gate"

echo "=== quality-gate-swift installer ==="
echo ""

# Clone or update
if [ -d "$LOCAL_DIR/.git" ]; then
    echo "Updating existing clone at $LOCAL_DIR..."
    git -C "$LOCAL_DIR" fetch origin main
    git -C "$LOCAL_DIR" checkout main
    git -C "$LOCAL_DIR" reset --hard origin/main
else
    echo "Cloning quality-gate-swift to $LOCAL_DIR..."
    git clone "$REPO_URL" "$LOCAL_DIR"
    git -C "$LOCAL_DIR" checkout main
fi

COMMIT_HASH=$(git -C "$LOCAL_DIR" rev-parse --short HEAD)
COMMIT_DATE=$(git -C "$LOCAL_DIR" log -1 --format=%ci HEAD)

echo ""
echo "Building release binary (pinned to main @ $COMMIT_HASH)..."
cd "$LOCAL_DIR"
swift build -c release 2>&1 | tail -3

BINARY_PATH="$LOCAL_DIR/.build/release/$BINARY_NAME"
if [ ! -f "$BINARY_PATH" ]; then
    echo "ERROR: Build failed — binary not found at $BINARY_PATH"
    exit 1
fi

# Integrity check
SHA256=$(shasum -a 256 "$BINARY_PATH" | awk '{print $1}')
echo ""
echo "Binary SHA256: $SHA256"

# Install
if [ ! -d "$INSTALL_DIR" ]; then
    echo "Creating $INSTALL_DIR (requires sudo)..."
    sudo mkdir -p "$INSTALL_DIR"
fi

if [ -w "$INSTALL_DIR" ]; then
    cp "$BINARY_PATH" "$INSTALL_DIR/$BINARY_NAME"
else
    echo "Installing to $INSTALL_DIR (requires sudo)..."
    sudo cp "$BINARY_PATH" "$INSTALL_DIR/$BINARY_NAME"
fi

chmod +x "$INSTALL_DIR/$BINARY_NAME"

# Ad-hoc codesign — macOS kills unsigned binaries from system paths
echo "Signing binary..."
if [ -w "$INSTALL_DIR/$BINARY_NAME" ]; then
    codesign --force -s - "$INSTALL_DIR/$BINARY_NAME"
else
    sudo codesign --force -s - "$INSTALL_DIR/$BINARY_NAME"
fi

echo ""
echo "=== Installed ==="
echo "  Binary:  $INSTALL_DIR/$BINARY_NAME"
echo "  Version: main @ $COMMIT_HASH ($COMMIT_DATE)"
echo "  SHA256:  $SHA256"
echo ""
echo "To update: cd $LOCAL_DIR && git pull && ./scripts/install.sh"
echo "To verify: quality-gate --help"
