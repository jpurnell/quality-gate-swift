# Changelog

## 1.0.0

- Initial release with 17 quality-gate checkers
- CLI with `--check all`, `--exclude`, `--strict`, `--continue-on-failure` flags
- JSON, SARIF, and terminal output formats
- `--fix` and `--dry-run` for auto-fixable checkers
- `--bootstrap` for generating initial status documents

## 1.1.0

- Add 5 new precision/institutional checkers:
  - DependencyAuditor: Package.resolved sync, branch pins, local overrides
  - ReleaseReadinessAuditor: CHANGELOG entries, README placeholders, bare TODOs
  - FloatingPointSafetyAuditor: FP equality comparisons, unguarded division
  - StochasticDeterminismAuditor: unseeded randomness in production code
  - MemoryLifecycleGuard: un-cancelled Tasks, strong delegate references
- Add MCPReadinessAuditor (opt-in): schema-implementation cross-reference for MCP tools
- Exclude unreachable checker from pre-push hook for faster local pushes
- DocC catalogs for all checker modules
