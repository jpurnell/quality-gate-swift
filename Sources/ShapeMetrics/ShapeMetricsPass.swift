import Foundation
import ComplexityAnalyzer
import QualityGateCore

/// The shape snapshot as it is written to disk and, later, to the corpus.
///
/// Carries the ratios, every component, and the coverage note — never the headline alone. A
/// bare `verbosity: 0.31` cannot be acted on: it does not say whether the cause was clones or
/// idioms, nor whether every contributing checker actually ran.
public struct ShapeSnapshot: Sendable, Equatable, Codable {
    /// Schema version, so a corpus reader can tell what it is looking at.
    public let schema: Int
    /// The package this describes.
    public let projectID: String
    /// Both ratios, their components, and what was measured.
    public let report: ShapeReport

    /// The current schema version.
    public static let currentSchema = 1

    /// Creates a snapshot.
    public init(projectID: String, report: ShapeReport, schema: Int = ShapeSnapshot.currentSchema) {
        self.schema = schema
        self.projectID = projectID
        self.report = report
    }
}

/// Runs the shape metrics over a completed gate run.
///
/// A post-pass rather than a checker, for the reason recorded on ``ShapeMetrics``: it needs the
/// union of line sets from three checkers that cannot see each other. It emits no diagnostic and
/// changes no verdict — calling it cannot make a run fail.
public enum ShapeMetricsPass {

    /// Computes a snapshot from a finished run.
    ///
    /// - Parameters:
    ///   - results: Every checker result from the run, in any order.
    ///   - projectRoot: The package root whose `Sources/` supplies the denominator.
    ///   - projectID: Identifier recorded on the snapshot.
    ///   - threshold: Cyclomatic threshold above which a function erodes.
    ///   - config: Which rules count as size claims.
    /// - Returns: The snapshot, or `nil` when there is no Swift source to measure.
    public static func run(
        results: [CheckResult],
        projectRoot: URL,
        projectID: String,
        threshold: Int = 10,
        config: ShapeConfig = ShapeConfig()
    ) -> ShapeSnapshot? {
        let ran = Set(results.map(\.checkerId))
        let missing = ShapeMetrics.contributingCheckers.filter { !ran.contains($0) }

        var regions: [FlaggedRegion] = []
        var rulesWithoutSpan: Set<String> = []
        for result in results where ShapeMetrics.contributingCheckers.contains(result.checkerId) {
            let extracted = FlaggedRegion.extract(from: result.diagnostics)
            regions.append(contentsOf: extracted.regions)
            rulesWithoutSpan.formUnion(extracted.rulesWithoutSpan)
        }

        let scan = scanSources(under: projectRoot)
        // Nothing to divide by and nothing to weigh: there is no shape here, which is not the
        // same as a shape of zero.
        guard !scan.sloc.isEmpty else { return nil }

        let report = ShapeMetrics.compute(
            regions: regions,
            sloc: scan.sloc,
            functions: scan.functions,
            missingCheckers: missing,
            rulesWithoutSpan: Array(rulesWithoutSpan),
            threshold: threshold,
            config: config
        )
        return ShapeSnapshot(projectID: projectID, report: report)
    }

    /// Writes a snapshot as JSON.
    ///
    /// Keys are sorted so two runs over an unchanged tree produce byte-identical files. An
    /// unsorted encoder emits a different byte order per process, which would make the
    /// determinism this metric depends on unobservable.
    ///
    /// - Parameters:
    ///   - snapshot: The snapshot to write.
    ///   - path: Destination path; parent directories are created.
    /// - Throws: Whatever encoding or writing throws.
    public static func write(_ snapshot: ShapeSnapshot, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    // MARK: - Scanning

    /// Source-line profiles and function records for every Swift file under `Sources/`.
    ///
    /// `Tests/` is excluded, and not by accident: test code has legitimately different
    /// duplication norms, and folding it into the denominator would let a package dilute its
    /// ratio by writing more tests. The project has a dedicated instrument for judging tests.
    static func scanSources(
        under projectRoot: URL
    ) -> (sloc: [String: SLOCProfile], functions: [FunctionComplexityRecord]) {
        let sourcesRoot = projectRoot.appendingPathComponent("Sources")
        var sloc: [String: SLOCProfile] = [:]
        var functions: [FunctionComplexityRecord] = []
        let analyzer = ComplexityAnalyzer()

        for path in swiftFiles(under: sourcesRoot) {
            guard let source = SourceFileReader.read(path, checker: "shape") else { continue }
            sloc[path] = SLOCProfile.profile(source: source)
            functions.append(contentsOf: analyzer.analyzeSource(
                source,
                filePath: path,
                moduleName: moduleName(of: path, under: sourcesRoot.path)
            ))
        }
        return (sloc, functions)
    }

    /// Every `.swift` file under `root`, sorted so a run's output does not depend on the order
    /// the file system happened to enumerate in.
    static func swiftFiles(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var files: [String] = []
        while let relative = enumerator.nextObject() as? String {
            guard relative.hasSuffix(".swift") else { continue }
            files.append(root.appendingPathComponent(relative).path)
        }
        return files.sorted()
    }

    /// The module a file belongs to: the first path component under `Sources/`.
    ///
    /// Containment is decided on whole path components, with symbolic links resolved, not on a
    /// string prefix. `hasPrefix` answered yes for `/base-evil` against `/base`, and the gate's
    /// own `security.path-prefix` rule (CWE-22) said so the first time this branch met a `main`
    /// that carried the rule. A sibling sharing a prefix is the cheap case; the one that matters
    /// is that a prefix test cannot see a link leading out of the tree, so a path that merely
    /// reads as inside it is treated as inside it.
    ///
    /// Comparing components also removes the slash arithmetic the prefix version needed — a
    /// `dropFirst(sourcesRoot.count)` followed by trimming `/` to undo whether the root was
    /// written with a trailing separator.
    static func moduleName(of path: String, under sourcesRoot: String) -> String {
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().pathComponents
        let root = URL(fileURLWithPath: sourcesRoot).resolvingSymlinksInPath().pathComponents
        guard file.starts(with: root), file.count > root.count else { return "?" }
        return file[root.count]
    }
}
