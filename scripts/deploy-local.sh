#!/bin/bash
# Deploy quality-gate from the local working tree to /usr/local/custom/bin.
# Usage: ./scripts/deploy-local.sh
set -euo pipefail

INSTALL_DIR="/usr/local/custom/bin"
BINARY_NAME="quality-gate"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== quality-gate local deploy ==="
echo "Building release..."
cd "$REPO_DIR"
swift build -c release 2>&1 | tail -3

BINARY_PATH="$REPO_DIR/.build/release/$BINARY_NAME"
if [ ! -f "$BINARY_PATH" ]; then
    echo "ERROR: Build failed — binary not found"
    exit 1
fi

echo "Installing to $INSTALL_DIR (requires sudo)..."
sudo cp "$BINARY_PATH" "$INSTALL_DIR/$BINARY_NAME"
sudo codesign --force -s - "$INSTALL_DIR/$BINARY_NAME"

STAMP_FILE="$INSTALL_DIR/.quality-gate-stamp"
DEPLOY_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD)"
echo "$DEPLOY_COMMIT" | sudo tee "$STAMP_FILE" > /dev/null

echo ""
echo "=== Deployed ==="
echo "  Binary: $INSTALL_DIR/$BINARY_NAME"
echo "  Stamp:  $DEPLOY_COMMIT"
"$INSTALL_DIR/$BINARY_NAME" --help 2>&1 | head -1 || echo "WARNING: binary failed to run"
