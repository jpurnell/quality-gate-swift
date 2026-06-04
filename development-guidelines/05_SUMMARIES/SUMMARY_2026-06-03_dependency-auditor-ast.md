# Session Summary: DependencyAuditor Regex-to-AST Migration (2026-06-03)

## Problem

The DependencyAuditor was the only checker in quality-gate-swift still using
NSRegularExpression for code parsing. Six regex patterns parsed Package.swift
manifests and Swift source files, despite SwiftSyntax/SwiftParser being
available project-wide. The regex for `extractProductNames` only matched
`.product(name:` but Package.swift uses `.library(name:`, `.executable(name:`,
etc. — causing false positive `dep-hallucinated-import` warnings for sub-products
like `RealModule` from swift-numerics.

## Changes Made

### 1. ManifestParser (new file)

Created `Sources/DependencyAuditor/ManifestParser.swift` (88 lines) with a
SwiftSyntax `SyntaxVisitor` that walks Package.swift AST to extract:
- Package dependency URLs (`.package(url:)`)
- Declared package names (`.package(name:)`)
- Target names (`.target()`, `.executableTarget()`, `.testTarget()`, `.plugin()`,
  `.systemLibrary()`, `.binaryTarget()`, `.macro()`)
- Product names (`.library()`, `.executable()`, `.plugin()`, `.product()`)
- Exclude paths (`exclude: [...]` array arguments)

Single `ManifestParser.parse(source:)` call returns all info — no re-parsing.

### 2. ImportVisitor (in DependencyAuditor.swift)

Replaced the 65-line regex-based `extractImports()` with a 40-line
`ImportVisitor: SyntaxVisitor` that:
- Visits `ImportDeclSyntax` for imports (handles `@preconcurrency`, `@testable`)
- Visits `IfConfigClauseSyntax` for `#if canImport(X)` guard detection
- Naturally skips imports inside string literals (AST doesn't parse string content)
- No manual multi-line string boundary tracking needed

### 3. DependencyAuditor.swift Refactoring

- Added `import SwiftSyntax` and `import SwiftParser`
- Replaced all 6 regex function bodies with AST delegation
- Refactored `runHallucinatedImportCheck` to parse each manifest once
  (was parsing 3x per file for targets, products, and declared names)
- Changed `addURLDerivedNames` to take pre-extracted `[String]` URLs
- Removed `countOccurrences` helper (only used by regex import parser)
- Net reduction: -105 lines (820 -> 715)

### 4. Package.swift

Added SwiftSyntax + SwiftParser as dependencies of the DependencyAuditor target.

### 5. Test Updates

Updated 3 tests that used bare fragment strings (`.target(name: "A"),`) as
input — these worked with regex but not with AST parsing. Wrapped them in
valid `let package = Package(...)` declarations to match real Package.swift
structure.

## Files Changed

| File | Action | Lines |
|------|--------|-------|
| Package.swift | Modified | +4 |
| Sources/DependencyAuditor/ManifestParser.swift | New | 88 |
| Sources/DependencyAuditor/DependencyAuditor.swift | Modified | -105 net |
| Tests/DependencyAuditorTests/DependencyAuditorTests.swift | Modified | +15 |
| CHANGELOG.md | Updated | test counts, AST entry |
| README.md | Updated | test counts, descriptions |

### 6. Quality Gate Warning Fixes

Two follow-up commits to reach 0/0:
- Added `// silent:` annotations for two `try?` calls in checkout scanning block
- Added `// lifecycle:exempt` to `delegatePropertyInfos` (false positive on the
  checker's own metadata property)
- Fixed `// silent:` → `// logging:` on two catch blocks in MemoryLifecycleGuard
  (catch block exemption uses `logging:` keyword, not `silent:`)

## Commits

| Hash | Description |
|------|-------------|
| `892d0a9` | Replace DependencyAuditor regex parsing with SwiftSyntax AST |
| `13975aa` | Fix 5 quality-gate warnings: silent try?, catch annotations, lifecycle:exempt |
| `d112784` | Fix catch block annotations: logging: not silent: |

## Verification

- `swift build` passes with zero warnings
- All 1,662 tests pass across 211 suites
- Zero NSRegularExpression usage remaining in DependencyAuditor module
- `grep -r NSRegularExpression Sources/DependencyAuditor/` returns empty
- BusinessMath full gate: 28 checkers pass, 0 errors, 0 warnings
- `import RealModule` false positives eliminated
- Binary deployed to `/usr/local/custom/bin/quality-gate` (v2.0.0, codesigned)
