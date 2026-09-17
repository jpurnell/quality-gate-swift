import Foundation
import IndexStoreInfra
#if canImport(os)
import os
#endif
import FloatingPointSafetyAuditor
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Scans Swift test files for quality anti-patterns.
///
/// Detects:
/// - Exact equality (`==`/`!=`) on floating-point operands inside `#expect`
///   (`exact-double-equality`)
/// - `try!` in test code
/// - Unseeded randomness (`.random`, `SystemRandomNumberGenerator`)
/// - `@Test` functions with no assertions (`#expect` or `#require`)
/// - Weak assertions (`!= 0`, `!= nil`) without quantitative bounds
///
/// ## Two kinds of rule live here
///
/// The five rules above are properties of one assertion's *syntax*. They are exact, they are
/// fast, and a finding is a defect.
///
/// The rules in `SemanticTestRules` and `SelfReferentialExpectation` are proxies. They
/// cannot see the relationship between an assertion and the thing under test — no syntactic
/// rule can — so they name shapes where vacuous tests are found in practice:
///
/// | Rule | Severity | Default |
/// |---|---|---|
/// | `unasserted-optional-unwrap` | error | on |
/// | `self-referential-expectation` | error | on |
/// | `non-strict-improvement` | warning | on |
/// | `coalesced-assertion` | warning | on |
/// | `ambient-calendar-in-test` | error | on |
/// | `skipped-test-inventory` | note | on |
/// | `unvaried-parameter` | warning | opt-in |
/// | `assertion-on-constant` | warning | opt-in |
/// | `tolerance-without-magnitude` | warning | opt-in |
///
/// The opt-in three arrive red on a clean corpus and would be switched off rather than
/// acted on; `TestQualityVisitor.optInRules` records what each measured and why.
/// Suppression for these rules must **name** the rule — see
/// `TestQualityVisitor.scopedOverrideIfExempted(line:ruleId:)`.
///
/// `coalesced-assertion` is back at `warning` after a promotion to `error` that was **reverted
/// the same day**, and the reason is worth more than the rule is.
///
/// It shipped 2026-09-14 at `warning`, and two working days later the five repositories named
/// in its proposal reported zero findings — 54 repaired, not one suppression marker. That looked
/// like ADR-001's condition satisfied, so it was promoted.
///
/// **Five was the wrong denominator.** The corpus knows 78 projects that push gate telemetry and
/// 75 that run `test-quality`, and a query against their most recent runs found **113 findings
/// across 19 projects** — a set that includes `SwiftMCPServer`, whose own gate blocked a push
/// within the hour. ADR-001 says to measure per consuming repository; the promotion measured a
/// proposal's list instead, which is a different and much smaller thing.
///
/// The lesson is not "be more careful." It is that the consumer set is **discoverable** — the
/// scan that found those 19 projects took about a second against data the corpus already
/// stores — and a promotion that does not run it is guessing. Re-promotion is gated on that
/// query returning zero, not on a hand sweep.
///
/// `ambient-calendar-in-test` remains at `error`; its population is 18 findings in two projects.
///
/// ## The exact-comparison rule is not implemented here
///
/// `exact-double-equality` and `fp-safety`'s `fp-equality` are the same rule.
/// They were once two detectors and drifted: different operands, different
/// suppression markers, and contradictory advice, so a developer could apply
/// the marker one checker named and still fail the other on the same line.
/// Detection now lives in `FloatingPointRules` (FloatingPointSafetyAuditor); this checker supplies the
/// reporting configuration — error severity, and only inside an assertion.
///
/// ## Usage
///
/// ```swift
/// import QualityGateCore
///
/// let config = Configuration()
/// let auditor = TestQualityAuditor()
/// let result = try await auditor.check(configuration: config)
/// ```
public struct TestQualityAuditor: QualityChecker, Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "TestQualityAuditor")

    /// Unique identifier for this checker.
    public let id = "test-quality"

    /// Human-readable name for this checker.
    public let name = "Test Quality Auditor"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Floating-point assertions, missing or vacuous test assertions, silent skips, ambient time, unseeded randomness in tests"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.codeHygiene

    /// What this checker's findings are about — see `CheckerKind`.
    /// decided 2026-08-16: fix the noisy rules rather than hide from them
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Analyses source without running it — safe to point at a stranger's package.
    public let executesProjectCode = false
    /// Creates a new TestQualityAuditor instance.
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

    /// Run the test quality audit on the Tests/ directory.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        let fileManager = FileManager.default
        let currentDir = configuration.resolvedProjectRoot.path
        let testsPath = (currentDir as NSString).appendingPathComponent("Tests")

        var allDiagnostics: [Diagnostic] = []
        var allOverrides: [DiagnosticOverride] = []

        if fileManager.fileExists(atPath: testsPath) { // SAFETY: CLI reads Tests/ from cwd; no user-supplied path component
            // Built once for the whole run: `self-referential-expectation` compares an
            // assertion against a body in `Sources/`, so it needs the other half of the
            // package. Every other rule here is a property of the test file alone.
            let implementations = SelfReferentialExpectation.buildIndex(projectRoot: currentDir)
            let result = try await auditDirectory(
                at: testsPath,
                configuration: configuration,
                implementations: implementations
            )
            allDiagnostics.append(contentsOf: result.diagnostics)
            allOverrides.append(contentsOf: result.overrides)
        }

        // Property coverage reads Sources/ as well as Tests/, because the finding is
        // about a function that owes an invariant, not about any individual test.
        //
        // Opt-in by rule id until a project's worklist is burned down. It arrives with 69
        // findings on this package, and a rule that is red on arrival gets skipped — the
        // lesson `doc-code` already paid for, where sixteen findings were enough to justify
        // shipping opt-in and promoting it only once the corpus was repaired. Enable with
        // `enabledCheckers: ["test-quality.property-coverage"]`.
        if configuration.enabledCheckers.contains(PropertyCoverage.ruleId) {
            allDiagnostics += Self.propertyCoverageDiagnostics(projectRoot: currentDir)
        }

        let duration = ContinuousClock.now - startTime

        return CheckResult(
            checkerId: id,
            status: Self.status(for: allDiagnostics),
            diagnostics: allDiagnostics,
            overrides: allOverrides,
            duration: duration
        )
    }

    /// Audit a single source code string (useful for testing).
    ///
    /// - Parameters:
    ///   - source: The Swift source code to audit.
    ///   - fileName: The name of the file (for diagnostics).
    ///   - configuration: The project configuration.
    /// - Returns: A check result with any violations found.
    public func auditSource(
        _ source: String,
        fileName: String,
        configuration: Configuration
    ) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        let result = auditSourceCode(
            source,
            fileName: fileName,
            configuration: configuration
        )

        let duration = ContinuousClock.now - startTime

        return CheckResult(
            checkerId: id,
            status: Self.status(for: result.diagnostics),
            diagnostics: result.diagnostics,
            overrides: result.overrides,
            duration: duration
        )
    }

    /// The status a set of diagnostics implies, by their severity.
    ///
    /// Previously this was `diagnostics.isEmpty ? .passed : .failed`, which failed the
    /// checker on any finding whatever its severity. That held while every rule here was an
    /// error or a warning. `skipped-test-inventory` is the first to emit `.note`, whose
    /// entire purpose is to be reported without gating — and counting notes as failures
    /// would have made a rule that never blocks a commit block every commit.
    ///
    /// This matches what `OverrideProcessor` already documents for the same question:
    /// any error fails, any warning warns, notes alone pass.
    static func status(for diagnostics: [Diagnostic]) -> CheckResult.Status {
        if diagnostics.contains(where: { $0.severity == .error }) { return .failed }
        if diagnostics.contains(where: { $0.severity == .warning }) { return .warning }
        return .passed
    }

    // MARK: - Private Implementation

    private func auditDirectory(
        at path: String,
        configuration: Configuration,
        implementations: SelfReferentialExpectation.ImplementationIndex
    ) async throws -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        let fileManager = FileManager.default
        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []

        guard let enumerator = fileManager.enumerator(atPath: path) else {
            return ([], [])
        }

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }

            let fullPath = (path as NSString).appendingPathComponent(relativePath)

            if shouldExclude(path: fullPath, patterns: configuration.excludePatterns) {
                continue
            }

            do {
                let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                let result = auditSourceCode(
                    source,
                    fileName: fullPath,
                    configuration: configuration,
                    implementations: implementations
                )
                diagnostics.append(contentsOf: result.diagnostics)
                overrides.append(contentsOf: result.overrides)
            } catch {
                Self.logger.warning("Skipping unreadable test file \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
        }

        return (diagnostics, overrides)
    }

    private func shouldExclude(path: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            if pathMatches(path: path, pattern: pattern) {
                return true
            }
        }
        return false
    }

    private func pathMatches(path: String, pattern: String) -> Bool {
        if pattern.contains("**") {
            let component = pattern.replacingOccurrences(of: "**/", with: "")
                .replacingOccurrences(of: "/**", with: "")
            return path.contains(component)
        }
        return path.contains(pattern.replacingOccurrences(of: "*", with: ""))
    }

    private func auditSourceCode(
        _ source: String,
        fileName: String,
        configuration: Configuration,
        implementations: SelfReferentialExpectation.ImplementationIndex = .empty
    ) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        let sourceFile = Parser.parse(source: source)
        // One converter for the file. Six rules used to build their own per visited node, each
        // indexing every line start in the tree.
        let converter = SourceLocationConverter(fileName: fileName, tree: sourceFile)

        // The other test-quality rules keep their own marker. `fp-safety:disable`
        // is scoped to the floating-point rule it names — it must not silence a
        // force-try or an unseeded draw.
        let visitor = TestQualityVisitor(
            fileName: fileName,
            source: source,
            converter: converter,
            exemptionPatterns: configuration.safetyExemptions + ["// TEST-QUALITY:"],
            enabledOptInRules: Set(configuration.enabledCheckers),
            implementations: implementations
        )
        visitor.walk(sourceFile)

        // exact-double-equality is not implemented here. One rule, one detector.
        let fpResult = FloatingPointRules.audit(
            source: source,
            fileName: fileName,
            options: .testAssertions(
                extraSuppressionMarkers: configuration.safetyExemptions
            ),
            parsedTree: sourceFile
        )

        return (
            visitor.diagnostics + fpResult.diagnostics,
            visitor.overrides + fpResult.overrides
        )
    }

    // MARK: - Property Coverage

    /// Shape-bearing functions in `Sources/` that no property-shaped test exercises.
    ///
    /// Reads both trees once. The source pass classifies functions by shape; the test
    /// pass collects the symbols named inside property-shaped tests; coverage extends
    /// one fixed level of delegation. ``PropertyCoverage`` documents why that depth is
    /// one and why it is not configurable.
    ///
    /// - Parameter projectRoot: The package root.
    /// - Returns: One warning per uncovered candidate, ordered by file then line.
    static func propertyCoverageDiagnostics(projectRoot: String) -> [Diagnostic] {
        let manager = FileManager.default
        var candidates: [PropertyCoverage.Candidate] = []
        var calls: [String: Set<String>] = [:]

        for spelling in ["Sources", "Source", "src"] {
            let root = URL(fileURLWithPath: projectRoot).appendingPathComponent(spelling)
            guard let walker = manager.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard !url.path.contains(".build/"), !url.path.contains(".docc/") else { continue }
                guard let text = SourceFileReader.read(url, checker: "test-quality") else { continue }
                let found = PropertyCoverage.candidates(in: text, path: url.path)
                candidates += found.candidates
                for (caller, callees) in found.calls {
                    calls[caller, default: []].formUnion(callees)
                }
            }
        }
        guard !candidates.isEmpty else { return [] }

        var covered: Set<String> = []
        let tests = URL(fileURLWithPath: projectRoot).appendingPathComponent("Tests")
        if let walker = manager.enumerator(
            at: tests, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard !url.path.contains(".build/") else { continue }
                guard let text = SourceFileReader.read(url, checker: "test-quality") else { continue }
                covered.formUnion(PropertyCoverage.propertyCoveredSymbols(inTestSource: text))
            }
        }

        return PropertyCoverage.findings(
            candidates: candidates, calls: calls, coveredDirectly: covered)
    }
}

