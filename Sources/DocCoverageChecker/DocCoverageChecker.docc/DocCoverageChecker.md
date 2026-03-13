# ``DocCoverageChecker``

Identifies undocumented public APIs using SwiftSyntax analysis.

## Overview

DocCoverageChecker scans Swift source files to find public declarations that are missing documentation comments. It helps maintain documentation coverage across your codebase.

### What It Detects

The checker finds undocumented:

| Declaration Type | Example |
|-----------------|---------|
| **Functions** | `public func calculate()` |
| **Structs** | `public struct User` |
| **Classes** | `public class Manager` |
| **Enums** | `public enum State` |
| **Protocols** | `public protocol Delegate` |
| **Properties** | `public var count: Int` |
| **Initializers** | `public init()` |
| **Type aliases** | `public typealias ID = String` |

### What Counts as Documentation

Only Swift documentation comments (`///`) are recognized:

```swift
/// This is documentation.
public func documented() {}

// This is NOT documentation (regular comment)
public func undocumented() {}

/* This is NOT documentation (block comment) */
public func alsoUndocumented() {}
```

### How It Works

1. Parses Swift source files using SwiftSyntax
2. Walks the syntax tree to find public declarations
3. Checks leading trivia for documentation comments
4. Reports missing documentation with file:line locations

### Configuration

Configure via `.quality-gate.yml`:

```yaml
excludePatterns:
  - "**/Generated/**"    # Skip generated code
  - "**/Vendor/**"       # Skip vendored dependencies
```

### Example Output

```
warning: Public function 'calculate' is missing documentation
  -> Sources/Math/Calculator.swift:42:5
  Fix: Add /// documentation comment above the declaration
```

## Topics

### Essentials

- ``DocCoverageChecker/check(configuration:)``
- ``DocCoverageChecker/checkSource(_:fileName:configuration:)``

### Configuration

- ``DocCoverageChecker/shouldExclude(path:patterns:)``
