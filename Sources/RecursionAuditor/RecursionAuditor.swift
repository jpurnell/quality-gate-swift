import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore
import SwiftSyntax
import SwiftParser
import IndexStoreInfra

/// Scans Swift source files for infinite-recursion bugs that compile cleanly.
///
/// See the design proposal at
/// `development-guidelines/02_IMPLEMENTATION_PLANS/UPCOMING/RECURSION_AUDITOR_design.md`
/// for the full rule list and rationale.
public struct RecursionAuditor: QualityChecker, Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "RecursionAuditor")

    /// Unique identifier for this checker.
    public let id = "recursion"
    /// Human-readable name shown in quality-gate output.
    public let name = "Recursion Auditor"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Self-forwarding inits, computed property cycles, mutual recursion via USR call-graph analysis"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.correctness

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Analyses source without running it — safe to point at a stranger's package.
    public let executesProjectCode = false
    /// Cross-module recursion analysis depends on the whole source tree, so the result is
    /// cacheable keyed by all Swift sources + manifests + config.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        SourceCacheInputs.wholeSourceAndIndex(
            projectRoot: configuration.resolvedProjectRoot,
            configuration: configuration
        )
    }

    /// Creates a new recursion auditor.
    public init() {}

    /// Scans all Swift files under `Sources/` for infinite-recursion patterns.
    /// - Parameter configuration: The quality-gate configuration for this run.
    /// - Returns: A check result containing any recursion diagnostics found.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let root = configuration.resolvedProjectRoot
        // The walk was a hardcoded `Sources/` under the resolved root, so unguarded recursion
        // in `Plugins/`, in `Tests/`, or at the package root was never examined — and a test
        // that recurses without a base case hangs a suite exactly as thoroughly as it hangs a
        // tool. `SourceWalker` also brings the exclusions the private enumerator ignored.
        let scan = SourceWalker.walk(under: root, excludePatterns: configuration.excludePatterns)

        var sources: [(fileName: String, source: String)] = []
        for fullPath in scan.files {
            do {
                let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                sources.append((fullPath, source))
            } catch {
                Self.logger.warning("Skipping unreadable source file: \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        let result = try await auditProject(sources: sources, configuration: configuration)
        let duration = ContinuousClock.now - startTime
        return CheckResult(
            checkerId: id,
            status: result.status,
            diagnostics: result.diagnostics,
            duration: duration
        )
    }

    /// Single-file audit. Cycle detection considers only the one file.
    public func auditSource(
        _ source: String,
        fileName: String,
        configuration: Configuration
    ) async throws -> CheckResult {
        try await auditProject(sources: [(fileName, source)], configuration: configuration)
    }

    /// Multi-file audit. Builds a project-wide call graph for cross-file
    /// mutual recursion detection. When an IndexStoreDB session is available
    /// and `configuration.recursion.useIndexStore` is true, Pass 2 (USR-based
    /// cycle detection) runs after the syntactic Pass 1, confirming or
    /// rejecting name-based mutual-cycle findings and detecting cross-module
    /// and protocol-witness cycles.
    public func auditProject(
        sources: [(fileName: String, source: String)],
        configuration: Configuration
    ) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        // Pre-pass: collect protocol names across the entire project so the
        // protocol-extension-default rule has the context it needs.
        let protocolGraph = collectProtocolGraph(in: sources)
        let protocolNames = protocolGraph.names

        var allDeclarations: [DeclarationInfo] = []
        var allDiagnostics: [Diagnostic] = []
        var pendingSelfCalls: [(signature: Signature, confident: Diagnostic, unresolved: Diagnostic)] = []
        var signatureDiscriminators: [Signature: Set<TypeDiscriminator>] = [:]
        for entry in sources {
            let analysis = analyzeFile(
                source: entry.source,
                fileName: entry.fileName,
                protocolNames: protocolNames
            )
            allDeclarations.append(contentsOf: analysis.declarations)
            allDiagnostics.append(contentsOf: analysis.diagnostics)
            pendingSelfCalls.append(contentsOf: analysis.pendingSelfCalls)
            for (signature, discriminators) in analysis.signatureDiscriminators {
                signatureDiscriminators[signature, default: []].formUnion(discriminators)
            }
        }

        // Whether a self-named call resolves to *this* declaration or to a sibling
        // overload is a property of the whole project, not of one file: a Swift type
        // spans files, and swift-collections declares `_ptr(at:)` for `Bucket` in one
        // file and for `Int` in another. Deciding per file reported the first as
        // recursion because it could not see the second.
        for pending in pendingSelfCalls {
            // Widen to overloads reachable by conformance: a default in `extension
            // SchemaType` can be calling a member of `extension QueryType`.
            var visible = signatureDiscriminators[pending.signature] ?? []
            for ancestor in inheritedClosure(
                of: pending.signature.typeContext, in: protocolGraph.inherits
            ) {
                let inherited = Signature(
                    typeContext: ancestor, displayName: pending.signature.displayName)
                visible.formUnion(signatureDiscriminators[inherited] ?? [])
            }
            let isOverloaded = visible.count > 1
            allDiagnostics.append(isOverloaded ? pending.unresolved : pending.confident)
        }

        // Pass 1: Project-wide mutual cycle detection (name-based, rule 8).
        let nameBasedCycleDiagnostics = detectMutualCyclesImpl(declarations: allDeclarations)

        // Pass 2: USR-based cycle detection via IndexStoreDB (when available).
        if configuration.recursion.useIndexStore {
            do {
                let pass2 = try await runIndexStorePass(
                    configuration: configuration,
                    baseCaseSites: RecursionIndexPass.baseCaseSites(from: allDeclarations),
                    selfBaseCaseSites: RecursionIndexPass.selfBaseCaseSites(from: allDeclarations),
                    analysedSites: RecursionIndexPass.analysedSites(from: allDeclarations)
                )

                // Where the index could see the file, its USR answer supersedes the
                // syntactic guess: an overload the AST pass had to record as unresolved
                // resolves to a different USR here, so it produces no self-edge and no
                // finding. Restricted to covered files, because an index that saw nothing
                // must not be allowed to erase findings it never examined.
                let supersededByUSR: Set<String> = [
                    "recursion.unconditional-self-call",
                    "recursion.self-reference-unresolved",
                    // Both of these were Pass 1 asserting something only a type checker can
                    // settle, in a file the index had already read properly.
                    //
                    // `mutual-cycle` here is the *name-based* finding from
                    // `detectMutualCyclesImpl`. GRDB's `SQLExpression` declares
                    // `indirect case collated(SQLExpression, Database.CollationName)` and
                    // `static func collated(_:_:) -> Self` — same name, same argument types,
                    // same arity. Which one `.collated(expression, collationName)` means is
                    // decided by contextual type, so the syntactic pass reads the
                    // terminating branch as a recursive call and the cycle as unbounded.
                    //
                    // `protocol-extension-default-self` is the same problem across a module
                    // boundary: GRDB's `EncodableRecord.encode(to: inout PersistenceContainer)`
                    // calls `Encodable.encode(to: Encoder)`, which is in the standard library
                    // and therefore absent from any census of the package.
                    //
                    // Removal runs before Pass 2's own findings are appended, so a cycle the
                    // index genuinely sees is still reported — by the pass that can prove it.
                    "recursion.mutual-cycle",
                    "recursion.protocol-extension-default-self",
                ]
                allDiagnostics.removeAll { diagnostic in
                    guard let ruleId = diagnostic.ruleId, supersededByUSR.contains(ruleId),
                          let path = diagnostic.filePath else { return false }
                    return pass2.coveredFiles.contains(
                        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                    )
                }
                allDiagnostics.append(contentsOf: pass2.diagnostics)

                for diag in nameBasedCycleDiagnostics {
                    allDiagnostics.append(RecursionIndexPass.demoteToNote(diag))
                }
            } catch {
                Self.logger.warning("IndexStore pass failed, falling back to name-based cycle detection: \(error.localizedDescription, privacy: .public)")
                allDiagnostics.append(contentsOf: nameBasedCycleDiagnostics)
                allDiagnostics.append(contentsOf: RecursionIndexPass.runWithoutIndex())
            }
        } else {
            allDiagnostics.append(contentsOf: nameBasedCycleDiagnostics)
        }

        let duration = ContinuousClock.now - startTime
        let hasErrors = allDiagnostics.contains { $0.severity == .error }
        let status: CheckResult.Status = hasErrors ? .failed : .passed
        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: allDiagnostics,
            duration: duration
        )
    }

    // MARK: - Private

    private func collectProtocolGraph(
        in sources: [(fileName: String, source: String)]
    ) -> (names: Set<String>, inherits: [String: Set<String>]) {
        var names: Set<String> = []
        var inherits: [String: Set<String>] = [:]
        for entry in sources {
            let tree = Parser.parse(source: entry.source)
            let collector = ProtocolNameCollector(viewMode: .sourceAccurate)
            collector.walk(tree)
            names.formUnion(collector.protocolNames)
            for (child, parents) in collector.inheritedProtocols {
                inherits[child, default: []].formUnion(parents)
            }
        }
        return (names, inherits)
    }

    private func analyzeFile(
        source: String,
        fileName: String,
        protocolNames: Set<String>
    ) -> FileAnalysis {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let visitor = RecursionVisitor(
            fileName: fileName,
            source: source,
            converter: converter,
            protocolNames: protocolNames
        )
        visitor.walk(tree)
        return FileAnalysis(
            diagnostics: visitor.diagnostics,
            declarations: visitor.declarations,
            pendingSelfCalls: visitor.pendingSelfCalls,
            signatureDiscriminators: visitor.signatureDiscriminators
        )
    }

    /// Runs the IndexStoreDB-backed Pass 2 for USR-based cycle detection.
    private func runIndexStorePass(configuration: Configuration, baseCaseSites: Set<DeclarationSite>,
        selfBaseCaseSites: Set<DeclarationSite>,
        analysedSites: Set<DeclarationSite>
    ) async throws -> RecursionIndexPass.Result {
        let cwd = configuration.resolvedProjectRoot
        let kind = ProjectKind.detect(at: cwd)

        guard let located = try StoreLocator.locate(projectKind: kind) else {
            throw IndexStorePassError.noIndexStore
        }

        guard let libPath = IndexStoreSession.findLibIndexStore() else {
            throw IndexStorePassError.toolchainNotFound
        }

        let session = try await SharedIndexStore.session(storePath: located.url, libPath: libPath)
        let swiftFiles = SourceWalker.swiftFiles(under: kind.rootURL, excludePatterns: configuration.excludePatterns)

        return try RecursionIndexPass.run(
            session: session,
            swiftFiles: swiftFiles,
            baseCaseSites: baseCaseSites,
            selfBaseCaseSites: selfBaseCaseSites,
            analysedSites: analysedSites
        )
    }

    /// Errors specific to the IndexStore pass integration.
    enum IndexStorePassError: Error {
        /// No index store could be located for the project.
        case noIndexStore
        /// The Swift toolchain or libIndexStore.dylib could not be found.
        case toolchainNotFound
    }

    private func detectMutualCyclesImpl(declarations: [DeclarationInfo]) -> [Diagnostic] {
        // Build the callable subgraph: only functions/methods participate.
        let callable = declarations.filter { $0.isCallable }
        // Index declarations by signature for quick lookup.
        var signatureToIndex: [Signature: Int] = [:]
        for (index, decl) in callable.enumerated() {
            // First declaration wins on collision (overload sets are rare in test fixtures).
            if signatureToIndex[decl.signature] == nil {
                signatureToIndex[decl.signature] = index
            }
        }

        // Adjacency list keyed by index.
        var adjacency: [[Int]] = Array(repeating: [], count: callable.count)
        for (sourceIndex, decl) in callable.enumerated() {
            for call in decl.outgoingCalls {
                for candidate in call.candidateSignatures {
                    if let targetIndex = signatureToIndex[candidate] {
                        adjacency[sourceIndex].append(targetIndex)
                    }
                }
            }
        }

        // Tarjan's strongly connected components.
        let sccs = tarjanSCCs(adjacency: adjacency)

        var diagnostics: [Diagnostic] = []
        for component in sccs where component.count >= 2 {
            // If any participant has a base case the cycle can terminate.
            let hasBaseCase = component.contains { callable[$0].hasBaseCase }
            if hasBaseCase { continue }

            for memberIndex in component {
                let decl = callable[memberIndex]
                // An unbounded cycle is a crash on untrusted input, not a style note. A
                // stack overflow cannot be caught by the caller, it takes the process. This
                // was reported as a warning while the finding was true: four correct
                // findings sat unread in BusinessMath's output — competing with 53 errors
                // from a stale worktree — until someone went looking for warnings
                // specifically, and the crashable path was public API taking user input.
                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: "function '\(decl.signature.displayName)' re-enters a mutual recursion cycle with no bound. Recursion depth grows with input length, so input that is merely long — not malformed — overflows the stack. A stack overflow cannot be caught by the caller.",
                    filePath: decl.location.file,
                    lineNumber: decl.location.line,
                    columnNumber: decl.location.column,
                    ruleId: "recursion.mutual-cycle",
                    suggestedFix: "Bound the descent — a depth counter checked by a guard in the body of each participant — or make the cycle iterative. The guard must appear in the participant itself: a bound reached through a helper is not visible to a reader deciding whether this function terminates, and the check is for that reader. Choose the limit against the smallest stack the code can run on — a cooperative executor's thread is far smaller than the main thread's, so a bound verified in a scratch program can still overflow under a test runner."
                ))
            }
        }
        return diagnostics
    }

    private func tarjanSCCs(adjacency: [[Int]]) -> [[Int]] {
        let count = adjacency.count
        var index = 0
        var sccStack: [Int] = []
        var indices: [Int?] = Array(repeating: nil, count: count)
        var lowlinks: [Int] = Array(repeating: 0, count: count)
        var onStack: [Bool] = Array(repeating: false, count: count)
        var result: [[Int]] = []

        struct Frame {
            let node: Int
            var neighborIndex: Int
            let parent: Int?
        }

        for startNode in 0..<count where indices[startNode] == nil {
            var workStack = [Frame(node: startNode, neighborIndex: 0, parent: nil)]
            indices[startNode] = index
            lowlinks[startNode] = index
            index += 1
            sccStack.append(startNode)
            onStack[startNode] = true

            while let frame = workStack.last {
                let v = frame.node
                let neighbors = adjacency[v]

                if frame.neighborIndex < neighbors.count {
                    let w = neighbors[frame.neighborIndex]
                    workStack[workStack.count - 1].neighborIndex += 1

                    if indices[w] == nil {
                        indices[w] = index
                        lowlinks[w] = index
                        index += 1
                        sccStack.append(w)
                        onStack[w] = true
                        workStack.append(Frame(node: w, neighborIndex: 0, parent: v))
                    } else if onStack[w] {
                        if let wIdx = indices[w] {
                            lowlinks[v] = min(lowlinks[v], wIdx)
                        }
                    }
                } else {
                    if let vIdx = indices[v], lowlinks[v] == vIdx {
                        var component: [Int] = []
                        while true { // SAFETY: loop terminates when sccStack is empty or w == v
                            guard let w = sccStack.popLast() else { break }
                            onStack[w] = false
                            component.append(w)
                            if w == v { break }
                        }
                        result.append(component)
                    }

                    workStack.removeLast()
                    if let parent = frame.parent {
                        lowlinks[parent] = min(lowlinks[parent], lowlinks[v])
                    }
                }
            }
        }
        return result
    }
}