// MARK: - Syntax Visitor

private final class TestQualityVisitor: SyntaxVisitor {
    let fileName: String
    let source: String
    /// Built once per file by the caller. Constructing one per visited node indexes every line
    /// start in the tree each time — O(file) per node, measured n^1.99 on triggering input.
    let converter: SourceLocationConverter
    let exemptionPatterns: [String]
    let sourceLines: [String]
    var diagnostics: [Diagnostic] = []
    var overrides: [DiagnosticOverride] = []

    /// Tracks whether we're inside a `@Test`-attributed function.
    private var currentTestFunctionName: String?
    private var currentTestFunctionLine: Int?
    private var currentTestHasAssertion: Bool = false

    /// How many closures or nested function declarations enclose the node being visited,
    /// counted from the `@Test` function's own body.
    ///
    /// `return` means different things at different depths. At zero it abandons the test;
    /// deeper, it answers a closure or a helper and the test carries on. Only
    /// `unasserted-optional-unwrap` consults this — the other rules are properties of a
    /// line and do not care what encloses it.
    private var nestedScopeDepth: Int = 0

    /// What the `@Test` currently being walked has done so far — see `unvaried-parameter`.
    private var currentTestShape = SemanticTestRules.TestShape()

    /// Whether the file imports the Testing framework.
    private var importsTestingFramework: Bool = false

