# Contributing to quality-gate-swift

Thanks for your interest in contributing! This project follows a design-first TDD workflow.

## Getting Started

```bash
git clone https://github.com/jpurnell/quality-gate-swift.git
cd quality-gate-swift
swift build
swift test
```

Requires macOS 14+ and Swift 6.0+.

## Development Workflow

```
0. DESIGN   — Propose architecture (for non-trivial changes)
1. RED      — Write failing tests first
2. GREEN    — Minimum code to pass
3. REFACTOR — Clean up, keep tests green
4. DOCUMENT — DocC comments for public APIs
5. VERIFY   — swift build + swift test with zero warnings
```

## Adding a New Checker

1. Create a new module in `Sources/` implementing `QualityChecker`
2. Add a test target in `Tests/`
3. Register the checker in `QualityGateCLI.swift`
4. Add per-checker config to `Configuration.swift` if needed
5. Update the README checker table

## Adding Security Rules

Security rules live in `Sources/SafetyAuditor/SecurityVisitor.swift`. To add a rule:

1. Add the visitor method to `SecurityVisitor`
2. Register metadata in `SecurityRuleManifest.swift` with CWE and OWASP mapping
3. Set `lastReviewedDate` to today
4. Write positive (must flag) and negative (must NOT flag) tests
5. Add a corresponding Semgrep YAML rule to [swift-security-rules](https://github.com/jpurnell/swift-security-rules)

## Code Standards

- No force unwraps (`!`), no `try!`, no force casts (`as!`)
- Guard clauses for validation; early returns over nesting
- Swift 6 strict concurrency compliance (`Sendable`)
- DocC documentation for all public APIs
- All tests must pass before submitting a PR

## Pull Requests

1. Fork the repository
2. Create a feature branch from `main`
3. Follow the TDD workflow above
4. Ensure `swift build` and `swift test` pass with zero warnings
5. Submit a PR with a clear description of what and why

## Reporting Issues

Open an issue with:
- What you expected
- What happened instead
- Steps to reproduce
- Swift version (`swift --version`)
