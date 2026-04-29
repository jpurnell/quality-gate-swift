# ``SwiftVersionChecker``

Checks that a project's `swift-tools-version` meets a configurable minimum and verifies upgrades via trial builds.

## Overview

SwiftVersionChecker enforces a minimum Swift tools version for your project by parsing `Package.swift`, comparing against a configured threshold, and running a trial build to verify upgrade feasibility. When `--fix` is passed, it rewrites the version line and validates the change compiles before committing it.

### How It Works

1. **Parse** -- Reads `Package.swift` and extracts the `swift-tools-version` comment using regex. Handles formats with and without spaces after the colon, and versions with 1-3 components.
2. **Compare** -- Compares the parsed version against the configured minimum. Missing version components are treated as zero (e.g., `"6.0"` equals `"6.0.0"`).
3. **Verify** -- If below minimum, temporarily rewrites `Package.swift` to the target version and runs `swift build`. The original file is always restored after the trial.
4. **Optionally fix** -- In fix mode, permanently updates the version line, verifies the build succeeds, and reverts if it fails.

### Configuration

Configure via `.quality-gate.yml`:

```yaml
swiftVersion:
  minimum: "6.2"       # Minimum required swift-tools-version
  checkCompiler: true   # Report local compiler version for context
```

When `checkCompiler` is enabled, the checker also runs `swift --version` and warns if the tools version exceeds the installed compiler version.

### FixableChecker Behavior

SwiftVersionChecker conforms to `FixableChecker`. When `--fix` is invoked:

1. Creates a timestamped backup of `Package.swift`
2. Rewrites the `swift-tools-version` line to the configured minimum
3. Runs `swift build` to verify the project compiles
4. **On success** -- keeps the change and reports the modification
5. **On failure** -- reverts to the backup and reports the diagnostics as unfixed with a "manual intervention required" error

This ensures `--fix` never leaves the project in a broken state.

### Out of Scope

- **Language feature migration** -- SwiftVersionChecker does not modify source code to adopt newer Swift features. It only changes the `swift-tools-version` declaration.
- **Multi-package workspaces** -- Only the `Package.swift` in the current working directory is checked.
- **Toolchain installation** -- The checker reports compiler mismatches but does not install or manage Swift toolchains.

## Topics

### Essentials

- ``SwiftVersionChecker/check(configuration:)``
- ``SwiftVersionChecker/fix(diagnostics:configuration:)``
- ``SwiftVersionChecker/fixDescription``

### Version Parsing

- ``SwiftVersionChecker/parseToolsVersion(from:)``
- ``SwiftVersionChecker/parseCompilerVersion(from:)``
- ``SwiftVersionChecker/compareVersions(_:_:)``

### Result Construction

- ``SwiftVersionChecker/createCheckResult(toolsVersion:minimumVersion:compilerVersion:checkCompiler:verificationResult:duration:)``
- ``SwiftVersionChecker/rewriteToolsVersion(in:to:)``
- ``VerificationResult``