    /// Rule ids the project has opted into — see ``TestQualityVisitor/isEnabled(_:)``.
    let enabledOptInRules: Set<String>

    /// Single-expression bodies from `Sources/`, for `self-referential-expectation`.
    /// Empty when auditing a bare source string, so the rule reports nothing.
    let implementations: SelfReferentialExpectation.ImplementationIndex

    /// Lines carrying a `// TEST-QUALITY-FILE:` marker — see
    /// ``TestQualityVisitor/fileScopedOverride(line:ruleId:)``.
    let fileScopedMarkers: [String]

    init(
        fileName: String,
        source: String,
        converter: SourceLocationConverter,
        exemptionPatterns: [String],
        enabledOptInRules: Set<String> = [],
        implementations: SelfReferentialExpectation.ImplementationIndex = .empty
    ) {
        self.converter = converter
        self.fileName = fileName
        self.source = source
        self.exemptionPatterns = exemptionPatterns
        self.enabledOptInRules = enabledOptInRules
        self.implementations = implementations
        let lines = source.lines
        self.sourceLines = lines
        self.fileScopedMarkers = lines.filter { $0.contains(Self.fileMarker) }
        super.init(viewMode: .sourceAccurate)
    }

    /// Rules that ship off by default because they arrive red on real corpora.
    ///
    /// Both were measured across BusinessMath's 557 test files, and both are *correct*:
    ///
    /// - `tolerance-without-magnitude` — **384 findings**. Almost all are optimizer and
    ///   quadrature tests asserting convergence to within 5–20% of an expected value. Some
    ///   of those tolerances were surely loosened until the test passed; others are honest
    ///   statements about a quantity that genuinely is not known more precisely. The rule
    ///   cannot tell the two apart, which is the point — it makes the ratio visible so a
    ///   human can. That is a review conversation, not a build failure.
    /// - `assertion-on-constant` — **73 findings**, every one an `#expect(true)`. These are
    ///   unambiguous, but they are also a seventy-three item worklist that has nothing to do
    ///   with whatever commit first trips over them.
    ///
    /// This repository has already paid for the alternative twice. `property-coverage`
    /// arrived with 69 findings and `doc-code` with 16, and both shipped opt-in for the same
    /// reason recorded there: *a rule that is red on arrival gets skipped*, and a skipped
    /// rule protects nothing. Promotion is earned by repairing a corpus, never by relaxing
    /// the rule.
    ///
    /// Enable per project:
    /// `enabledCheckers: ["test-quality.tolerance-without-magnitude"]`.
    /// - `unvaried-parameter` — **129 findings** after the fixture, conformance and refusal
    ///   exclusions cut it from 141. The survivors include genuine targets — `combination(10,
    ///   c: 3)` asserted against a single expected value cannot tell that `c` is ignored —
    ///   alongside initialization tests where the shape is simply what the test is. The
    ///   proposal makes this rule's promotion conditional on a false-positive rate "measured
    ///   below a threshold on at least two real corpora"; it has been measured on one, and
    ///   129 is not below a threshold. Opt-in is what that condition means in practice.
    static let optInRules: Set<String> = [
        "tolerance-without-magnitude",
        "assertion-on-constant",
        "unvaried-parameter",
    ]

