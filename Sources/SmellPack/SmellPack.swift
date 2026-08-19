import Foundation
import IndexStoreInfra
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// Advisory code-smell metric suite (Phase 4c §4) — the generalist checkbox.
///
/// Cheap SwiftSyntax metrics over every Swift source under `Sources/` and
/// `Tests/`: parameter count, statement nesting depth, god-object member
/// count (same-file extensions included), type body length, and closure body
/// length. Thresholds are tunable via ``SmellConfig``.
///
/// Advisory posture, matching the ComplexityAnalyzer/LegibilityAnalyzer
/// precedent: every finding is a `.note` and the status is always `.passed` —
/// smells inform, they never gate. The `// smell:exempt` escape hatch on the
/// flagged declaration's line is recorded as a ``DiagnosticOverride``, never
/// silently dropped.
public struct SmellPack: QualityChecker, Sendable {

    /// The checker identifier.
    public let id = "smells"
    /// The human-readable name.
    public let name = "Smell Pack"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Structural smells in declarations: long parameter lists, feature envy, primitive obsession; `// smell:exempt` is recorded (advisory)"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.codeHygiene

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Analyses source without running it — safe to point at a stranger's package.
    public let executesProjectCode = false
    /// Thresholds for every metric.
    let config: SmellConfig
    /// Package root to scan; nil means the current working directory.
    let root: String?

    /// Creates the checker.
    ///
    /// - Parameters:
    ///   - config: Metric thresholds (defaults documented on ``SmellConfig``).
    ///   - root: Package root to scan (defaults to the working directory;
    ///     injectable for tests).
    public init(config: SmellConfig = SmellConfig(), root: String? = nil) {
        self.config = config
        self.root = root
    }

    /// Declares this checker cacheable on the source tree it reads.
    ///
    /// Syntactic analysis over the sources, with no clock, corpus, network or out-of-tree path
    /// among its inputs — so the same tree under the same gate binary yields the same verdict.
    /// `gateIdentityHash` folds in the binary's identity and the toolchain, so a rebuild or a
    /// compiler change invalidates every entry.
    ///
    /// `wholeSourceAndDocs` rather than `wholeSource`: it is the wider set, and over-including
    /// an input costs a cache miss while under-including one serves a stale pass.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        SourceCacheInputs.wholeSourceAndDocs(
            projectRoot: configuration.resolvedProjectRoot,
            configuration: configuration
        )
    }

    /// Runs every metric over the project's Swift sources.
    ///
    /// Always returns `.passed`: the suite is advisory by contract, whatever
    /// it finds.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let scanRoot = root ?? configuration.resolvedProjectRoot.path

        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []
        for file in Self.swiftFiles(under: scanRoot) {
            // silent: an unreadable file is simply not measured by an advisory metric
            guard let source = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            let findings = Self.analyze(source: source, filePath: file, config: config)
            diagnostics.append(contentsOf: findings.diagnostics)
            overrides.append(contentsOf: findings.overrides)
        }

        return CheckResult(
            checkerId: id,
            status: .passed,
            diagnostics: diagnostics,
            overrides: overrides,
            duration: ContinuousClock.now - startTime)
    }

    // MARK: - Engine (pure over its inputs; internal for tests)

    /// All metrics over one source file: parse once, walk once, then settle
    /// the per-file god-object tallies. Findings come back in line order.
    static func analyze(
        source: String,
        filePath: String,
        config: SmellConfig
    ) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        let tree = Parser.parse(source: source)
        let visitor = SmellVisitor(config: config, filePath: filePath, source: source, tree: tree)
        visitor.walk(tree)
        visitor.finalizeGodObjects()
        let sorted = visitor.findings.sorted { lhs, rhs in
            let leftLine = lhs.lineNumber ?? 0
            let rightLine = rhs.lineNumber ?? 0
            if leftLine != rightLine { return leftLine < rightLine }
            return (lhs.ruleId ?? "") < (rhs.ruleId ?? "")
        }
        return (sorted, visitor.overrides)
    }

    /// Every `.swift` file under `Sources/` and `Tests/`, sorted for
    /// deterministic finding order.
    static func swiftFiles(under root: String) -> [String] {
        var files: [String] = []
        for dir in ["Sources", "Tests"] {
            let base = (root as NSString).appendingPathComponent(dir)
            guard let enumerator = FileManager.default.enumerator(atPath: base) else { continue }
            while let relative = enumerator.nextObject() as? String {
                guard relative.hasSuffix(".swift") else { continue }
                files.append((base as NSString).appendingPathComponent(relative))
            }
        }
        return files.sorted()
    }
}
