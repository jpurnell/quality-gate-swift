#!/bin/bash
# development-guidelines updater
# Pulls the latest framework files from GitHub while preserving all
# project-specific documents (summaries, checklists, roadmaps, plans).
#
# Usage: ./development-guidelines/scripts/update.sh
#
# What gets updated (framework files):
#   00_CORE_RULES/*.md        — coding rules, enforcement docs, session workflow
#   03_STRATEGIES_AND_FRAMEWORKS/*.md — strategic frameworks
#   scripts/*.sh              — hook installer, migration, this updater
#   templates/*               — CLAUDE.md template, settings template
#   README.md, .version       — top-level framework files
#
# What is NEVER touched (project files):
#   01_ROADMAPS/              — project-specific roadmaps
#   02_IMPLEMENTATION_PLANS/  — project-specific plans and proposals
#   04_LIBRARY/               — project reference materials
#   05_SUMMARIES/             — session summaries and phase summaries
#   CLAUDE.md (project root)  — customized project CLAUDE.md
#   .quality-gate.yml         — project quality gate config

set -euo pipefail

REPO_URL="https://github.com/jpurnell/development-guidelines.git"
GUIDELINES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="$(git -C "$GUIDELINES_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$GUIDELINES_DIR")"
TEMP_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo "=== development-guidelines updater ==="
echo ""

# Show current version
if [ -f "$GUIDELINES_DIR/.version" ]; then
    echo "Current version: $(cat "$GUIDELINES_DIR/.version")"
else
    echo "Current version: unversioned"
fi
echo ""

# Clone latest from GitHub (shallow clone for speed)
echo "Fetching latest from GitHub..."
if ! git clone --depth 1 "$REPO_URL" "$TEMP_DIR/dev-guidelines" 2>/dev/null; then
    echo "ERROR: Could not clone $REPO_URL"
    echo "Check your network connection and repository access."
    exit 1
fi

UPSTREAM_VERSION="unknown"
if [ -f "$TEMP_DIR/dev-guidelines/.version" ]; then
    UPSTREAM_VERSION=$(cat "$TEMP_DIR/dev-guidelines/.version")
fi
echo "Upstream version: $UPSTREAM_VERSION"
echo ""

CHANGES=0

# --- Framework directories: sync contents ---
sync_framework_dir() {
    local dir="$1"
    local desc="$2"
    local src="$TEMP_DIR/dev-guidelines/$dir"
    local dest="$GUIDELINES_DIR/$dir"

    if [ ! -d "$src" ]; then
        return
    fi

    mkdir -p "$dest"

    # Copy all files from upstream, overwriting existing
    local count=0
    while IFS= read -r -d '' file; do
        local relpath="${file#"$src/"}"
        local destfile="$dest/$relpath"
        mkdir -p "$(dirname "$destfile")"

        if [ -f "$destfile" ]; then
            if ! diff -q "$file" "$destfile" >/dev/null 2>&1; then
                cp "$file" "$destfile"
                echo "  Updated $dir/$relpath"
                count=$((count + 1))
            fi
        else
            cp "$file" "$destfile"
            echo "  Added   $dir/$relpath"
            count=$((count + 1))
        fi
    done < <(find "$src" -type f -print0)

    if [ "$count" -gt 0 ]; then
        CHANGES=$((CHANGES + count))
    fi
}

# --- Framework files: sync individual files ---
sync_framework_file() {
    local file="$1"
    local src="$TEMP_DIR/dev-guidelines/$file"
    local dest="$GUIDELINES_DIR/$file"

    if [ ! -f "$src" ]; then
        return
    fi

    if [ -f "$dest" ]; then
        if ! diff -q "$src" "$dest" >/dev/null 2>&1; then
            cp "$src" "$dest"
            echo "  Updated $file"
            CHANGES=$((CHANGES + 1))
        fi
    else
        mkdir -p "$(dirname "$dest")"
        cp "$src" "$dest"
        echo "  Added   $file"
        CHANGES=$((CHANGES + 1))
    fi
}

echo "Syncing framework files..."

# Framework directories (always updated)
sync_framework_dir "00_CORE_RULES" "core rules and standards"
sync_framework_dir "03_STRATEGIES_AND_FRAMEWORKS" "strategic frameworks"
sync_framework_dir "scripts" "scripts"
sync_framework_dir "templates" "templates"

# Framework files at guidelines root
sync_framework_file "README.md"
sync_framework_file ".version"

# --- Ensure project-specific directories exist ---
ensure_dir() {
    local dir="$GUIDELINES_DIR/$1"
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        echo "  Created $1/"
        CHANGES=$((CHANGES + 1))
    fi
}

echo ""
echo "Ensuring project directories exist..."
ensure_dir "01_ROADMAPS"
ensure_dir "02_IMPLEMENTATION_PLANS/COMPLETED"
ensure_dir "02_IMPLEMENTATION_PLANS/PROPOSALS"
ensure_dir "02_IMPLEMENTATION_PLANS/UPCOMING"
ensure_dir "02_IMPLEMENTATION_PLANS/IDEAS"
ensure_dir "04_LIBRARY"
ensure_dir "05_SUMMARIES"
ensure_dir "05_SUMMARIES/05_00_PHASE_SUMMARIES"
ensure_dir "05_SUMMARIES/05_01_FIX_SUMMARIES"

# --- Copy CLAUDE.md template if not present at project root ---
if [ ! -f "$PROJECT_ROOT/CLAUDE.md" ] && [ -f "$GUIDELINES_DIR/templates/CLAUDE.md" ]; then
    cp "$GUIDELINES_DIR/templates/CLAUDE.md" "$PROJECT_ROOT/CLAUDE.md"
    echo "  Added CLAUDE.md template at project root (customize [PROJECT_NAME])"
    CHANGES=$((CHANGES + 1))
fi

# --- Update hooks ---
echo ""
echo "Updating git hooks..."
if [ -f "$GUIDELINES_DIR/scripts/install-hooks.sh" ]; then
    bash "$GUIDELINES_DIR/scripts/install-hooks.sh"
fi

# --- Run migration if needed ---
if [ -f "$GUIDELINES_DIR/scripts/migrate.sh" ]; then
    echo ""
    echo "Running structural migration..."
    bash "$GUIDELINES_DIR/scripts/migrate.sh"
fi

# --- Summary ---
echo ""
echo "=========================================="
if [ "$CHANGES" -eq 0 ]; then
    echo "Already up to date. No framework files changed."
else
    echo "$CHANGES framework file(s) updated."
    echo ""
    echo "Review changes:"
    echo "  git diff development-guidelines/"
    echo ""
    echo "Run quality gate to check compliance:"
    echo "  quality-gate --check all --strict --continue-on-failure"
fi
echo "=========================================="
