import Foundation
import IndexStoreInfra
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// Reports blocking waits that declined a deadline their own API offered.
///
/// ## What this checker claims, and what it does not
///
/// It claims exactly one thing: **the vendor provided a bounded overload and this call site did
/// not use it.** That is decidable from the overload set, so a finding is never a matter of
/// opinion.
///
/// It does **not** claim the code cannot hang. Whether a wait is genuinely bounded depends on
/// subprocess lifetime, signal delivery, descriptor inheritance, thread scheduling and whether a
/// timeout handler is even reachable after the wait — none of which a syntactic pass can decide.
/// Primitives with no bounded form at all are the separate concern of `bounded-io`, which
/// confines them to an audited kernel rather than reasoning about them.
///
/// ## Rules
///
/// - **liveness.unbounded-wait**: a blocking primitive called with no deadline when its API
///   offers one. The repair is local and forces a real decision — what should happen when the
///   deadline fires — which is the point rather than a side effect.
///
/// ## Provenance
///
/// Written after `process-safety` missed two of the three deadlocks in the file it was created to
/// protect. It missed them partly by matching one syntactic shape, and partly by being scoped to
/// a *subsystem* rather than a *hazard*: the first two findings of this checker are semaphore
/// waits in a TUI, with no subprocess anywhere near them.
public struct LivenessAuditor: QualityChecker, Sendable {
    /// Unique identifier for this checker.
    public let id = "liveness"
    /// Human-readable display name.
    public let name = "Liveness Auditor"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Blocking waits that declined an available deadline"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.correctness

    /// What this checker's findings are about — see `CheckerKind`.
    ///
    /// `code`, not `convention`: declining an offered bound is a defect in any codebase, so this
    /// is meaningful when pointed at a stranger's package. Its sibling `bounded-io` is
    /// `convention`, because "route it through our kernel" is a house rule and says nothing about
    /// a repository that has no kernel.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Creates a new liveness auditor.
    public init() {}

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

    /// Scans every Swift file under the project root.
    ///
    /// Walks from the project root via `SourceWalker` rather than a hardcoded `Sources/`, so
    /// `Tests/`, `Plugins/` and any other directory are covered — a wait with no deadline hangs a
    /// test suite exactly as thoroughly as it hangs the tool.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let started = ContinuousClock.now
        let root = configuration.resolvedProjectRoot
        let scan = SourceWalker.walk(under: root, excludePatterns: configuration.excludePatterns)
        let files = scan.files

        var diagnostics: [Diagnostic] = []
        var examined = 0
        var skipped = 0

        for path in files {
            // silent: an unreadable file is skipped, not counted clean; the walker reports it.
            guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }
            let scan = Self.scan(source: source, fileName: path)
            diagnostics.append(contentsOf: scan.diagnostics)
            examined += scan.examined
            skipped += scan.skipped
        }

        // Emitted on every run, pass or fail, including when the answer is zero — a silent pass
        // from this checker's predecessor was read as a guarantee it never made.
        let coverage = LivenessScan(diagnostics: [], examined: examined, skipped: skipped)
        // The exclusion clause appears only when something was left out, so a reduced scope
        // reads as a statement rather than as boilerplate nobody scans.
        let scope = scan.exclusionClause.map { " · \($0)" } ?? ""
        diagnostics.append(Diagnostic(
            severity: .note,
            message: coverage.coverageLine + " across \(files.count) files" + scope,
            ruleId: "liveness.coverage"))

        let failed = diagnostics.contains { $0.severity == .error }
        return CheckResult(
            checkerId: id,
            status: failed ? .failed : .passed,
            diagnostics: diagnostics,
            duration: ContinuousClock.now - started)
    }

    /// Scans one file's source. Exposed for tests, which drive this checker case by case.
    static func scan(source: String, fileName: String) -> LivenessScan {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let visitor = LivenessVisitor(fileName: fileName, converter: converter)
        visitor.walk(tree)
        return LivenessScan(
            diagnostics: visitor.diagnostics,
            examined: visitor.examined,
            skipped: visitor.skipped)
    }
}
