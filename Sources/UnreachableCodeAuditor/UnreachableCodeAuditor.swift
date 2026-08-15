import Foundation
import IndexStoreInfra
#if canImport(os)
import os
#endif
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// Scans Swift source files for syntactically unreachable code.
///
/// Detects three classes of dead code (intra-file, syntactic only):
/// - Statements following an unconditional terminator (`return`, `throw`,
///   `break`, `continue`, `fatalError`, `preconditionFailure`).
/// - Branches of constant conditions (`if false { … }`, `if true { … } else { … }`).
/// - Private / fileprivate symbols never referenced in the same file.
///
/// Cross-module dead-code analysis (public symbols, protocol witnesses) is
/// out of scope for v1 — it requires IndexStore.
///
/// ## Usage
/// ```swift
/// import QualityGateCore
///
/// let config = Configuration()
/// let auditor = UnreachableCodeAuditor()
/// let result = try await auditor.check(configuration: config)
/// ```
public struct UnreachableCodeAuditor: QualityChecker, Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "UnreachableCodeAuditor")

    /// Unique identifier for this checker.
    ///
    /// The literal must stay *here*, on the declaration: `doc-generated` derives the README's
    /// checker tables by reading this initializer, and an indirection through a constant left
    /// it unable to find the declaration for a checker its registry lists — six regions failed
    /// to regenerate rather than silently dropping a row, which is the checker working.
    public let id = "unreachable"

    /// The same id at type level, for the static diagnostic builders. Derived from an instance
    /// rather than a second literal so the two cannot drift.
    static let checkerId = UnreachableCodeAuditor().id

    /// Human-readable name for display.
    public let name = "Unreachable Code Auditor"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Dead code via SwiftSyntax + IndexStore cross-reference"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.correctness

    /// Cross-module dead-code analysis depends on the whole source tree, so the result is
    /// cacheable keyed by all Swift sources + manifests + config.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        SourceCacheInputs.wholeSource(
            projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            configuration: configuration
        )
    }

    /// Creates a new auditor.
    public init() {}

    /// Run the audit against `Sources/` in the current working directory.
    ///
    /// - Parameter configuration: Project configuration (excludes are honored).
    /// - Returns: A `CheckResult` with one diagnostic per finding.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return try await audit(at: cwd, configuration: configuration)
    }

    /// Audit any Swift codebase rooted at `root`.
    ///
    /// Detects the project kind (SwiftPM / Xcode / plain) and dispatches
    /// the cross-module pass accordingly. The syntactic pass always runs
    /// over every `.swift` file under `root` (recursive, with the standard
    /// build / dependency / Xcode-container skip list applied).
    ///
    /// Cross-module behavior by project kind:
    /// - **SwiftPM** — auto-builds an isolated index store under
    ///   `.build/index-build` and runs the full reachability pass.
    /// - **Xcode** — looks up an existing index store under
    ///   `~/Library/Developer/Xcode/DerivedData/`. A *missing* store is still
    ///   a `.note`: nothing was found, and nothing is claimed.
    /// - **Plain** — cross-module is skipped with a `.note`; only the
    ///   syntactic pass runs.
    ///
    /// A **stale or undateable** index is different, and no longer a note. The cross-module
    /// pass does not run and an error-severity barrier replaces the findings it would have
    /// produced — see `indexProvenance(located:)`. This reverses the previous contract, under
    /// which the gate was never failed on a stale index: an advisory line is something a
    /// reader scrolls past, and the reader who scrolls past it acts on findings computed
    /// against a program that no longer exists.
    ///
    /// The syntactic pass is unaffected in every case, because it reads the sources directly.
    ///
    /// - Parameters:
    ///   - root: Absolute URL of the project root.
    ///   - configuration: Project configuration (excludes honored).
    /// - Returns: A combined `CheckResult`.
    public func audit(at root: URL, configuration: Configuration) async throws -> CheckResult {
        let start = ContinuousClock.now
        var diagnostics: [Diagnostic] = []

        let kind = ProjectKind.detect(at: root)

        // Vendored third-party trees the project does not own are excluded from
        // both passes: `vendorPaths` entries are treated as additional excludes
        // so declaring code as vendored keeps it out of every unreachable finding.
        let effectiveExcludes = configuration.excludePatterns + configuration.vendorPaths

        // Syntactic pass — works regardless of project kind.
        let swiftFiles = SourceWalker.swiftFiles(
            under: kind.rootURL,
            excludePatterns: effectiveExcludes)
        for file in swiftFiles {
            let src: String
            do {
                src = try String(contentsOfFile: file, encoding: .utf8)
            } catch {
                Self.logger.warning("Skipping unreadable source file \(file, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            diagnostics.append(contentsOf: analyze(source: src, fileName: file))
        }

        // Cross-module pass.
        do {
            var located: StoreLocator.LocatedStore?
            located = try StoreLocator.locate(projectKind: kind, excludePatterns: effectiveExcludes)

            // v5: optional auto-build for Xcode projects/workspaces.
            if (located == nil || located?.isStale == true)
                && configuration.unreachableAutoBuildXcode {
                if case .xcode = kind {
                    located = try Self.runXcodebuildAndRelocate(kind: kind, configuration: configuration)
                } else if case .xcworkspace = kind {
                    located = try Self.runXcodebuildAndRelocate(kind: kind, configuration: configuration)
                }
            }

            guard let storeInfo = located else {
                diagnostics.append(Diagnostic(
                    severity: .note,
                    message: "Cross-module pass skipped: no index store available. (For Xcode projects, build in Xcode first or set `unreachableAutoBuildXcode: true`.)",
                    ruleId: "unreachable.cross_module.skipped"
                ))
                throw SkipMarker.skipped
            }
            let located2 = storeInfo
            // A stale index reports symbols at their old line numbers; once source
            // above them shifts (e.g. an added `#if canImport` guard), those lines
            // no longer line up with the current file — `// LIVE:` markers are missed
            // and live symbols look dead. The barrier replaces the cross-module findings
            // rather than accompanying them; the syntactic pass has already run and is
            // unaffected, because it reads the sources directly.
            //
            // This was a `.note` that let the run pass. A note is advice, and the reader
            // who scrolls past it is the reader who deletes live public API on a stale
            // index's authority — which is what all but happened.
            let provenance = Self.indexProvenance(located: located2)
            diagnostics.append(contentsOf: provenance.diagnostics)
            guard provenance.shouldRun else { throw SkipMarker.skipped }
            let dylib = try Self.locateLibIndexStore()
            let targetTypeByModule: [String: String]
            switch kind {
            case .swiftPM(let pkgRoot):
                do {
                    targetTypeByModule = try Self.describeTargetTypes(packageRoot: pkgRoot)
                } catch {
                    Self.logger.warning("SPM describe failed, falling back to empty type map: \(error.localizedDescription, privacy: .public)")
                    targetTypeByModule = [:]
                }
            case .xcode, .xcworkspace, .plain:
                targetTypeByModule = [:]   // synthesized via heuristic
            }
            let inputs = IndexStorePass.Inputs(
                rootURL: kind.rootURL,
                excludePatterns: effectiveExcludes,
                indexStorePath: located2.url,
                libIndexStoreDylib: dylib,
                targetTypeByModule: targetTypeByModule
            )
            diagnostics.append(contentsOf: try IndexStorePass.run(inputs: inputs))
        } catch SkipMarker.skipped {
            Self.logger.info("Cross-module pass skipped: no index store available")
        } catch {
            Self.logger.warning("Cross-module pass failed: \(error.localizedDescription, privacy: .public)")
            diagnostics.append(Diagnostic(
                severity: .note,
                message: "Cross-module pass skipped: \(error.localizedDescription)",
                ruleId: "unreachable.cross_module.skipped"
            ))
        }

        let duration = ContinuousClock.now - start
        let hasError = diagnostics.contains { $0.severity == .error }
        return CheckResult(
            checkerId: id,
            status: hasError ? .failed : .passed,
            diagnostics: diagnostics,
            duration: duration
        )
    }

    private enum SkipMarker: Error { case skipped }

    /// Whether the cross-module (index-backed) pass should run for a located store.
    ///
    /// A `nil` store means none was found; a stale store's recorded line numbers may
    /// have drifted from the current source, making its reachability findings — and
    /// the `// LIVE:` line matching that guards them — unreliable. In both cases the
    /// cross-module pass is skipped so the gate never fails on data it can't trust.
    ///
    /// - Parameter located: The located index store, or `nil`.
    /// - Returns: `true` only when a fresh store is present.
    static func shouldRunCrossModule(located: StoreLocator.LocatedStore?) -> Bool {
        guard let located else { return false }
        return !located.isStale
    }

    /// What to say about the index before reading it, and whether to read it at all.
    ///
    /// The barrier **replaces** the cross-module findings rather than accompanying them.
    /// Emitting both invites the reader to act on the findings and treat the barrier as
    /// noise, which is precisely what would have happened in the case that produced this
    /// rule: three plausible dead symbols and one advisory line about timestamps.
    ///
    /// - Parameter located: The located store, carrying its measurement when it has one.
    /// - Returns: The diagnostics to emit, and whether the index may be read.
    static func indexProvenance(
        located: StoreLocator.LocatedStore
    ) -> (diagnostics: [Diagnostic], shouldRun: Bool) {
        guard let measurement = located.measurement else {
            // An asserted store from the legacy initializer: nothing was measured, so there is
            // nothing to report. Preserves the behavior of callers that have not adopted the
            // measured path.
            return ([], !located.isStale)
        }

        switch measurement {
        case .measured(let freshness) where freshness.isStale:
            return ([freshness.staleBarrier(
                checkerId: checkerId,
                subject: "reachability",
                storeURL: located.url
            )], false)

        case .measured(let freshness):
            return ([freshness.coverageNote(checkerId: checkerId)], true)

        case .noIndexUnits:
            // Worse than stale, and a different sentence. An index holding no units yields no
            // references, so *every* symbol in the package reads as unreachable — the largest
            // false-positive surface this checker has. It cannot be reported as staleness
            // because the timestamps that sentence would quote do not exist.
            return ([Diagnostic(
                severity: .error,
                message: """
                    The index store at \(located.url.path) holds no unit records, so \
                    reachability could not be determined. Read as-is it would report every \
                    symbol in the package as unreachable.
                    """,
                ruleId: "\(checkerId).index.unmeasurable",
                suggestedFix: """
                    Build the project — `swift build` — and re-run. If the store is being \
                    written to a path this checker does not read, that is a configuration \
                    fault rather than a missing build.
                    """
            )], false)

        case .noSources:
            // Nothing to be stale against; there is no reachability question to answer.
            return ([], false)
        }
    }

    /// Build the Xcode project / workspace via `xcodebuild` and return a
    /// freshly-located index store. Used by the v5 `--auto-build-xcode`
    /// opt-in path.
    private static func runXcodebuildAndRelocate(
        kind: ProjectKind,
        configuration: Configuration
    ) throws -> StoreLocator.LocatedStore {
        var options = StoreLocator.XcodebuildOptions.defaults(rootURL: kind.rootURL)
        if let s = configuration.xcodeScheme { options.scheme = s }
        if let d = configuration.xcodeDestination { options.destination = d }
        let store = try StoreLocator.runXcodebuild(projectKind: kind, options: options)
        return StoreLocator.LocatedStore(url: store, isStale: false)
    }

    /// Backwards-compatible alias for the v3 entry point. Prefer `audit(at:)`.
    public func auditPackage(at root: URL, configuration: Configuration) async throws -> CheckResult {
        try await audit(at: root, configuration: configuration)
    }

    /// Audit a single in-memory source string.
    ///
    /// - Parameters:
    ///   - source: The Swift source to analyze.
    ///   - fileName: A label used in diagnostics.
    ///   - configuration: Project configuration (currently unused for in-memory audits).
    /// - Returns: A `CheckResult` with the findings.
    public func auditSource(
        _ source: String,
        fileName: String,
        configuration: Configuration
    ) async throws -> CheckResult {
        let start = ContinuousClock.now
        let diagnostics = analyze(source: source, fileName: fileName)
        let duration = ContinuousClock.now - start
        return CheckResult(
            checkerId: id,
            status: diagnostics.isEmpty ? .passed : .failed,
            diagnostics: diagnostics,
            duration: duration
        )
    }

    // MARK: - Toolchain helpers

    enum ToolchainError: LocalizedError {
        case libIndexStoreNotFound
        case describeFailed(String)
        var errorDescription: String? {
            switch self {
            case .libIndexStoreNotFound:
                return "Could not locate libIndexStore.dylib via xcrun."
            case .describeFailed(let msg):
                return "swift package describe failed: \(msg)"
            }
        }
    }

    static func locateLibIndexStore() throws -> URL {
        // `xcrun --find swift` → /…/usr/bin/swift
        // libIndexStore lives at        /…/usr/lib/libIndexStore.dylib
        // SAFETY: runs xcrun --find swift to locate the toolchain
        let result = try ProcessRunner.run(
            "/usr/bin/xcrun",
            arguments: ["--find", "swift"]
        )
        guard result.exitCode == 0 else { throw ToolchainError.libIndexStoreNotFound }
        let path = result.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw ToolchainError.libIndexStoreNotFound }
        // /…/usr/bin/swift -> /…/usr/lib/libIndexStore.dylib
        let usr = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dylib = usr.appendingPathComponent("lib/libIndexStore.dylib")
        guard FileManager.default.fileExists(atPath: dylib.path) else { // SAFETY: CLI tool checks local toolchain library
            throw ToolchainError.libIndexStoreNotFound
        }
        return dylib
    }

    /// Returns a `module name → target type` map from `swift package
    /// describe --type json`. SwiftPM target names are also their module
    /// names, so this is a direct lookup for `IndexStorePass`.
    static func describeTargetTypes(packageRoot: URL) throws -> [String: String] {
        // SAFETY: runs swift package describe to map target types
        let result = try ProcessRunner.run(
            "/usr/bin/env",
            arguments: ["swift", "package", "--package-path", packageRoot.path, "describe", "--type", "json"]
        )
        guard result.exitCode == 0 else {
            throw ToolchainError.describeFailed(result.stderr)
        }
        guard let data = result.stdout.data(using: .utf8) else {
            throw ToolchainError.describeFailed("non-UTF-8 output from swift package describe")
        }
        struct Described: Decodable {
            struct Target: Decodable { let name: String; let type: String }
            let targets: [Target]
        }
        let described = try JSONDecoder().decode(Described.self, from: data)
        return Dictionary(uniqueKeysWithValues: described.targets.map { ($0.name, $0.type) })
    }

    // MARK: - Private

    private func analyze(source: String, fileName: String) -> [Diagnostic] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)

        let visitor = UnreachableVisitor(fileName: fileName, converter: converter)
        visitor.walk(tree)

        var diagnostics = visitor.diagnostics
        diagnostics.append(contentsOf: visitor.unusedPrivateDiagnostics())
        return diagnostics
    }
}

