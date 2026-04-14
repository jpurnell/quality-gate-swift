import Foundation
import QualityGateCore
import SwiftSyntax
import SwiftParser

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
/// let auditor = UnreachableCodeAuditor()
/// let result = try await auditor.check(configuration: config)
/// ```
public struct UnreachableCodeAuditor: QualityChecker, Sendable {

    /// Unique identifier for this checker.
    public let id = "unreachable"

    /// Human-readable name for display.
    public let name = "Unreachable Code Auditor"

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
    ///   `~/Library/Developer/Xcode/DerivedData/`. If the user hasn't
    ///   built recently a `.note` is emitted; the gate is never failed
    ///   purely on a missing or stale index. A separate `.note` is
    ///   emitted when the located store is older than the newest source.
    /// - **Plain** — cross-module is skipped with a `.note`; only the
    ///   syntactic pass runs.
    ///
    /// - Parameters:
    ///   - root: Absolute URL of the project root.
    ///   - configuration: Project configuration (excludes honored).
    /// - Returns: A combined `CheckResult`.
    public func audit(at root: URL, configuration: Configuration) async throws -> CheckResult {
        let start = ContinuousClock.now
        var diagnostics: [Diagnostic] = []

        let kind = ProjectKind.detect(at: root)

        // Syntactic pass — works regardless of project kind.
        let swiftFiles = SourceWalker.swiftFiles(
            under: kind.rootURL,
            excludePatterns: configuration.excludePatterns)
        for file in swiftFiles {
            guard let src = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            diagnostics.append(contentsOf: analyze(source: src, fileName: file))
        }

        // Cross-module pass.
        do {
            var located: IndexStoreManager.LocatedStore?
            located = try IndexStoreManager.locate(projectKind: kind)

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
            if located2.isStale {
                diagnostics.append(Diagnostic(
                    severity: .note,
                    message: "Index store at \(located2.url.path) is older than the newest source file — results may be out of date. Build the project in Xcode and re-run, or pass `--auto-build-xcode`.",
                    ruleId: "unreachable.cross_module.stale"
                ))
            }
            let dylib = try Self.locateLibIndexStore()
            let targetTypeByModule: [String: String]
            switch kind {
            case .swiftPM(let pkgRoot):
                targetTypeByModule = (try? Self.describeTargetTypes(packageRoot: pkgRoot)) ?? [:]
            case .xcode, .xcworkspace, .plain:
                targetTypeByModule = [:]   // synthesized via heuristic
            }
            let inputs = IndexStorePass.Inputs(
                rootURL: kind.rootURL,
                excludePatterns: configuration.excludePatterns,
                indexStorePath: located2.url,
                libIndexStoreDylib: dylib,
                targetTypeByModule: targetTypeByModule
            )
            diagnostics.append(contentsOf: try IndexStorePass.run(inputs: inputs))
        } catch SkipMarker.skipped {
            // Already added a .note above.
        } catch {
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

    /// Build the Xcode project / workspace via `xcodebuild` and return a
    /// freshly-located index store. Used by the v5 `--auto-build-xcode`
    /// opt-in path.
    private static func runXcodebuildAndRelocate(
        kind: ProjectKind,
        configuration: Configuration
    ) throws -> IndexStoreManager.LocatedStore {
        var options = IndexStoreManager.XcodebuildOptions.defaults(rootURL: kind.rootURL)
        if let s = configuration.xcodeScheme { options.scheme = s }
        if let d = configuration.xcodeDestination { options.destination = d }
        let store = try IndexStoreManager.runXcodebuild(projectKind: kind, options: options)
        return IndexStoreManager.LocatedStore(url: store, isStale: false)
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
        let proc = Process() // SAFETY: runs xcrun --find swift to locate the toolchain
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = ["--find", "swift"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw ToolchainError.libIndexStoreNotFound }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { throw ToolchainError.libIndexStoreNotFound }
        // /…/usr/bin/swift -> /…/usr/lib/libIndexStore.dylib
        let usr = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dylib = usr.appendingPathComponent("lib/libIndexStore.dylib")
        guard FileManager.default.fileExists(atPath: dylib.path) else {
            throw ToolchainError.libIndexStoreNotFound
        }
        return dylib
    }

    /// Returns a `module name → target type` map from `swift package
    /// describe --type json`. SwiftPM target names are also their module
    /// names, so this is a direct lookup for `IndexStorePass`.
    static func describeTargetTypes(packageRoot: URL) throws -> [String: String] {
        let proc = Process() // SAFETY: runs swift package describe to map target types
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["swift", "package", "--package-path", packageRoot.path, "describe", "--type", "json"]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0 else {
            let e = err.fileHandleForReading.readDataToEndOfFile()
            throw ToolchainError.describeFailed(String(data: e, encoding: .utf8) ?? "")
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
                    file: fileName,
                    line: loc.line,
                    column: loc.column,
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
                file: fileName,
                line: loc.line,
                column: loc.column,
                ruleId: "unreachable.dead_branch",
                suggestedFix: "Remove the dead branch."
            ))
        } else if let elseBody = node.elseBody {
            let loc = elseBody.startLocation(converter: converter)
            diagnostics.append(Diagnostic(
                severity: .error,
                message: "Unreachable branch: `else` after constant `true` condition.",
                file: fileName,
                line: loc.line,
                column: loc.column,
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
                file: fileName,
                line: loc.0,
                column: loc.1,
                ruleId: "unreachable.unused_private",
                suggestedFix: "Remove '\(name)' or make it internal/public if it is intended for use elsewhere."
            ))
        }
        return out
    }
}