    /// Whether a rule should report, given what the project opted into.
    private func isEnabled(_ ruleId: String) -> Bool {
        guard Self.optInRules.contains(ruleId) else { return true }
        return enabledOptInRules.contains("test-quality.\(ruleId)")
    }

    // MARK: - Import Detection

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let moduleName = node.path.map { $0.name.text }.joined(separator: ".")
        if moduleName == "Testing" {
            importsTestingFramework = true
        }
        return .visitChildren
    }

    // MARK: - @Test Function Tracking

    /// Whether a declaration carries the `@Test` attribute.
    ///
    /// Extracted from the two copies that `visit` and `visitPost` each kept: they had to
    /// agree for the enter/leave bookkeeping to balance, and two copies of a predicate that
    /// must agree is one copy too many.
    private func isTestFunction(_ node: FunctionDeclSyntax) -> Bool {
        node.attributes.contains { attr in
            if let identAttr = attr.as(AttributeSyntax.self) {
                let attrName: String
                if let identifier = identAttr.attributeName.as(IdentifierTypeSyntax.self) {
                    attrName = identifier.name.text
                } else {
                    attrName = identAttr.attributeName.description.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return attrName == "Test"
            }
            return false
        }
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if let skip = SemanticTestRules.skipTrait(in: node.attributes) {
            recordSkip(skip, at: node)
        }

        if isTestFunction(node) {
            currentTestFunctionName = node.name.text
            let location = node.startLocation(
                converter: converter
            )
            currentTestFunctionLine = location.line
            currentTestHasAssertion = false
            nestedScopeDepth = 0
            currentTestShape = SemanticTestRules.TestShape()
        } else if currentTestFunctionName != nil {
            // A helper declared inside the test body. Its `return` is its own.
            nestedScopeDepth += 1
        }

        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        // Only process when leaving a @Test function, not nested helpers.
        guard isTestFunction(node) else {
            if currentTestFunctionName != nil, nestedScopeDepth > 0 {
                nestedScopeDepth -= 1
            }
            return
        }

        if let testName = currentTestFunctionName,
           currentTestHasAssertion,
           SemanticTestRules.isUnvaried(currentTestShape) {
            emit(
                severity: .warning,
                message: "Test '\(testName)' makes one call with fixed arguments and one assertion, so it cannot detect that a parameter is ignored.",
                ruleId: "unvaried-parameter",
                fix: "Assert across a spread of inputs — a monotonicity, or a relation that must hold at several values",
                at: node)
        }

        if let testName = currentTestFunctionName, !currentTestHasAssertion {
            let line = currentTestFunctionLine ?? 1
            if let override = overrideIfExempted(line: line, ruleId: "missing-assertion") {
                overrides.append(override)
            } else {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "Test function '\(testName)' has no #expect or #require assertions.",
                    filePath: fileName,
                    lineNumber: line,
                    columnNumber: nil,
                    ruleId: "missing-assertion",
                    suggestedFix: "Add #expect or #require assertions to validate behavior"
                ))
            }
        }
        currentTestFunctionName = nil
        currentTestFunctionLine = nil
        currentTestHasAssertion = false
        nestedScopeDepth = 0
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        if currentTestFunctionName != nil {
            nestedScopeDepth += 1
        }
        return .visitChildren
    }

    override func visitPost(_ node: ClosureExprSyntax) {
        if currentTestFunctionName != nil, nestedScopeDepth > 0 {
            nestedScopeDepth -= 1
        }
    }

    // MARK: - Force Try Detection

    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        if node.questionOrExclamationMark?.tokenKind == .exclamationMark {
            let location = node.startLocation(
                converter: converter
            )
            let line = location.line

            if let override = overrideIfExempted(line: line, ruleId: "force-try-in-test") {
                overrides.append(override)
                return .visitChildren
            }

            diagnostics.append(Diagnostic(
                severity: .error,
                message: "Force try (try!) in test code. Use do/catch with #expect(throws:) or propagate with 'throws'.",
                filePath: fileName,
                lineNumber: line,
                columnNumber: location.column,
                ruleId: "force-try-in-test",
                suggestedFix: "Replace try! with #expect(throws: ErrorType.self) { try expression } or mark test as throws"
            ))
        }

        return .visitChildren
    }

    // A disabled suite is reported once, at the suite. Reporting it per test it contains
    // would turn one decision into forty lines of output and bury the decision.
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if let skip = SemanticTestRules.skipTrait(in: node.attributes) {
            recordSkip(skip, at: node)
        }
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if let skip = SemanticTestRules.skipTrait(in: node.attributes) {
            recordSkip(skip, at: node)
        }
        return .visitChildren
    }

    override func visit(_ node: ThrowStmtSyntax) -> SyntaxVisitorContinueKind {
        // Not scoped to `@Test`: XCTSkip is the XCTest spelling, and the XCTest suites that
        // still use it declare `func testX()` with no attribute at all.
        if let skip = SemanticTestRules.xctSkip(in: node) {
            recordSkip(skip, at: node)
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // Only calls the test itself makes. A call nested inside a closure argument is part
        // of the same single statement and would double-count the one thing being measured.
        if currentTestFunctionName != nil, nestedScopeDepth == 0,
           !SemanticTestRules.looksLikeFixtureConstruction(node) {
            currentTestShape.subjectCalls += 1
            if SemanticTestRules.hasOnlyLiteralArguments(node) {
                currentTestShape.allLiteralCalls += 1
            }
        }
        return .visitChildren
    }

    // MARK: - Unasserted Optional Unwrap Detection

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        guard currentTestFunctionName != nil, nestedScopeDepth == 0 else {
            return .visitChildren
        }

        // An environment gate is a skip, not a defect, and is claimed by the inventory
        // first — see `SemanticTestRules.isEnvironmentGate`.
        if SemanticTestRules.isEnvironmentGate(node) {
            recordSkip(
                SemanticTestRules.Skip(mechanism: .environmentGate, reason: nil),
                at: node)
            return .visitChildren
        }

        // Scoped to a `@Test` body's own scope. A helper may legitimately fall back to a
        // default; a test that falls back has silently stopped testing. Inside a closure
        // or a nested `func`, `return` leaves that scope and not the test — see
        // `nestedScopeDepth`.
        guard SemanticTestRules.isUnassertedOptionalUnwrap(node) else {
            return .visitChildren
        }

        let location = node.startLocation(converter: converter)
        let line = location.line

        if let override = scopedOverrideIfExempted(line: line, ruleId: "unasserted-optional-unwrap") {
            overrides.append(override)
            return .visitChildren
        }

        diagnostics.append(Diagnostic(
            severity: .error,
            message: "Guard binds an optional and returns without asserting. When the value is nil this test passes having run none of its assertions.",
            filePath: fileName,
            lineNumber: line,
            columnNumber: location.column,
            ruleId: "unasserted-optional-unwrap",
            suggestedFix: "If the value must exist, use try #require(...) so nil fails loudly. If its absence is a legitimate skip — an unavailable GPU, a missing fixture — move the condition into a .enabled(if:) trait, so the run is recorded as skipped instead of counted as passed."
        ))

        return .visitChildren
    }

    // MARK: - #expect / #require Macro Detection

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        let macroName = node.macroName.text
        if macroName == "expect" || macroName == "require" {
            currentTestHasAssertion = true
            currentTestShape.assertions += 1
            if node.arguments.contains(where: { $0.label?.text == "throws" }) {
                currentTestShape.assertsAThrow = true
            }

            // Analyze the arguments for anti-patterns.
            analyzeExpectArguments(node)
        }
        return .visitChildren
    }

    // MARK: - Unseeded Randomness Detection

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if node.declName.baseName.text == "random" || node.declName.baseName.text == "shuffled" {
            // Skip enum case access (e.g., PlayerType.random, AIDifficulty.random).
            // Only flag when .random/.shuffled is actually called as a function/method,
            // meaning the MemberAccessExprSyntax is the callee of a FunctionCallExprSyntax.
            guard let callExpr = node.parent?.as(FunctionCallExprSyntax.self) else {
                return .visitChildren
            }

            // Skip calls that pass a seeded generator via `using:` parameter,
            // e.g., .random(using: &rng) or .shuffled(using: &rng).
            let hasUsingArg = callExpr.arguments.contains { arg in
                arg.label?.text == "using"
            }
            guard !hasUsingArg else { return .visitChildren }

            let location = node.startLocation(
                converter: converter
            )
            let line = location.line

            if let override = overrideIfExempted(line: line, ruleId: "unseeded-random") {
                overrides.append(override)
                return .visitChildren
            }

            diagnostics.append(Diagnostic(
                severity: .warning,
                message: "Unseeded .random usage in test code. Tests must be deterministic.",
                filePath: fileName,
                lineNumber: line,
                columnNumber: location.column,
                ruleId: "unseeded-random",
                suggestedFix: "Inject a SeededGenerator or validate distributional invariants only"
            ))
        }

        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        // Not scoped to a `@Test` body: the corpus reads the calendar as a suite-level
        // property as often as inside a test, and the reading is ambient either way.
        if let ambient = SemanticTestRules.ambientCalendarReference(in: node) {
            emit(
                severity: .error,
                message: "\(ambient.reading.describedAsWritten).",
                ruleId: "ambient-calendar-in-test",
                fix: "Use a fixed calendar shared by the suite — a Calendar with an explicit timeZone, named once as a fixture — so the assertion means the same thing on every machine.",
                at: node)
        }

        if node.baseName.text == "SystemRandomNumberGenerator" {
            let location = node.startLocation(
                converter: converter
            )
            let line = location.line

            if let override = overrideIfExempted(line: line, ruleId: "unseeded-random") {
                overrides.append(override)
                return .visitChildren
            }

            diagnostics.append(Diagnostic(
                severity: .warning,
                message: "SystemRandomNumberGenerator in test code produces non-deterministic results.",
                filePath: fileName,
                lineNumber: line,
                columnNumber: location.column,
                ruleId: "unseeded-random",
                suggestedFix: "Use a SeededGenerator with a fixed seed for reproducible tests"
            ))
        }

        return .visitChildren
    }

    // MARK: - Expect Argument Analysis

    private func analyzeExpectArguments(_ node: MacroExpansionExprSyntax) {
        // Walk the argument expressions looking for anti-patterns.
        for argument in node.arguments {
            let expr = argument.expression
            analyzeExpressionForAntiPatterns(expr, in: node)
        }

        analyzeAssertedCondition(node)
    }

    /// Applies the rules that read the assertion as a *claim* rather than as syntax.
    ///
    /// Only the first argument, and only when it is unlabeled. `#expect` takes an optional
    /// trailing comment — `#expect(x == y, "the fit should converge")` — and a labelled
    /// form, `#expect(throws: MyError.self)`. Both would defeat these rules if the whole
    /// argument list were scanned: a comment string is a literal, so every commented
    /// assertion would look like `assertion-on-constant`.
    private func analyzeAssertedCondition(_ node: MacroExpansionExprSyntax) {
        guard let first = node.arguments.first, first.label == nil else { return }
        let condition = first.expression

        if let site = SemanticTestRules.coalescedLiteral(in: condition) {
            emit(
                severity: .warning,
                message: "Assertion falls back to '\(site.fallback)' when the optional is nil, so a missing value is asserted as if it were present.",
                ruleId: "coalesced-assertion",
                fix: "Bind the value first — let v = try #require(optional) — and assert on v, so absence is what fails. try #require cannot be inlined into #expect: the macro expands its condition into a non-throwing closure, so the binding must be its own statement and the enclosing function must be marked throws.",
                at: node)
        }

        if SemanticTestRules.isAssertionOnConstant(condition) {
            emit(
                severity: .warning,
                message: "Assertion compares only literals, so it passes for every possible implementation.",
                ruleId: "assertion-on-constant",
                fix: "Assert something computed by the code under test",
                at: node)
        }

        for comparison in SemanticTestRules.comparisons(in: condition) {
            analyzeComparison(comparison, in: node)
        }
    }

    /// The rules that read one comparison. A compound assertion yields several.
    private func analyzeComparison(
        _ comparison: SemanticTestRules.Comparison,
        in node: MacroExpansionExprSyntax
    ) {
        if let testName = currentTestFunctionName,
           SemanticTestRules.claimsImprovement(testName: testName),
           SemanticTestRules.isNonStrictImprovement(comparison) {
            emit(
                severity: .warning,
                message: "Test '\(testName)' claims an improvement but asserts '\(comparison.op)', which an unchanged implementation also satisfies.",
                ruleId: "non-strict-improvement",
                fix: "Assert the strict comparison, or record why a tie is legitimate with // TEST-QUALITY: non-strict-improvement — <reason>",
                at: node)
        }

        if let restated = SelfReferentialExpectation.restatedFunction(
            in: comparison, using: implementations) {
            emit(
                severity: .error,
                message: "Expected value restates the body of '\(restated)', so this assertion holds for whatever that body is.",
                ruleId: SelfReferentialExpectation.ruleId,
                fix: "Assert a value derived independently of the implementation — a worked example, a reference implementation, or a published figure",
                at: node)
        }

        if let ratio = SemanticTestRules.toleranceRatio(comparison),
           ratio > Self.toleranceRatioThreshold {
            // Rounded arithmetic rather than String(format:), which bridges to the C
            // printf ABI. One decimal place is enough to make the ratio legible.
            let percent = (ratio * 1000).rounded() / 10
            emit(
                severity: .warning,
                message: "Tolerance is \(percent)% of the magnitude it is checked against, which asserts little about the expected value.",
                ruleId: "tolerance-without-magnitude",
                fix: "Tighten the tolerance, or state the relative bound explicitly so the ratio is visible in review",
                at: node)
        }
    }

    /// The ratio above which an absolute tolerance is reported.
    ///
    /// One percent, from the proposal. It is a starting point rather than a derived value,
    /// and it is deliberately a single named constant so that changing it is one edit with
    /// one place to argue about.
    private static let toleranceRatioThreshold = 0.01

    /// Appends a diagnostic unless the line carries a suppression comment.
    private func emit(
        severity: Diagnostic.Severity,
        message: String,
        ruleId: String,
        fix: String,
        at node: some SyntaxProtocol
    ) {
        guard isEnabled(ruleId) else { return }

        let location = node.startLocation(converter: converter)
        let line = location.line

        if let override = scopedOverrideIfExempted(line: line, ruleId: ruleId) {
            overrides.append(override)
            return
        }

        diagnostics.append(Diagnostic(
            severity: severity,
            message: message,
            filePath: fileName,
            lineNumber: line,
            columnNumber: location.column,
            ruleId: ruleId,
            suggestedFix: fix
        ))
    }

    /// Analyzes expressions inside #expect for anti-patterns.
    ///
    /// Handles both `SequenceExprSyntax` (pre-fold) and `InfixOperatorExprSyntax` (post-fold)
    /// representations of binary expressions.
    ///
    /// `exact-double-equality` is deliberately absent: it is detected by
    /// `FloatingPointRules` (FloatingPointSafetyAuditor), shared with `fp-safety`. Only `weak-assertion`
    /// is decided here.
    private func analyzeExpressionForAntiPatterns(
        _ expr: ExprSyntax,
        in macroNode: MacroExpansionExprSyntax
    ) {
        // Handle SequenceExprSyntax: e.g., `result != nil`
        if let sequence = expr.as(SequenceExprSyntax.self) {
            let elements = Array(sequence.elements)

            for (index, element) in elements.enumerated() {
                // Look for binary operators
                if let binOp = element.as(BinaryOperatorExprSyntax.self) {
                    // Check for weak assertions: `!= 0` or `!= nil`
                    if binOp.operator.text == "!=" {
                        checkWeakAssertion(
                            elements: elements,
                            operatorIndex: index,
                            macroNode: macroNode
                        )
                    }
                }
            }
        }

        // Handle InfixOperatorExprSyntax (if operator folding has occurred)
        if let infix = expr.as(InfixOperatorExprSyntax.self),
           let binOp = infix.operator.as(BinaryOperatorExprSyntax.self),
           binOp.operator.text == "!=" {
            let lhs = infix.leftOperand
            let rhs = infix.rightOperand
            let rhsIsZero = rhs.as(IntegerLiteralExprSyntax.self)?.literal.text == "0"
            let rhsIsNil = rhs.is(NilLiteralExprSyntax.self)
            let lhsIsZero = lhs.as(IntegerLiteralExprSyntax.self)?.literal.text == "0"
            let lhsIsNil = lhs.is(NilLiteralExprSyntax.self)

            if rhsIsZero || rhsIsNil || lhsIsZero || lhsIsNil {
                emitWeakAssertionDiagnostic(at: macroNode)
            }
        }
    }

    private func checkWeakAssertion(
        elements: [ExprSyntax],
        operatorIndex: Int,
        macroNode: MacroExpansionExprSyntax
    ) {
        let rhsIndex = operatorIndex + 1
        let lhsIndex = operatorIndex - 1

        var isWeak = false

        // Check RHS for 0 or nil
        if rhsIndex < elements.count {
            if let intLit = elements[rhsIndex].as(IntegerLiteralExprSyntax.self),
               intLit.literal.text == "0" {
                isWeak = true
            }
            if elements[rhsIndex].is(NilLiteralExprSyntax.self) {
                isWeak = true
            }
        }

        // Check LHS for 0 or nil (reversed comparison)
        if lhsIndex >= 0 {
            if let intLit = elements[lhsIndex].as(IntegerLiteralExprSyntax.self),
               intLit.literal.text == "0" {
                isWeak = true
            }
            if elements[lhsIndex].is(NilLiteralExprSyntax.self) {
                isWeak = true
            }
        }

        if isWeak {
            emitWeakAssertionDiagnostic(at: macroNode)
        }
    }

    private func emitWeakAssertionDiagnostic(at node: some SyntaxProtocol) {
        let location = node.startLocation(
            converter: converter
        )
        let line = location.line

        if let override = overrideIfExempted(line: line, ruleId: "weak-assertion") {
            overrides.append(override)
            return
        }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Weak assertion: != 0 or != nil does not validate correctness. Assert quantitative bounds.",
            filePath: fileName,
            lineNumber: line,
            columnNumber: location.column,
            ruleId: "weak-assertion",
            suggestedFix: "Replace != 0 with a specific expected value or range check"
        ))
    }

    // MARK: - Hardcoded Date Detection

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.segments.count == 1,
              let segment = node.segments.first?.as(StringSegmentSyntax.self) else {
            return .visitChildren
        }

        let text = segment.content.text
        guard text.count == 10,
              let _ = text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) else {
            return .visitChildren
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        guard let parsedDate = fmt.date(from: text) else {
            return .visitChildren
        }

        let daysBetween = abs(Calendar.current.dateComponents(
            [.day], from: parsedDate, to: Date()
        ).day ?? 0)
        guard daysBetween <= 365 else {
            return .visitChildren
        }

        let location = node.startLocation(
            converter: converter
        )
        let line = location.line

        guard isInDefaultTimestampContext(line: line) else {
            return .visitChildren
        }

        if let override = overrideIfExempted(line: line, ruleId: "hardcoded-date") {
            overrides.append(override)
            return .visitChildren
        }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Hardcoded date \"\(text)\" in default timestamp context will drift past time windows.",
            filePath: fileName,
            lineNumber: line,
            columnNumber: location.column,
            ruleId: "hardcoded-date",
            suggestedFix: "Use Date() or Date().addingTimeInterval(...) for timestamps that represent 'recent'"
        ))

        return .visitChildren
    }

    private func isInDefaultTimestampContext(line: Int) -> Bool {
        guard line >= 1, line <= sourceLines.count else { return false }
        let lineContent = sourceLines[line - 1]
        return lineContent.contains("??")
    }

    // MARK: - Skipped Test Inventory

    /// Records a test that does not run, at `.note` severity.
    ///
    /// `.note` rather than `.warning` is the whole design of this rule. A warning gates —
    /// this package's bar is zero warnings, and `--strict` fails on them — so an inventory
    /// reported as a warning would block every commit in any repository that has ever
    /// disabled a test, which is how a rule gets switched off. A note is reported on every
    /// run and never changes the verdict, which is exactly what "a standing inventory that
    /// cannot rot quietly" asks for. A project that wants it to bite can say so:
    /// `overrides: { test-quality.skipped-test-inventory: warning }`.
    private func recordSkip(_ skip: SemanticTestRules.Skip, at node: some SyntaxProtocol) {
        let location = node.startLocation(converter: converter)
        let line = location.line

        if let override = scopedOverrideIfExempted(line: line, ruleId: "skipped-test-inventory") {
            overrides.append(override)
            return
        }

        var message = "This test does not run: \(skip.mechanism.describedAsWritten)."
        if let reason = skip.reason {
            message += " Stated reason: \"\(reason)\"."
        } else if skip.mechanism == .disabledTrait {
            message += " No reason was recorded."
        }
        // Best effort, and never part of the verdict — see `SkippedTestAge`.
        if let days = SkippedTestAge.days(path: fileName, line: line) {
            message += " Last touched \(days) day\(days == 1 ? "" : "s") ago."
        }

        diagnostics.append(Diagnostic(
            severity: .note,
            message: message,
            filePath: fileName,
            lineNumber: line,
            columnNumber: location.column,
            ruleId: "skipped-test-inventory",
            suggestedFix: "Fix and re-enable it, or delete it. A test that has not run in months is a deleted test that still costs review attention."
        ))
    }

    // MARK: - Exemption Checking

    /// A suppression that must name the rule it suppresses.
    ///
    /// The six original rules accept any marker in `exemptionPatterns` — a bare
    /// `// TEST-QUALITY:` silences whatever fires on that line. The semantic rules do not,
    /// and the reason was measured rather than assumed.
    ///
    /// BusinessMath contains 73 lines of `#expect(true) // TEST-QUALITY: <reason>`, written
    /// to get past `missing-assertion`. Every one of them is precisely what
    /// `assertion-on-constant` was built to find. Under a blanket marker, the comment
    /// excusing the first rule would have silently excused the rule designed to catch it,
    /// and the new rule would have shipped reporting zero findings on a corpus containing
    /// seventy-three — indistinguishable, from the outside, from a rule that works.
    ///
    /// This is the hazard this file already documents for `fp-safety:disable`: a marker
    /// scoped to the rule it names must not silence a different one. Naming the rule also
    /// makes the acknowledgement legible in review — `// TEST-QUALITY: non-strict-improvement
    /// — a grid optimum can legitimately tie` says which judgement was made and why.
    private func scopedOverrideIfExempted(line: Int, ruleId: String) -> DiagnosticOverride? {
        let linesToCheck = [line - 1, line]
            .filter { $0 >= 1 && $0 <= sourceLines.count }

        for lineNum in linesToCheck {
            let lineContent = sourceLines[lineNum - 1]
            guard lineContent.contains("// TEST-QUALITY:"), lineContent.contains(ruleId) else {
                continue
            }
            return DiagnosticOverride(
                ruleId: ruleId,
                justification: lineContent.trimmingCharacters(in: .whitespaces),
                filePath: fileName,
                lineNumber: line
            )
        }

        return fileScopedOverride(line: line, ruleId: ruleId)
    }

    /// The marker that suppresses a named rule for a whole file.
    ///
    /// Spelled `-FILE:` rather than `:` so it cannot be mistaken for the line-scoped marker
    /// by either a reader or `overrideIfExempted`, whose pattern is `// TEST-QUALITY:` and
    /// does not match this one.
    private static let fileMarker = "// TEST-QUALITY-FILE:"

    /// A suppression stated once for a file whose *subject* is the flagged shape.
    ///
    /// `ambient-calendar-in-test` is why this exists. A suite that exists to prove behaviour
    /// across time zones reads the ambient calendar in every test it contains, on purpose;
    /// BusinessMath's `ZoneInvariance.swift` is that file. Repeating a line marker on forty
    /// sites is the noise that gets a rule switched off, and `excludePatterns` is too blunt —
    /// it would hide every other test-quality rule in the same file, including the ones that
    /// would find a real defect there.
    ///
    /// The three properties that keep this from becoming a blanket escape hatch are the same
    /// ones ``TestQualityVisitor/scopedOverrideIfExempted(line:ruleId:)`` argues for: the
    /// marker must **name** the rule, so it cannot silence a rule its author never considered;
    /// it records an override **per suppressed site**, so the count stays visible in the
    /// report rather than collapsing to one; and it applies only to the scoped rules, never to
    /// the five syntactic ones, whose findings are defects rather than judgements.
    private func fileScopedOverride(line: Int, ruleId: String) -> DiagnosticOverride? {
        guard let marker = fileScopedMarkers.first(where: { $0.contains(ruleId) }) else {
            return nil
        }
        return DiagnosticOverride(
            ruleId: ruleId,
            justification: marker.trimmingCharacters(in: .whitespaces),
            filePath: fileName,
            lineNumber: line
        )
    }

    private func overrideIfExempted(line: Int, ruleId: String) -> DiagnosticOverride? {
        let linesToCheck = [line - 1, line]
            .filter { $0 >= 1 && $0 <= sourceLines.count }

        for lineNum in linesToCheck {
            let lineContent = sourceLines[lineNum - 1]
            for pattern in exemptionPatterns {
                if lineContent.contains(pattern) {
                    return DiagnosticOverride(
                        ruleId: ruleId,
                        justification: lineContent.trimmingCharacters(in: .whitespaces),
                        filePath: fileName,
                        lineNumber: line
                    )
                }
            }
        }

        return nil
    }
}
