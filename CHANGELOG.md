# Changelog

## 1.0.0

- 23 checkers across correctness, safety, security, documentation, accessibility, and project health
- 853 tests across 74 test files
- Zero-warning self-audit: all checkers pass clean against the quality-gate-swift codebase
- Comprehensive DocC catalogs for all 25 modules
- CLI with `--check all`, `--exclude`, `--strict`, `--continue-on-failure` flags
- JSON, SARIF, and terminal output formats
- `--fix` and `--dry-run` for auto-fixable checkers
- `--bootstrap` for generating initial status documents
- Severity override system: downgrade or upgrade any rule via `.quality-gate.yml`
- `--auto-build-xcode` for IndexStore generation in Xcode projects
- `QualityGateTestKit` module for writing checker tests
- Reusable GitHub Actions workflow for cross-repo adoption
- Security rule staleness workflow with automated issue creation
- Guide document covering vision, design philosophy, architecture, and integration patterns