// MARK: - Supporting Types

/// A declaration found in a Swift source file.
struct DeclarationInfo {
    let signature: Signature
    let location: SourceLocation
    /// True if the body contains a guard-driven early exit.
    ///
    /// The strict test, and the one a *cycle* needs: a branch returning some other call
    /// is not a bound, because that call may be the next participant.
    let hasBaseCase: Bool
    /// True if some branch exits without re-entering this declaration.
    ///
    /// The loose test, and the one *direct* self-recursion needs. Kept separate because
    /// sharing one test between the two questions silently moved `mutual-cycle` from 89
    /// to 72 when it was tried.
    let hasSelfBaseCase: Bool
    /// True if the AST pass actually read this declaration's body.
    ///
    /// False for a protocol requirement, a stored property, and anything else that has no
    /// body to read — including the accessors a macro generates, which the tree shows only
    /// as an attribute. The index sees the expansion; we do not, so we must not judge it.
    let wasAnalysed: Bool
    /// Outgoing call sites collected from the body.
    let outgoingCalls: [CallSite]
    /// True if this declaration participates in cycle detection (functions/methods).
    let isCallable: Bool
}

/// A signature uniquely identifying a callable within its enclosing type context.
/// The part of a Swift function's identity that argument labels do not carry.
///
/// `Signature` is a *matching* key, not an *identity* key: a call site knows a base name
/// and argument labels and nothing more, so `Signature` deliberately stops there. But two
/// declarations sharing a `Signature` are not necessarily the same function, and the
/// overload census needs to tell them apart. That is this type's only job.
///
/// Not a type checker — a syntactic approximation over written spellings, normalized for
/// sugar. `throws` is excluded on purpose: a non-throwing default legally satisfies a
/// throwing requirement, so comparing it would separate a requirement from its own default.
struct TypeDiscriminator: Hashable {
    let parameterTypes: [String]
    let isAsync: Bool
    let returnType: String
}

