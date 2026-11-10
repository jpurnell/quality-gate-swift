import Foundation
import QualityGateCore

/// Flags values the design tokens own — colours, type sizes, corner radii, grid widths — when
/// they are written outside the tokens.
///
/// Opt-in: nothing is read until `designTokens.enabled` is `true`. Three kinds of file may write
/// such a value, each declared in `.quality-gate.yml` and none by a comment in a source file: the
/// tokens package, an app's own palette, and tests when the project chooses to exempt them. A
/// declared palette is **validated** on every run rather than skipped: a listed file that no
/// longer exists, or that defines no colour, is itself an error, so an exemption cannot outlive
/// its reason.
///
/// Swift is read with SwiftSyntax. CSS and HTML are read only under `designTokens.cssPaths`,
/// against the generated token files in `designTokens.tokenFiles`. The proposal is
/// `DesignTokenDriftIsAFinding.md`; the rules are in `SwiftDrift` and `CSSDrift`.
public struct DesignTokenDriftAuditor: QualityChecker, Sendable {

    /// Unique identifier for this auditor.
    public let id = "design-token-drift"
    /// Human-readable display name for this auditor.
    public let name = "Design Token Drift Auditor"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Colours, fonts, corner radii and grid widths written outside the design tokens; app palettes are declared and validated, never skipped (opt-in)"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.codeHygiene

    /// What this checker's findings are about: our design standard, which a stranger's repository never agreed to.
    public let kind = CheckerKind.convention

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Reads files; runs nothing.
    public let executesProjectCode = false

    /// Creates the auditor.
    public init() {}

    /// Runs the drift checks under the project root.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let start = ContinuousClock.now
        let config = configuration.designTokens
        guard config.enabled else {
            return CheckResult(checkerId: id, status: .skipped, diagnostics: [], duration: ContinuousClock.now - start)
        }

        let files = ProjectFiles(root: configuration.resolvedProjectRoot, excludePatterns: configuration.excludePatterns)
        var run = DriftRun(config: config, files: files)
        run.execute()

        let diagnostics = run.diagnostics
        let status: CheckResult.Status = diagnostics.contains { $0.severity == .error }
            ? .failed : (diagnostics.contains { $0.severity == .warning } ? .warning : .passed)
        return CheckResult(
            checkerId: id, status: status, diagnostics: diagnostics, duration: ContinuousClock.now - start)
    }
}
