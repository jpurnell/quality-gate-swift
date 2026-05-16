#!/bin/bash
# onboard-corpus.sh — Onboard Swift projects to IJS quality-gate telemetry corpus
#
# Usage:
#   ./scripts/onboard-corpus.sh                    # onboard all known projects
#   ./scripts/onboard-corpus.sh --dry-run           # preview changes only
#   ./scripts/onboard-corpus.sh --skip-run           # config + hooks only, no quality-gate run
#   ./scripts/onboard-corpus.sh /path/to/project     # onboard specific project(s)

set -uo pipefail

CORPUS_PATH="/Users/jpurnell/Dropbox/Computer/Development/Swift/Tools/org-judgement-corpus"
QG_BIN="$(command -v quality-gate 2>/dev/null || echo "")"
GUIDELINES_REPO="https://github.com/jpurnell/development-guidelines.git"
SWIFT_DIR="/Users/jpurnell/Dropbox/Computer/Development/Swift"
TOOLS_DIR="$SWIFT_DIR/Tools"

DRY_RUN=false
SKIP_RUN=false
CUSTOM_PROJECTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true; shift ;;
        --skip-run) SKIP_RUN=true; shift ;;
        *)          CUSTOM_PROJECTS+=("$1"); shift ;;
    esac
done

DEFAULT_PROJECTS=(
    "$SWIFT_DIR/IconquerAI"
    "$SWIFT_DIR/Ignite"
    "$SWIFT_DIR/SwiftCLIKit"
    "$SWIFT_DIR/sicp-swift-companion"
    "$SWIFT_DIR/iconquer"
    "$SWIFT_DIR/IconquerApp"
    "$SWIFT_DIR/IconquerClient"
    "$SWIFT_DIR/IconquerTournament"
    "$SWIFT_DIR/swift-potrace"
    "$SWIFT_DIR/IconquerServer"
    "$SWIFT_DIR/IconquerCLI"
    "$SWIFT_DIR/IconquerMatch"
    "$SWIFT_DIR/IconquerCore"
    "$SWIFT_DIR/geo-audit"
    "$SWIFT_DIR/ApplesoftBASIC"
    "$SWIFT_DIR/IconquerMCP"
    "$SWIFT_DIR/CoverLetterWriter"
    "$SWIFT_DIR/IconquerGameKit"
    "$SWIFT_DIR/justinpurnell.com"
    "$SWIFT_DIR/narbis"
    "$SWIFT_DIR/reunions2025"
    "$SWIFT_DIR/businessMathMCP"
    "$SWIFT_DIR/StockOpt"
    "$SWIFT_DIR/houseMaker"
    "$SWIFT_DIR/ApplesoftBASICApp"
    "$SWIFT_DIR/WineTaster 4"
    "$TOOLS_DIR/DevGuidelinesMCP"
    "$TOOLS_DIR/docc-lint"
    "$TOOLS_DIR/GeoSEOMCP"
    "$TOOLS_DIR/project-showcase"
    "$TOOLS_DIR/quality-gate-types"
    "$TOOLS_DIR/SearchOperatorMCP"
    "$TOOLS_DIR/SwiftMCPClient"
    "$TOOLS_DIR/SwiftMCPServer"
    "$TOOLS_DIR/SwiftSVG"
    "$TOOLS_DIR/org-judgement-system"
)

SKIP_PROJECTS=(
    "$TOOLS_DIR/quality-gate-swift"
)