/// Folds Swift's sugar so two spellings of one type compare equal.
///
/// Deliberately partial: generic parameter names and `some P` versus `<T: P>` are left
/// alone. Measured across the 22-package corpus, the residual disagreement among
/// requirement/default pairs after this folding is zero of 229.
func normalizeTypeSpelling(_ type: String) -> String {
    var s = type.filter { !$0.isWhitespace }
    while let r = s.range(of: "Self.") { s.replaceSubrange(r, with: "") }

    func matchingAngle(_ s: String, from: String.Index) -> String.Index? {
        var depth = 1
        var i = from
        while i < s.endIndex {
            if s[i] == "<" { depth += 1 }
            if s[i] == ">" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = s.index(after: i)
        }
        return nil
    }

    func topLevelComma(_ s: String) -> String.Index? {
        var depth = 0
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "<" || s[i] == "[" || s[i] == "(" { depth += 1 }
            if s[i] == ">" || s[i] == "]" || s[i] == ")" { depth -= 1 }
            if s[i] == "," && depth == 0 { return i }
            i = s.index(after: i)
        }
        return nil
    }

    var changed = true
    while changed {
        changed = false
        if let r = s.range(of: "Array<"), let end = matchingAngle(s, from: r.upperBound) {
            let inner = String(s[r.upperBound..<end])
            s.replaceSubrange(r.lowerBound..<s.index(after: end), with: "[\(inner)]")
            changed = true
            continue
        }
        if let r = s.range(of: "Optional<"), let end = matchingAngle(s, from: r.upperBound) {
            let inner = String(s[r.upperBound..<end])
            s.replaceSubrange(r.lowerBound..<s.index(after: end), with: "\(inner)?")
            changed = true
            continue
        }
        if let r = s.range(of: "Dictionary<"), let end = matchingAngle(s, from: r.upperBound) {
            let inner = String(s[r.upperBound..<end])
            if let comma = topLevelComma(inner) {
                let key = String(inner[inner.startIndex..<comma])
                let value = String(inner[inner.index(after: comma)...])
                s.replaceSubrange(r.lowerBound..<s.index(after: end), with: "[\(key):\(value)]")
                changed = true
                continue
            }
        }
    }
    return s
}

