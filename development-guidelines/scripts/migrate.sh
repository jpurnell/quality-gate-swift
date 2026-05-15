#!/bin/bash
# development-guidelines migration script
# Applies structural changes to an existing development-guidelines/ directory
# without overwriting user-customized content.
#
# Usage: ./development-guidelines/scripts/migrate.sh

set -euo pipefail

GUIDELINES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$GUIDELINES_DIR/.version"
CURRENT_VERSION="2026-05-14"

echo "=== development-guidelines migration ==="
echo ""

# Detect current version
if [ -f "$VERSION_FILE" ]; then
    INSTALLED_VERSION=$(cat "$VERSION_FILE")
    echo "Current version: $INSTALLED_VERSION"
else
    INSTALLED_VERSION="unversioned"
    echo "Current version: unversioned (pre-migration)"
fi

if [ "$INSTALLED_VERSION" = "$CURRENT_VERSION" ]; then
    echo "Already at version $CURRENT_VERSION. Nothing to migrate."
    exit 0
fi

echo "Target version:  $CURRENT_VERSION"
echo ""

CHANGES=0

# --- Migration: ensure required directories exist ---
ensure_dir() {
    local dir="$1"
    local desc="$2"
    if [ ! -d "$GUIDELINES_DIR/$dir" ]; then
        echo "  Creating $dir/ ($desc)"
        mkdir -p "$GUIDELINES_DIR/$dir"
        CHANGES=$((CHANGES + 1))
    fi
}

ensure_dir "scripts" "hook installer and migration scripts"
ensure_dir "templates" "CLAUDE.md and settings templates"
ensure_dir "00_CORE_RULES" "core rules and standards"
ensure_dir "02_IMPLEMENTATION_PLANS/COMPLETED" "completed implementation plans"
ensure_dir "02_IMPLEMENTATION_PLANS/PROPOSALS" "design proposals"
ensure_dir "02_IMPLEMENTATION_PLANS/UPCOMING" "upcoming implementation plans"
ensure_dir "02_IMPLEMENTATION_PLANS/IDEAS" "future ideas"
ensure_dir "04_IMPLEMENTATION_CHECKLISTS/COMPLETED" "completed checklists"
ensure_dir "05_SUMMARIES" "session summaries"

# --- Migration: copy new template files (never overwrite) ---
copy_if_missing() {
    local src="$1"
    local dest="$2"
    local desc="$3"
    if [ ! -f "$dest" ]; then
        if [ -f "$src" ]; then
            echo "  Adding $desc"
            cp "$src" "$dest"
            CHANGES=$((CHANGES + 1))
        fi
    fi
}

copy_if_missing "$GUIDELINES_DIR/templates/CLAUDE.md" \
    "$(git rev-parse --show-toplevel 2>/dev/null)/CLAUDE.md" \
    "CLAUDE.md template at project root"

# --- Migration: ensure enforcement doc exists ---
if [ ! -f "$GUIDELINES_DIR/00_CORE_RULES/12_ENFORCEMENT.md" ]; then
    echo "  NOTE: 12_ENFORCEMENT.md not found. Pull latest development-guidelines to get it."
    CHANGES=$((CHANGES + 1))
fi

# --- Migration: install hooks if not present ---
HOOK_DIR="$(git rev-parse --show-toplevel 2>/dev/null)/.git/hooks"
if [ -d "$HOOK_DIR" ] && [ ! -f "$HOOK_DIR/pre-commit" ]; then
    echo "  Installing git hooks..."
    bash "$GUIDELINES_DIR/scripts/install-hooks.sh"
    CHANGES=$((CHANGES + 1))
fi

# --- Write version marker ---
echo "$CURRENT_VERSION" > "$VERSION_FILE"

echo ""
if [ "$CHANGES" -eq 0 ]; then
    echo "No structural changes needed. Version marker updated to $CURRENT_VERSION."
else
    echo "$CHANGES change(s) applied. Version updated to $CURRENT_VERSION."
fi

echo ""
echo "Review changes with: git diff development-guidelines/"