if [[ ${#CUSTOM_PROJECTS[@]} -gt 0 ]]; then
    PROJECTS=("${CUSTOM_PROJECTS[@]}")
else
    PROJECTS=("${DEFAULT_PROJECTS[@]}")
fi

# --- Prerequisites ---
echo "=== IJS Corpus Onboarding ==="
echo ""

if [[ -z "$QG_BIN" ]]; then
    echo "WARNING: quality-gate not found in PATH. Telemetry seeding will be skipped."
    echo "  Install with: ./scripts/install.sh"
    SKIP_RUN=true
fi

if [[ ! -d "$CORPUS_PATH" ]]; then
    echo "ERROR: Corpus directory not found: $CORPUS_PATH"
    exit 1
fi

if $DRY_RUN; then
    echo "DRY RUN — no files will be modified"
fi
echo ""

total=${#PROJECTS[@]}
onboarded=0
skipped=0
failed=0
config_only=0
idx=0

for project_path in "${PROJECTS[@]}"; do
    idx=$((idx + 1))
    project_name="$(basename "$project_path")"

    # Check if this project should be skipped entirely
    skip=false
    for skip_path in "${SKIP_PROJECTS[@]}"; do
        if [[ "$project_path" == "$skip_path" ]]; then
            skip=true
            break
        fi
    done
    if $skip; then
        printf "[%2d/%d] %-30s SKIP (already onboarded)\n" "$idx" "$total" "$project_name"
        skipped=$((skipped + 1))
        continue
    fi

    if [[ ! -d "$project_path" ]]; then
        printf "[%2d/%d] %-30s SKIP (directory not found)\n" "$idx" "$total" "$project_name"
        skipped=$((skipped + 1))
        continue
    fi

    start_time=$SECONDS
    has_package=false
    has_git=false
    status="SUCCESS"

    [[ -f "$project_path/Package.swift" ]] && has_package=true
    [[ -d "$project_path/.git" ]] && has_git=true

    # --- Step 1: Development guidelines ---
    if [[ -d "$project_path/development-guidelines" ]]; then
        if [[ -f "$project_path/development-guidelines/scripts/update.sh" ]]; then
            if ! $DRY_RUN; then
                (cd "$project_path" && bash development-guidelines/scripts/update.sh) >/dev/null 2>&1 || true
            fi
        fi
    else
        if $DRY_RUN; then
            echo "  Would clone development-guidelines into $project_path"
        else
            git clone --depth 1 "$GUIDELINES_REPO" "$project_path/development-guidelines" >/dev/null 2>&1 || {
                echo "  WARNING: Failed to clone development-guidelines for $project_name"
            }
        fi
    fi

    # --- Step 2: .quality-gate.yml ---
    config_file="$project_path/.quality-gate.yml"
    if [[ -f "$config_file" ]]; then
        if grep -q "^consistency:" "$config_file" 2>/dev/null; then
            : # Already has consistency section
        else
            if $DRY_RUN; then
                echo "  Would append consistency section to $config_file"
            else
                cat >> "$config_file" << EOF

consistency:
  corpusPath: $CORPUS_PATH
  projectID: $project_name
  consistencyThreshold: 0.7
  defaultRiskTier: 2
EOF
            fi
        fi
    else
        if $DRY_RUN; then
            echo "  Would create $config_file"
        else
            cat > "$config_file" << EOF
consistency:
  corpusPath: $CORPUS_PATH
  projectID: $project_name
  consistencyThreshold: 0.7
  defaultRiskTier: 2
EOF
        fi
    fi

    # --- Step 3: Install hooks ---
    if $has_git && [[ -f "$project_path/development-guidelines/scripts/install-hooks.sh" ]]; then
        if ! $DRY_RUN; then
            (cd "$project_path" && bash development-guidelines/scripts/install-hooks.sh) >/dev/null 2>&1 || true
        fi
    fi

    # --- Step 4: CLAUDE.md template ---
    if [[ ! -f "$project_path/CLAUDE.md" ]] && [[ -f "$project_path/development-guidelines/templates/CLAUDE.md" ]]; then
        if ! $DRY_RUN; then
            cp "$project_path/development-guidelines/templates/CLAUDE.md" "$project_path/CLAUDE.md" 2>/dev/null || true
        fi
    fi

    # --- Step 5: Seed initial telemetry ---
    if $has_package && ! $SKIP_RUN && ! $DRY_RUN && [[ -n "$QG_BIN" ]]; then
        (cd "$project_path" && "$QG_BIN" \
            --check all \
            --exclude test \
            --exclude doc-lint \
            --exclude disk-clean \
            --exclude memory-builder \
            --exclude unreachable \
            --exclude status \
            --strict \
            --continue-on-failure) >/dev/null 2>&1
        qg_exit=$?
        if [[ $qg_exit -ne 0 ]]; then
            status="PARTIAL (gate exit $qg_exit)"
        fi
    elif ! $has_package; then
        status="CONFIG ONLY (no Package.swift)"
        config_only=$((config_only + 1))
    elif $SKIP_RUN || $DRY_RUN; then
        status="CONFIG ONLY (run skipped)"
        config_only=$((config_only + 1))
    fi

    elapsed=$((SECONDS - start_time))
    printf "[%2d/%d] %-30s %s (%ds)\n" "$idx" "$total" "$project_name" "$status" "$elapsed"
    onboarded=$((onboarded + 1))
done

echo ""
echo "=========================================="
echo "Onboarded: $onboarded  Skipped: $skipped  Config-only: $config_only  Failed: $failed"
echo ""
echo "Verify:"
echo "  quality-gate dashboard --summary"
echo "  ls $CORPUS_PATH/telemetry/ | wc -l"
echo "=========================================="
