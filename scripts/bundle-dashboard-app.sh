#!/bin/bash
# Bundles the IJSDashboardApp executable into a proper macOS .app.
# Usage: scripts/bundle-dashboard-app.sh [debug|release]  (default: release)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP_NAME="IJS Dashboard"
BUNDLE_ID="org.roseclub.IJSDashboard"
EXECUTABLE="IJSDashboardApp"

echo "Building ${EXECUTABLE} (${CONFIG})..."
swift build -c "${CONFIG}" --product "${EXECUTABLE}" >/dev/null
BIN_DIR="$(swift build -c "${CONFIG}" --product "${EXECUTABLE}" --show-bin-path)"
BIN="${BIN_DIR}/${EXECUTABLE}"

APP_DIR="${ROOT}/build/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
rm -rf "${APP_DIR}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

cp "${BIN}" "${CONTENTS}/MacOS/${EXECUTABLE}"

# App icon (generate on first run).
if [[ ! -f "${ROOT}/scripts/AppIcon.icns" ]]; then
    "${ROOT}/scripts/make-icon.sh" || echo "  (icon generation skipped)"
fi
ICON_KEY=""
if [[ -f "${ROOT}/scripts/AppIcon.icns" ]]; then
    cp "${ROOT}/scripts/AppIcon.icns" "${CONTENTS}/Resources/AppIcon.icns"
    ICON_KEY="    <key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${EXECUTABLE}</string>
${ICON_KEY}
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1 || echo "  (ad-hoc codesign skipped)"

echo "Built ${APP_DIR}"
echo "Run:  open \"${APP_DIR}\" --args --corpus-path <corpus>"
echo "Or install: cp -R \"${APP_DIR}\" /Applications/"
