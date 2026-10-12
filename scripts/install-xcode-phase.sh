#!/bin/bash
# Installs a "Quality Gate" Run Script build phase into an Xcode project, so findings
# appear inline in the issue navigator while you work.
#
# Usage: ./scripts/install-xcode-phase.sh [path/to/Project.xcodeproj] [--blocking] [--force]
#
#   (no path)    Finds a single .xcodeproj in the current directory.
#   --blocking   Findings fail the build. Default is advisory: warnings and errors are
#                shown inline, the build proceeds.
#   --force      Replace a "Quality Gate" phase this script did not write.
#
# Why a build phase and not a plugin: a SwiftPM BuildToolPlugin runs sandboxed, with no
# network and restricted writes, and this tool runs `swift build`, `swift test` and reads an
# index store. It also would recurse — a plugin invoking a build from inside a build. A Run
# Script phase is the only place in Xcode where this can run on every build.
#
# This complements the git hooks rather than replacing them. The phase is advisory and lives
# in one project; the hook blocks the commit and works for anyone, including people who never
# open Xcode. Install both: scripts/install-hooks.sh does the other half.

set -euo pipefail

PROJECT=""
BLOCKING="no"
FORCE="no"
for arg in "$@"; do
    case "$arg" in
        --blocking) BLOCKING="yes" ;;
        --force)    FORCE="yes" ;;
        *.xcodeproj) PROJECT="$arg" ;;
        *) echo "Unknown argument: $arg"; exit 2 ;;
    esac
done

if [[ -z "$PROJECT" ]]; then
    # Deliberately refuses when there is more than one: guessing which project a repository
    # meant would be a silent wrong answer in exactly the repositories that are hardest to
    # check afterwards.
    mapfile -t FOUND < <(find . -maxdepth 2 -name '*.xcodeproj' -not -path '*/.build/*' 2>/dev/null)
    if [[ ${#FOUND[@]} -eq 1 ]]; then
        PROJECT="${FOUND[0]}"
    elif [[ ${#FOUND[@]} -eq 0 ]]; then
        echo "No .xcodeproj found here. Pass one explicitly."
        exit 1
    else
        echo "More than one .xcodeproj found; name the one you mean:"
        printf '  %s\n' "${FOUND[@]}"
        exit 1
    fi
fi

if [[ ! -d "$PROJECT" ]]; then
    echo "Not a project: $PROJECT"
    exit 1
fi

if ! ruby -e "require 'xcodeproj'" 2>/dev/null; then
    echo "The 'xcodeproj' gem is required to edit a project file safely."
    echo "  gem install xcodeproj"
    echo ""
    echo "Refusing to edit the .pbxproj by hand: a malformed project file is a worse"
    echo "outcome than an uninstalled build phase, and text surgery on that format is"
    echo "how you get one."
    exit 1
fi

PROJECT="$PROJECT" BLOCKING="$BLOCKING" FORCE="$FORCE" ruby <<'RUBY'
require 'xcodeproj'

MARKER = 'installed by scripts/install-xcode-phase.sh'
PHASE_NAME = 'Quality Gate'

project_path = ENV.fetch('PROJECT')
blocking = ENV.fetch('BLOCKING') == 'yes'
force = ENV.fetch('FORCE') == 'yes'

# Advisory by default. A phase that runs on every build and fails it on a pre-existing
# finding makes the project unbuildable until the backlog is cleared, which is how a tool
# gets removed rather than adopted. `quality-gate adopt` is the route to a clean gate on a
# codebase with history; --blocking is for after that.
tail = blocking ? '' : ' || true'

script = <<~SH
  # #{PHASE_NAME} (#{MARKER})
  #
  # Checker selection matters here: this runs on EVERY build. The three below are static
  # and fast. Never put `--check all` in a build phase — `build`, `test` and `unreachable`
  # would run a build inside your build.
  if command -v quality-gate >/dev/null 2>&1; then
    quality-gate --format xcode --check safety --check concurrency --check fp-safety#{tail}
  else
    # Visible rather than silent: a gate that is not installed should say so, not look
    # like a clean run.
    echo "warning: quality-gate not installed — not checked. See github.com/jpurnell/quality-gate-swift"
  fi
SH

project = Xcodeproj::Project.open(project_path)

# Test targets are skipped: their findings are about test code, which the gate's own
# `--exclude test` convention already treats separately.
targets = project.native_targets.reject { |t| t.test_target_type? }
if targets.empty?
  warn "No non-test targets in #{project_path}; nothing to install into."
  exit 1
end

changed = []
targets.each do |target|
  existing = target.shell_script_build_phases.find do |p|
    p.name == PHASE_NAME || (p.shell_script || '').include?(MARKER)
  end

  if existing && !(existing.shell_script || '').include?(MARKER) && !force
    warn "#{target.name}: a '#{PHASE_NAME}' phase exists that this script did not write."
    warn "  Inspect it, then re-run with --force to replace it."
    next
  end

  phase = existing || target.new_shell_script_build_phase(PHASE_NAME)
  phase.shell_script = script
  phase.shell_path = '/bin/sh'
  # "Based on dependency analysis" unchecked. With it checked and no declared outputs,
  # Xcode runs the phase once and then considers it up to date forever — the phase appears
  # installed and silently stops running.
  phase.always_out_of_date = '1' if phase.respond_to?(:always_out_of_date=)
  changed << target.name
end

if changed.empty?
  puts "Nothing changed."
  exit 0
end

project.save
puts "Installed '#{PHASE_NAME}' into: #{changed.join(', ')}"
puts blocking ? "Mode: blocking — findings fail the build." :
                "Mode: advisory — findings appear inline, the build proceeds. Re-run with --blocking to enforce."
RUBY

echo ""
echo "Also install the git hooks, which are the half that actually blocks a bad commit:"
echo "  ./scripts/install-hooks.sh"
