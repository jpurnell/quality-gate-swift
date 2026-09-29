import Foundation
import IndexStoreInfra
#if canImport(os)
import os
#endif
import QualityGateCore

/// Finds the places where a value that is not a number gets an answer anyway.
///
/// `fp-safety` asks whether a divisor is guarded. This checker asks what becomes
/// of a NaN once it is in the program: it is never raised, only carried, and
/// every comparison with it quietly answers *no*.
///
/// Detected rules:
/// - `fallback.int-conversion-unguarded` (error) — `Int(x)` on a floating-point
///   `x` with nothing before it that shows `x` is representable. `Int(.nan)`,
///   `Int(.infinity)` and `Int(1e300)` all stop the process.
/// - `fallback.clamp-absorbs-nan` (warning) — `max(a, min(b, x))`, which returns
///   `b` for a NaN. `Swift.min` and `Swift.max` return their first argument when
///   either is one.
/// - `fallback.classification-omits-nan` (warning) — an `if` / `else if` chain
///   that sorts a value by comparison. A NaN passes no comparison, so it takes
///   the trailing `else`, or no arm at all.
/// - `fallback.guard-returns-a-value` (note) — `guard x > 0 else { return 0 }`,
///   which a NaN fails. Advisory and never gating: whether `0` is the right
///   answer is not something a checker can know. It is answered by naming the
///   fallback in the documentation's `- Returns:` clause, by refusing (`nil`,
///   `throw`, `.nan`), or by `// fallback-justified: <reason>` on the line above.
/// - `fallback.justification-empty` (warning) — that marker with no reason.
///
/// The conversion is accepted when the enclosing function bounds the value's
/// magnitude in the conditions of a `guard` — `guard abs(x) < limit`,
/// `guard x >= 0, x < limit` — or bounds it anywhere and also tests `x.isFinite`.
/// `isFinite` alone is not accepted: `1e300` is finite. `Int(exactly:)` is always
/// accepted, because it returns `nil` instead of trapping.
///
/// ## What it cannot see
///
/// Types are read from syntax, one file at a time. A parameter, a local, a
/// generic parameter constrained to `Real`, `BinaryFloatingPoint` or
/// `FloatingPoint`, and a member whose every declaration in the file agrees are
/// known; a member declared in another file is not, and a conversion of one is
/// skipped rather than guessed. The coverage note says how many conversions were
/// examined, which is the number to read a clean result against.
///
/// A check applied upstream through a collection —
/// `rates.filter { $0.tenor.isFinite }` — is not recognised. The rule asks for
/// the check in the function that converts.
public struct FallbackAuditor: QualityChecker, Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "FallbackAuditor")

    /// Unique identifier for this checker.
    public let id = "fallback"
    /// Human-readable display name for this checker.
    public let name = "Fallback Auditor"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "A NaN that traps an integer conversion, is clamped to a bound, is sorted into the last arm, or is answered for by a guard"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.correctness

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Analyses source without running it — safe to point at a stranger's package.
    public let executesProjectCode = false

    /// Creates a fallback auditor.
    public init() {}

    /// Declares this checker cacheable on the source tree it reads.
    ///
    /// Syntactic analysis over the sources, with no clock, corpus, network or
    /// out-of-tree path among its inputs.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        SourceCacheInputs.wholeSourceAndDocs(
            projectRoot: configuration.resolvedProjectRoot,
            configuration: configuration
        )
    }

    /// Audits every Swift file under the project root that is not test code.
    ///
    /// - Parameter configuration: Project-specific configuration.
    /// - Returns: A `CheckResult` with status `.failed` if an unguarded
    ///   conversion was found, `.warning` if only a clamp or a classification
    ///   was, `.passed` otherwise.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let root = configuration.resolvedProjectRoot
        let scan = SourceWalker.walk(under: root, excludePatterns: configuration.excludePatterns)
        let rootPath = root.resolvingSymlinksInPath().path

        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []
        var conversionsExamined = 0
        var clampsExamined = 0
        var classificationsExamined = 0
        var guardsExamined = 0
        var filesExamined = 0

        for fullPath in scan.files {
            let relativePath = fullPath.hasPrefix(rootPath)
                ? String(fullPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : fullPath
            // Judged on the repository-relative path: an absolute one carries the
            // checkout's own directory names, and a checkout under `…/Tests/…`
            // would otherwise exempt every file in it.
            guard !FallbackRules.isTestFile(relativePath) else { continue }

            do {
                let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                let result = FallbackRules.audit(source: source, fileName: fullPath, isTestFile: false)
                diagnostics.append(contentsOf: result.diagnostics)
                overrides.append(contentsOf: result.overrides)
                conversionsExamined += result.conversionsExamined
                clampsExamined += result.clampsExamined
                classificationsExamined += result.classificationsExamined
                guardsExamined += result.guardsExamined
                filesExamined += 1
            } catch {
                Self.logger.warning("Failed to read source file \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
        }

        func found(_ ruleId: String) -> Int {
            diagnostics.filter { $0.ruleId == ruleId }.count
        }
        // Emitted pass or fail — examined-nothing must not look like found-nothing.
        diagnostics.append(Diagnostic(
            severity: .note,
            message: "fallback examined \(Self.counted(filesExamined, "file")) · "
                + "\(Self.counted(conversionsExamined, "integer conversion")) of a floating-point value, "
                + "\(found(FallbackRuleID.intConversionUnguarded)) unguarded · "
                + "\(Self.counted(clampsExamined, "clamp")), "
                + "\(found(FallbackRuleID.clampAbsorbsNaN)) absorbing a NaN · "
                + "\(Self.counted(classificationsExamined, "classification")), "
                + "\(found(FallbackRuleID.classificationOmitsNaN)) with no arm for one · "
                + "\(Self.counted(guardsExamined, "guard")) answering with a value, "
                + "\(found(FallbackRuleID.guardReturnsAValue)) undeclared, "
                + "\(overrides.count) justified"
                + (scan.exclusionClause.map { " · \($0)" } ?? ""),
            ruleId: FallbackRuleID.coverage))

        return CheckResult(
            checkerId: id,
            status: Self.status(for: diagnostics),
            diagnostics: diagnostics,
            overrides: overrides,
            duration: ContinuousClock.now - startTime
        )
    }

    /// Audits a single source string.
    ///
    /// Useful for testing or single-file analysis without filesystem access.
    ///
    /// - Parameters:
    ///   - source: The Swift source code to analyze.
    ///   - fileName: The file path used in emitted diagnostics.
    ///   - configuration: The quality-gate configuration.
    /// - Returns: A `CheckResult` with all diagnostics found.
    public func auditSource(
        _ source: String,
        fileName: String,
        configuration: Configuration
    ) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let result = FallbackRules.audit(source: source, fileName: fileName)
        return CheckResult(
            checkerId: id,
            status: Self.status(for: result.diagnostics),
            diagnostics: result.diagnostics,
            overrides: result.overrides,
            duration: ContinuousClock.now - startTime
        )
    }

    // MARK: - Private

    /// `.failed` on an error, `.warning` on a warning, `.passed` on notes alone.
    private static func status(for diagnostics: [Diagnostic]) -> CheckResult.Status {
        if diagnostics.contains(where: { $0.severity == .error }) { return .failed }
        if diagnostics.contains(where: { $0.severity == .warning }) { return .warning }
        return .passed
    }

    /// `1 file`, `2 files`.
    private static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
