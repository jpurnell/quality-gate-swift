import Foundation
import IndexStoreInfra
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// Keeps unbounded blocking primitives inside one audited kernel.
///
/// ## What this checker claims
///
/// Only this: **an unbounded primitive was called outside the repository's kernel.** It never
/// claims the code cannot hang, and never claims the kernel is correct — the kernel was wrong for
/// three months, which is why this exists.
///
/// ## One file, per repository
///
/// The kernel is one file, and *which* file is a property of the repository being audited, set
/// with `boundedIO.kernelPath` and defaulting to this package's own
/// `Sources/QualityGateCore/ProcessRunner.swift`. It used to be that constant and nothing else,
/// which named a type only this package has: a foreign repository had every spawn site outside
/// the kernel by construction, and the emitted fix cited a symbol it could not import, so
/// **writing the correct fix did not clear the rule**. Declaring no kernel is still a finding
/// rather than an exemption — a repository with nine unbounded spawns and no kernel is the one
/// that most needs telling.
///
/// The distinction from `liveness` is the API, not the severity. There, a bounded overload exists
/// and the call site declined it, so the repair is local. Here no bounded form exists at all:
/// `readDataToEndOfFile()` returns at EOF or never, and EOF waits on every inherited write end
/// including a grandchild's. Such a call can only be bounded from outside, so the only checkable
/// property is *where it lives*.
///
/// ## Why a kernel at all
///
/// The deadline fix that prompted this landed on **one of nine sites**. There was no kernel for a
/// correct fix to propagate from, so fixing the shared runner fixed one caller and left eight.
/// Containment does not make the kernel right; it makes it the only place that has to be.
///
/// ## Rules
///
/// - **bounded-io.outside-kernel**: an unbounded primitive called outside the declared kernel.
/// - **bounded-io.process-construction**: a `Process()` or `NSTask()` built outside it. Absorbed
///   from `security.command-injection`, whose mechanism was exactly this check under a name that
///   described a different hazard — and which was disabled in config on injection grounds,
///   silently removing the only signal that pointed at every direct spawn in the tree.
///
/// A site may be acknowledged with `// Unbounded: <reason>` on the line immediately above. That
/// removes the error and counts the site into the coverage note instead — `TrapPolicy`'s
/// `aggregate` shape — so a deliberate, documented decision does not read as an unfixed defect
/// while the number stays in front of the reader on every run.
///
/// A bare marker with no reason does not qualify, and that is the load-bearing part. When the
/// justification cannot be written honestly, the inability to write it *is* the finding:
/// `PluginRunner` armed a watchdog that terminated the child and did not bound the read, and no
/// true sentence described it as bounded.
public struct BoundedIOAuditor: QualityChecker, Sendable {
    /// Unique identifier for this checker.
    public let id = "bounded-io"
    /// Human-readable display name.
    public let name = "Bounded IO Auditor"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Unbounded blocking primitives called outside the audited kernel"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.correctness

    /// What this checker's findings are about — see `CheckerKind`.
    ///
    /// `convention`, not `code`. "Route it through our kernel" is a house rule and says nothing
    /// about a repository that has no kernel, so this must stay silent during a `--profile code`
    /// survey of a stranger's package. Its sibling `liveness` is `code`, because declining an
    /// offered deadline is a defect anywhere.
    public let kind = CheckerKind.convention

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// The kernel this package uses when a repository declares none.
    ///
    /// Matched by path suffix so it holds under any checkout root. Deliberately a single file:
    /// the trust argument rests on the kernel being small enough to read in one sitting, and a
    /// list of "places where this is fine" is how that property is lost one entry at a time.
    ///
    /// The admission test for anything joining it: **does this primitive lack a bounded form?**
    /// If a bounded form exists the answer is the overload, not the kernel — which is why the
    /// semaphore waits `liveness` reports were fixed in place rather than moved here.
    ///
    /// This used to be *the* kernel path rather than the default one, and it names this
    /// package's own type. A foreign repository has no `QualityGateCore`, so every spawn site
    /// it owned was outside the kernel by construction and the emitted fix named a symbol it
    /// could not import — **writing the correct fix did not clear the rule.** Override with
    /// `boundedIO.kernelPath`. See `project/plans/proposals/BoundedIOKernelPath.md`.
    static let defaultKernelPath = "Sources/QualityGateCore/ProcessRunner.swift"

    /// The name a diagnostic should use for a kernel at `path` — its file's base name.
    ///
    /// A message that names a type the reader cannot import reads as a broken checker rather
    /// than as a finding, which is the failure this exists to avoid.
    static func kernelName(for path: String) -> String {
        (path as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
    }

    /// Creates a new bounded IO auditor.
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
    public func check(configuration: Configuration) async throws -> CheckResult {
        let started = ContinuousClock.now
        let root = configuration.resolvedProjectRoot
        let scan = SourceWalker.walk(under: root, excludePatterns: configuration.excludePatterns)

        var diagnostics: [Diagnostic] = []
        var sites = 0
        var acknowledged = 0
        for path in scan.files {
            // silent: an unreadable file is skipped, not counted clean; the walker reports it.
            guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let result = Self.scan(
                source: source, fileName: path, kernelPath: configuration.boundedIO.kernelPath)
            diagnostics.append(contentsOf: result.diagnostics)
            sites += result.sitesExamined
            acknowledged += result.acknowledged
        }

        // Printed pass or fail. A checker whose silence gets read as a guarantee is the failure
        // this whole family of rules exists to correct, so a pass states its own size.
        let scope = scan.exclusionClause.map { " · \($0)" } ?? ""
        diagnostics.append(Diagnostic(
            severity: .note,
            message: BoundedIOScan(
                diagnostics: [], sitesExamined: sites, acknowledged: acknowledged,
                kernelName: Self.kernelName(
                    for: configuration.boundedIO.kernelPath ?? Self.defaultKernelPath)).coverageLine
                + " across \(scan.files.count) files" + scope,
            ruleId: "bounded-io.coverage"))

        let failed = diagnostics.contains { $0.severity != .note }
        return CheckResult(
            checkerId: id,
            status: failed ? .failed : .passed,
            diagnostics: diagnostics,
            duration: ContinuousClock.now - started)
    }

    /// Scans one file's source. Exposed for tests, which drive this checker case by case.
    ///
    /// - Parameters:
    ///   - source: The Swift source to scan.
    ///   - fileName: The path used for the kernel test and in emitted diagnostics.
    ///   - kernelPath: The repository's declared kernel, or `nil` for ``defaultKernelPath``.
    ///   Defaulted to `nil` so the existing case-by-case tests, which exercise the default
    ///   kernel, keep reading as tests of *that* rather than restating it at every call.
    static func scan(source: String, fileName: String, kernelPath: String? = nil) -> BoundedIOScan {
        let resolvedKernel = kernelPath ?? defaultKernelPath
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let visitor = BoundedIOVisitor(
            fileName: fileName,
            converter: converter,
            sourceLines: source.lines,
            isKernel: fileName.hasSuffix(resolvedKernel),
            kernelName: kernelName(for: resolvedKernel))
        visitor.walk(tree)
        return BoundedIOScan(
            diagnostics: visitor.diagnostics,
            sitesExamined: visitor.sitesExamined,
            acknowledged: visitor.acknowledged,
            kernelName: kernelName(for: resolvedKernel))
    }
}