// MARK: - Visitor

private final class UnreachableVisitor: SyntaxVisitor {
    let fileName: String
    let converter: SourceLocationConverter
    var diagnostics: [Diagnostic] = []

    /// Declared private/fileprivate symbol name -> (line, column) of declaration.
    private var privateDecls: [String: (Int, Int)] = [:]
    /// Names referenced anywhere in the file.
    private var references: Set<String> = []

    init(fileName: String, converter: SourceLocationConverter) {
        self.fileName = fileName
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: Post-terminator

    override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
        let items = Array(node)
        for (index, item) in items.enumerated() where index < items.count - 1 {
            if isTerminator(item.item) {
                let next = items[index + 1]
                let loc = next.startLocation(converter: converter)
                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: "Unreachable code after terminator statement.",
                    filePath: fileName,
                    lineNumber: loc.line,
                    columnNumber: loc.column,
                    ruleId: "unreachable.after_terminator",
                    suggestedFix: "Remove the unreachable statements or restructure the control flow."
                ))
                break
            }
        }
        return .visitChildren
    }

    private func isTerminator(_ item: CodeBlockItemSyntax.Item) -> Bool {
        switch item {
        case .stmt(let stmt):
            if stmt.is(ReturnStmtSyntax.self) { return true }
            if stmt.is(ThrowStmtSyntax.self) { return true }
            if stmt.is(BreakStmtSyntax.self) { return true }
            if stmt.is(ContinueStmtSyntax.self) { return true }
            if let expr = stmt.as(ExpressionStmtSyntax.self) {
                return isNeverReturningCall(expr.expression)
            }
            return false
        case .expr(let expr):
            return isNeverReturningCall(expr)
        default:
            return false
        }
    }

    private func isNeverReturningCall(_ expr: ExprSyntax) -> Bool {
        guard let call = expr.as(FunctionCallExprSyntax.self),
              let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) else {
            return false
        }
        switch ref.baseName.text {
        case "fatalError", "preconditionFailure":
            return true
        default:
            return false
        }
    }

    // MARK: Constant condition

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        guard let first = node.conditions.first?.condition,
              let lit = first.as(BooleanLiteralExprSyntax.self) else {
            return .visitChildren
        }
        let isTrue = lit.literal.tokenKind == .keyword(.true)
        if !isTrue {
            // entire then-branch is dead
            let loc = node.body.startLocation(converter: converter)
            diagnostics.append(Diagnostic(
                severity: .error,
                message: "Unreachable branch: condition is constant `false`.",
                filePath: fileName,
                lineNumber: loc.line,
                columnNumber: loc.column,
                ruleId: "unreachable.dead_branch",
                suggestedFix: "Remove the dead branch."
            ))
        } else if let elseBody = node.elseBody {
            let loc = elseBody.startLocation(converter: converter)
            diagnostics.append(Diagnostic(
                severity: .error,
                message: "Unreachable branch: `else` after constant `true` condition.",
                filePath: fileName,
                lineNumber: loc.line,
                columnNumber: loc.column,
                ruleId: "unreachable.dead_branch",
                suggestedFix: "Remove the dead else branch."
            ))
        }
        return .visitChildren
    }

    // MARK: Unused private symbols

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if hasPrivateModifier(node.modifiers) {
            let loc = node.name.startLocation(converter: converter)
            privateDecls[node.name.text] = (loc.line, loc.column)
        }
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        references.insert(node.baseName.text)
        return .visitChildren
    }

    private func hasPrivateModifier(_ modifiers: DeclModifierListSyntax) -> Bool {
        for m in modifiers {
            let kind = m.name.tokenKind
            if kind == .keyword(.private) || kind == .keyword(.fileprivate) {
                return true
            }
        }
        return false
    }

    func unusedPrivateDiagnostics() -> [Diagnostic] {
        var out: [Diagnostic] = []
        for (name, loc) in privateDecls where !references.contains(name) {
            out.append(Diagnostic(
                severity: .warning,
                message: "Private symbol '\(name)' is never referenced in this file.",
                filePath: fileName,
                lineNumber: loc.0,
                columnNumber: loc.1,
                ruleId: "unreachable.unused_private",
                suggestedFix: "Remove '\(name)' or make it internal/public if it is intended for use elsewhere."
            ))
        }
        return out
    }
}
