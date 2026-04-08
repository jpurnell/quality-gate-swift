#!/usr/bin/env bash
# v5: cross-module self-audit. Builds the release binary and runs it
# against the package itself. Use this from CI to fail PRs that
# introduce dead code that the in-process syntactic test (in
# SelfAuditTests.swift) can't catch.
#
# Exits non-zero if any error-severity unreachable findings are found.

set -euo pipefail

cd "$(dirname "$0")/.."

echo "Building release binary…"
swift build -c release > /dev/null

# Force a fresh cross-module index for the self-audit.
rm -rf .build/index-build

echo "Running cross-module self-audit…"
./.build/release/quality-gate --check unreachable
