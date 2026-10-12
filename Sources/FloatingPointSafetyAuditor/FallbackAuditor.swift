import Foundation
import IndexStoreInfra
import QualityGateLogging
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
/// `guard x >= 0, x < limit`, `guard allowedRange.contains(x)` against a constant
/// range — or bounds it anywhere and also tests `x.isFinite`. A bound is followed
/// from the value that was checked to a `let` computed from it by arithmetic that
/// keeps it bounded. `isFinite` alone is not accepted: `1e300` is finite.
/// `Int(exactly:)` is always accepted, because it returns `nil` instead of trapping.
///
/// ## Which files it reads
///
/// In a package, files a target may compile; a `.swift` file outside every target
/// is counted in the coverage note and not audited. With no `Package.swift`, or
/// one whose target directories cannot be read, every file — see
/// `FallbackTargetScope` for why it errs that way.
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
/// A check applied upstream to a *member* through a collection —
/// `rates.filter { $0.tenor.isFinite }` — is not recognised, and neither is one
/// made in a function that is called. The rule asks for the check in the
/// function that converts.
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

    /// Audits every Swift file under the project root that a target may compile and
    /// that is not test code.
    ///
    /// In a package, a file outside every target — a reference script, an example
    /// kept beside the documentation — is not audited, and the coverage note says how
    /// many there were. With no `Package.swift`, or one whose target directories
    /// cannot be read, every file is audited.
    ///
    /// - Parameter configuration: Project-specific configuration.
    /// - Returns: A `CheckResult` with status `.failed` if an unguarded
    ///   conversion was found, `.warning` if only a clamp or a classification
    ///   was, `.passed` otherwise.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let root = configuration.resolvedProjectRoot
        let scan = SourceWalker.walk(under: root, excludePatterns: configuration.excludePatterns)
        // Both spellings of the root. A directory reached through a symlink is
        // enumerated under one and resolved to the other, and a path that matched
        // neither would be judged — for test code and for target membership alike —
        // on its absolute spelling.
        let rootPaths = Self.spellings(of: root)

        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []
        var conversionsExamined = 0
        var clampsExamined = 0
        var classificationsExamined = 0
        var guardsExamined = 0
        var filesExamined = 0

        let scope = FallbackTargetScope.resolve(projectRoot: root)
        var xcode = FallbackXcodeClaims(root: root)
        var outsideTargets = 0
        var sources: [(path: String, text: String)] = []

        for fullPath in scan.files {
            let relativePath = Self.relativePath(of: fullPath, under: rootPaths)
            // Judged on the repository-relative path: an absolute one carries the
            // checkout's own directory names, and a checkout under `…/Tests/…`
            // would otherwise exempt every file in it.
            guard !FallbackRules.isTestFile(relativePath) else { continue }

            // Not in a target, and not beside an Xcode project that might own it:
            // nothing compiles it. Counted, so the note can say what was left out.
            // A path that could not be made relative is audited: nothing can be
            // said about where it sits.
            guard relativePath.hasPrefix("/") || scope.owns(relativePath) || xcode.claims(relativePath) else {
                outsideTargets += 1
                continue
            }

            do {
                sources.append((fullPath, try String(contentsOfFile: fullPath, encoding: .utf8)))
            } catch {
                Self.logger.warning("Failed to read source file \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
        }

        // Read once across the project, so a range constant declared in one file
        // bounds a value tested against it in another.
        let rangeConstants = FallbackProjectRanges.qualifiedConstants(in: sources.map(\.text))

        for source in sources {
            let result = FallbackRules.audit(
                source: source.text,
                fileName: source.path,
                isTestFile: false,
                projectRangeConstants: rangeConstants
            )
            diagnostics.append(contentsOf: result.diagnostics)
            overrides.append(contentsOf: result.overrides)
            conversionsExamined += result.conversionsExamined
            clampsExamined += result.clampsExamined
            classificationsExamined += result.classificationsExamined
            guardsExamined += result.guardsExamined
            filesExamined += 1
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
                + Self.scopeClause(outsideTargets: outsideTargets, resolution: scope.resolution)
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

    /// The absolute paths `root` may be enumerated under: as given, with symlinks
    /// resolved, and as the filesystem canonically names it.
    ///
    /// The third is not the second. `resolvingSymlinksInPath` drops a leading
    /// `/private`, and a directory enumeration under `/var` reports `/private/var`.
    private static func spellings(of root: URL) -> [String] {
        var paths = [root.resolvingSymlinksInPath().path, root.standardizedFileURL.path, root.path]
        do {
            if let canonical = try root.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
                paths.append(canonical)
            }
        } catch {
            logger.debug("No canonical path for \(root.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return paths
    }

    /// `path` relative to whichever spelling of the root it sits under, or `path`
    /// unchanged — still absolute — when it sits under none.
    private static func relativePath(of path: String, under roots: [String]) -> String {
        let file = path.split(separator: "/")
        for root in roots {
            let base = root.split(separator: "/")
            guard file.count > base.count, file.starts(with: base) else { continue }
            return file.dropFirst(base.count).joined(separator: "/")
        }
        return path
    }

    /// What the coverage note says about target scope, or nothing when every file
    /// found was in a target.
    ///
    /// Absent in the ordinary case so that it is read in the others: when files were
    /// left out, and when a manifest was present and could not be used to leave any
    /// out — a package whose scripts are still being audited deserves to know why.
    private static func scopeClause(outsideTargets: Int, resolution: FallbackTargetScope.Resolution) -> String {
        if outsideTargets > 0 {
            return " · \(outsideTargets) .swift file\(outsideTargets == 1 ? "" : "s") outside any SwiftPM target not audited"
        }
        if resolution == .unreadable {
            return " · target paths in Package.swift could not be read, so every file was audited"
        }
        return ""
    }

    /// `1 file`, `2 files`.
    private static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
