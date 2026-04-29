# ``DiskCleaner``

Identifies and removes build artifacts and compresses git history to reclaim disk space.

## Overview

DiskCleaner scans the current working directory for build artifacts and derived data that accumulate during development. It removes these artifacts and optionally runs `git gc` to compress repository history, freeing disk space without affecting source files.

### What It Detects

- **`.build/`** - Swift Package Manager build artifacts in the project root
- **`.docc-build/`** - DocC documentation build output, found recursively throughout the project tree
- **`.git/` bloat** - Compressible git object history eligible for garbage collection

### Safety Model

DiskCleaner operates directly on known build artifact directories. It **only** targets generated output that can be fully reconstructed by rebuilding:

- `.build/` and `.docc-build/` directories are always safe to remove; SPM and DocC regenerate them on the next build
- Git garbage collection (`git gc --aggressive --prune=now`) compresses history but never discards reachable commits
- Source files, configuration, and version-controlled content are never touched
- The checker always returns a **passed** status; cleanup failures are reported as warnings rather than gate failures

### Configuration

DiskCleaner has no module-specific configuration options. It runs against the current working directory and is controlled through the standard `.quality-gate.yml` checker selection:

```yaml
enabled_checkers:
  - disk-clean
```

### Out of Scope

DiskCleaner does not manage:

- **Xcode DerivedData** (`~/Library/Developer/Xcode/DerivedData/`) - outside the project directory
- **CocoaPods or Carthage caches** - not part of the SPM workflow
- **User-created files or directories** - only well-known build output paths are targeted
- **Remote repository operations** - no `git push`, `git fetch`, or network activity

## Topics

### Essentials

- ``DiskCleaner/check(configuration:)``
- ``DiskCleaner/id``
- ``DiskCleaner/name``
