# quality-gate-swift — Project Description

## Short Description (Reddit / Forum Post)

I've been doing a lot of AI-pair programming, but I really want to enforce both a development process and coding standards, so I've been building **quality-gate-swift** — basically a modular static analysis tool that runs as a pre-commit hook.

It's a CLI tool (built on ArgumentParser) that runs ~29 "auditors" over my Swift source. It uses IndexStore to walk the AST and can look for patterns across files. Right now it catches things like:

- **SafetyAuditor** — force unwraps, force casts, `try!`
- **FloatingPointSafetyAuditor** — unguarded division, `==` on floats
- **RecursionAuditor** — self-forwarding inits, self-referencing computed properties, infinitely recursive protocol defaults
- **PointerEscapeAuditor** — pointers escaping `withUnsafe*` blocks
- **ConcurrencyAuditor** — `@unchecked Sendable` without justification, mutable Sendable classes, DispatchQueue inside actors
- **ComplexityAnalyzer** — cyclomatic complexity, deeply nested code
- **MemoryLifecycleGuard** — retain cycles, missing `[weak self]`
- **LoggingAuditor** — `print()` instead of `os.Logger`, empty catch blocks, silent `try?`
- **DocCoverageChecker** — missing documentation on public API
- **DocLinter** — malformed doc comments
- **TestQualityAuditor** — non-specific assertions (`!= nil`, `!= 0`), test hygiene
- **StochasticDeterminismAuditor** — unseeded `.random()` in tests
- **AccessibilityAuditor** — missing accessibility labels/traits in SwiftUI views
- **HIGAuditor** — Human Interface Guidelines compliance
- **AppIntentsAuditor** — App Intents API usage patterns
- **MCPReadinessAuditor** — MCP server implementation checks
- **DependencyAuditor** — dependency graph issues
- **ConsistencyChecker** — cross-file naming/pattern consistency
- **UnreachableCodeAuditor** — dead code after returns/throws
- **ProcessSafetyAuditor** — unsafe `Process` usage
- **ContextAuditor** — context propagation issues
- **StatusAuditor** — status/state management patterns
- **ReleaseReadinessAuditor** — pre-release checks (TODOs, debug code)
- **XcodeBuildChecker** — Xcode build setting validation
- **SwiftVersionChecker** — Swift version compatibility

I've also been working on an "Institutional Judgment Score" — just a way to track how my projects score against the strict version of the gate over time, so I can see if I'm actually getting better or just writing the same bugs in new places.

It's on GitHub if anyone's curious.