struct Signature: Hashable {
    /// Lexical type context. Empty for free declarations, otherwise dot-joined
    /// type names like "Foo" or "Foo.Inner".
    let typeContext: String
    /// Display name with argument labels: `f(_:x:)`, `init(name:)`,
    /// `subscript(_:)`, or for properties just the property name.
    let displayName: String
}

/// A call site within a declaration body, with the candidate signatures it
/// might resolve to. The graph builder picks any candidate that exists as a
/// declaration in the project.
struct CallSite {
    let candidateSignatures: [Signature]
}

/// Source location for a diagnostic.
/// A declaration site — the only identifier both recursion passes can compute.
///
/// Pass 1 knows base cases by AST location and has no USRs; the index knows symbols by
/// USR and has no syntax tree. The definition's canonical path plus its display name
/// carries Pass 1's answer across the gap, and both sides spell that name the same way:
/// `makeFunctionDisplayName` produces `_subtracting(_:_:)` and so does IndexStoreDB's
/// `symbol.name`.
///
/// Keyed on the name rather than the line, which was tried first and matched barely half
/// the corpus — a declaration's line drifts between the two passes (attributes, multi-line
/// signatures) and a near-miss silently drops the base case, which reports a bounded cycle
/// as unbounded. Two overloads in one file with the same display name both get marked;
/// that errs toward suppression, which is the safer direction for a heuristic feeding an
/// error-severity rule.
struct DeclarationSite: Hashable, Sendable {
    let path: String
    let name: String
}

struct SourceLocation {
    let file: String
    let line: Int
    let column: Int
}

/// Per-file analysis result.
struct FileAnalysis {
    let diagnostics: [Diagnostic]
    let declarations: [DeclarationInfo]
    /// Self-call findings awaiting the project-wide overload census.
    let pendingSelfCalls: [(signature: Signature, confident: Diagnostic, unresolved: Diagnostic)]
    /// How many implementations of each signature this file contributes.
    let signatureDiscriminators: [Signature: Set<TypeDiscriminator>]
}
