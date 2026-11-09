import Foundation
import QualityGateCore

/// Checks an Apple skills bundle against the constraints that fail silently.
///
/// A `.skillsbundle` that breaks a rule is not rejected at build time: it is simply not offered
/// to Siri. This is a file-tree checker, not an AST one: the facts are folder names, the shape
/// of each `SKILL.md`, and which Xcode target copies the bundle. A project with no
/// `.skillsbundle` is skipped, so the checker costs a project that does not use skills nothing.
///
/// Rules are in `SkillsAudit`; the proposal is `OneReadinessManyCarriers.md` §4.5.
public struct AppSkillsAuditor: QualityChecker, Sendable {

    /// Unique identifier for this auditor.
    public let id = "app-skills"
    /// Human-readable display name for this auditor.
    public let name = "App Skills Auditor"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Apple skills bundles: folder names, SKILL.md shape, size, and whether the target copies the bundle"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.specialty

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Reads folders and one project file; runs nothing.
    public let executesProjectCode = false

    /// Creates the auditor.
    public init() {}

    /// Runs the skills checks under the project root.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let start = ContinuousClock.now
        let root = configuration.resolvedProjectRoot

        guard !SkillsAudit.bundles(under: root).isEmpty else {
            return CheckResult(
                checkerId: id, status: .skipped, diagnostics: [], duration: ContinuousClock.now - start)
        }

        let diagnostics = SkillsAudit.analyze(root: root)
        let status: CheckResult.Status = diagnostics.contains { $0.severity == .error }
            ? .failed : (diagnostics.contains { $0.severity == .warning } ? .warning : .passed)
        return CheckResult(
            checkerId: id, status: status, diagnostics: diagnostics, duration: ContinuousClock.now - start)
    }
}
