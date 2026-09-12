import Foundation
import QualityGateCore
import SwiftSyntax

// MARK: - Constants

/// C-style global random functions that introduce hidden shared state.
private let globalRandomFunctions: Set<String> = [
    "drand48", "srand48", "arc4random", "arc4random_uniform"
]

/// Names that look like randomness but are exempt (crypto or identity).
private let exemptReferenceNames: Set<String> = [
    "UUID", "SecRandomCopyBytes"
]

// MARK: - Visitor

/// Walks a Swift syntax tree looking for non-deterministic randomness usage.
///
/// Detects three classes of problems:
/// - **stochastic-no-seed**: Calls to `.random()`, `.random(in:)`, or
///   `SystemRandomNumberGenerator` inside a function that does not accept
///   a generic `RandomNumberGenerator` parameter.
/// - **stochastic-global-state**: Direct use of C-style global random
///   functions (`drand48`, `srand48`, `arc4random`, `arc4random_uniform`).
/// - **stochastic-collection-shuffle**: Calls to `.shuffled()` or
///   `.shuffle()` without a `using:` argument.
///
/// Functions that accept `inout some RandomNumberGenerator` (or a generic
/// constrained to `RandomNumberGenerator`) are considered seed-injectable
/// and are not flagged.
final class StochasticVisitor: SyntaxVisitor {
    let filePath: String
    let converter: SourceLocationConverter
    let sourceLines: [String]
    let flagCollectionShuffle: Bool
    let flagGlobalState: Bool
    let exemptFunctions: Set<String>

    /// Accumulated diagnostics from the walk.
    private(set) var diagnostics: [Diagnostic] = []

    /// The per-line suppression marker this visitor honours.
    ///
    /// Spelled here rather than configured: it is the token this auditor's own documentation
    /// and every existing call site already use, and a renameable suppression keyword would let
    /// a project rename its way out of the rule.
    static let exemptKeyword = "stochastic:exempt"

    /// Lines already reported for carrying a marker with no reason.
    ///
    /// The missing reason belongs to the marker, not to each finding it silences, so a line
    /// suppressing three diagnostics is still one omission.
    private var bareExemptLines: Set<Int> = []

    /// Whether the current enclosing function accepts an RNG parameter.
    private var functionHasRNGParameter = false

    /// Whether this file declares a type marked `@main`.
    ///
    /// Set during the walk rather than read from the path, because `@main` is how a program
    /// names its entry point when that entry point is not in `main.swift`.
    private var declaresMainAttribute = false

    /// Stack tracking nested function declarations and their RNG status.
    private var rngParameterStack: [Bool] = []

    /// Name of the current enclosing function (for exempt-function checks).
    private var currentFunctionName: String?

    /// Stack of function names for nested functions.
    private var functionNameStack: [String?] = []

    /// Creates a new stochastic determinism visitor.
    /// - Parameters:
    ///   - filePath: Absolute path used in diagnostic output.
    ///   - converter: Source location converter for line/column lookup.
    ///   - sourceLines: The source split by newline, for per-line exempt checks.
    ///   - flagCollectionShuffle: Whether to apply the `stochastic-collection-shuffle` rule.
    ///   - flagGlobalState: Whether to apply the `stochastic-global-state` rule.
    ///   - exemptFunctions: Function names exempt from the seed requirement.
    init(
        filePath: String,
        converter: SourceLocationConverter,
        sourceLines: [String],
        flagCollectionShuffle: Bool = true,
        flagGlobalState: Bool = true,
        exemptFunctions: Set<String> = []
    ) {
        self.filePath = filePath
        self.converter = converter
        self.sourceLines = sourceLines
        self.flagCollectionShuffle = flagCollectionShuffle
        self.flagGlobalState = flagGlobalState
        self.exemptFunctions = exemptFunctions
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Test Context

    /// Whether this file lives under `Tests/`.
    ///
    /// This used to be a skip: every visitor method returned `.skipChildren` for a test
    /// file, so none of the three rules could see test code at all. It is now a *register*
    /// switch and a narrow division of labour, because two things are true at once:
    ///
    /// - A test is exactly as capable of being non-deterministic as production code, and
    ///   `stochastic-global-state` and the in-place `.shuffle()` spelling are audited by
    ///   nothing else anywhere in the gate.
    /// - `TestQualityAuditor`'s `unseeded-random` already claims `.random(…)`,
    ///   `.shuffled(…)` and `SystemRandomNumberGenerator` inside `Tests/`, at the same
    ///   severity. Firing here as well would put two warnings on one line and teach people
    ///   to read past both.
    ///
    /// So in a test file this auditor emits only what `unseeded-random` does not, and the
    /// advice it does emit is rewritten: "accept an RNG parameter" is guidance a `@Test`
    /// function cannot follow, since it has no caller to inject one. A test seeds its own.
    var isTestFile: Bool {
        filePath.contains("/Tests/") || filePath.hasPrefix("Tests/")
    }

    /// Whether this file is a program's entry point.
    ///
    /// **Why the generator rule stops here.** The rule is that a function must not silently
    /// depend on ambient randomness — it should take a generator, so a caller can inject one.
    /// That rule has an end: injection terminates at the entry point, which by definition has
    /// no caller to inject anything.
    ///
    /// `SystemRandomNumberGenerator` is the standard library's only concrete
    /// `RandomNumberGenerator`, and it is deliberately unseedable because unpredictability is
    /// its contract. So a program needing real randomness — session tokens, salts, challenges —
    /// must name it once, somewhere, and no restructuring makes that line disappear. Reporting
    /// it told a correctly-built program to do something impossible, and the advice offered,
    /// *"accept an RNG parameter instead"*, is not something `main.swift` can act on.
    ///
    /// Matched exactly, on the file name alone: `mainViewModel.swift` is not an entry point,
    /// and a substring test would turn this into a way to opt out by choosing a filename.
    var isCompositionRoot: Bool {
        (filePath as NSString).lastPathComponent == "main.swift" || declaresMainAttribute
    }

    // MARK: - Entry Point Detection

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        noteMainAttribute(node.attributes)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        noteMainAttribute(node.attributes)
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        noteMainAttribute(node.attributes)
        return .visitChildren
    }

    /// Records that this file declares the program's entry point.
    ///
    /// Set on the way *down*, so a `SystemRandomNumberGenerator` inside the `@main` type is
    /// reached after the attribute has been seen. A file whose `@main` type appears below some
    /// other declaration that names the generator would still report that one — which is the
    /// right answer, since it is not in the entry point.
    private func noteMainAttribute(_ attributes: AttributeListSyntax) {
        for attribute in attributes {
            guard case .attribute(let value) = attribute,
                  value.attributeName.trimmedDescription == "main" else { continue }
            declaresMainAttribute = true
            return
        }
    }

    // MARK: - Function Declaration Tracking

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        // Save current state on stack
        rngParameterStack.append(functionHasRNGParameter)
        functionNameStack.append(currentFunctionName)

        // Determine if this function has an RNG parameter
        let hasRNG = functionHasRandomNumberGeneratorParameter(node)
        functionHasRNGParameter = hasRNG

        // Track the function name for exemption checks
        currentFunctionName = node.name.text

        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        // Restore previous state
        functionHasRNGParameter = rngParameterStack.popLast() ?? false
        currentFunctionName = functionNameStack.popLast() ?? nil
    }

    // MARK: - Member Access Detection (.random, .shuffled, .shuffle)

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let memberName = node.declName.baseName.text

        // Check for .random() / .random(in:).
        // Ceded to TestQualityAuditor's `unseeded-random` inside Tests/.
        if memberName == "random", !isTestFile {
            // Only flag if the member access is part of a function call
            if let parent = node.parent, parent.is(FunctionCallExprSyntax.self) {
                // Check if this call has a `using:` argument (seed-injected)
                if let call = parent.as(FunctionCallExprSyntax.self),
                   callHasUsingArgument(call) {
                    return .visitChildren
                }

                if !functionHasRNGParameter && !isExemptFunction() {
                    emitDiagnostic(
                        ruleId: "stochastic-no-seed",
                        message: "`.random()` called without seed injection; enclosing function should accept `inout some RandomNumberGenerator`",
                        node: Syntax(node),
                        suggestedFix: "Add `using rng: inout some RandomNumberGenerator` parameter to the enclosing function"
                    )
                }
            }
        }

        // Check for .shuffled() / .shuffle() without using: parameter.
        // Skip rng.shuffle(&collection) — the inout argument means the receiver is an RNG, not a collection.
        //
        // Inside Tests/, only the in-place `shuffle` spelling is ours: `unseeded-random`
        // matches the literal name "shuffled" and so misses `shuffle` entirely.
        let shuffleSpellingIsOurs = isTestFile ? (memberName == "shuffle") : (memberName == "shuffled" || memberName == "shuffle")
        if flagCollectionShuffle && shuffleSpellingIsOurs {
            if let parent = node.parent, parent.is(FunctionCallExprSyntax.self) {
                if let call = parent.as(FunctionCallExprSyntax.self),
                   !callHasUsingArgument(call),
                   !callHasInoutArgument(call) {
                    if !functionHasRNGParameter && !isExemptFunction() {
                        emitDiagnostic(
                            ruleId: "stochastic-collection-shuffle",
                            message: "`.\(memberName)()` called without `using:` parameter; results are non-deterministic",
                            node: Syntax(node),
                            suggestedFix: isTestFile
                                ? "Use `.\(memberName)(using: &rng)` with a generator the test seeds itself"
                                : "Use `.\(memberName)(using: &rng)` with an injected RandomNumberGenerator"
                        )
                    }
                }
            }
        }

        return .visitChildren
    }

    // MARK: - Declaration Reference Detection (SystemRandomNumberGenerator, global funcs)

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text

        // Skip exempt references (UUID, SecRandomCopyBytes)
        if exemptReferenceNames.contains(name) {
            return .visitChildren
        }

        // Check for SystemRandomNumberGenerator.
        // Ceded to TestQualityAuditor's `unseeded-random` inside Tests/.
        // Exempt in a composition root, and **only** this rule is. An unseeded `.random()`
        // in `main.swift` is still a dependency on ambient randomness that nothing can
        // reproduce; what is permitted here is naming the production generator, which is what
        // an entry point is for.
        if name == "SystemRandomNumberGenerator", !isTestFile, !isCompositionRoot {
            if !functionHasRNGParameter && !isExemptFunction() {
                emitDiagnostic(
                    ruleId: "stochastic-no-seed",
                    message: "`SystemRandomNumberGenerator` used directly; enclosing function should accept `inout some RandomNumberGenerator`",
                    node: Syntax(node),
                    suggestedFix: "Accept a generic `RandomNumberGenerator` parameter instead of using `SystemRandomNumberGenerator` directly"
                )
            }
        }

        // Check for global C-style random functions
        if flagGlobalState && globalRandomFunctions.contains(name) {
            emitDiagnostic(
                ruleId: "stochastic-global-state",
                message: "`\(name)` uses global mutable state; prefer `RandomNumberGenerator`-based APIs",
                node: Syntax(node),
                suggestedFix: isTestFile
                    ? "Replace with Swift's `.random(in:using:)` API and a generator the test seeds itself"
                    : "Replace with Swift's `.random(in:using:)` API and inject a `RandomNumberGenerator`"
            )
        }

        return .visitChildren
    }

    // MARK: - Helpers

    /// Checks whether a function declaration accepts a `RandomNumberGenerator` parameter.
    ///
    /// Detects these patterns:
    /// - `inout some RandomNumberGenerator`
    /// - `inout G` where `G: RandomNumberGenerator` (generic constraint)
    /// - Any parameter whose type text contains `RandomNumberGenerator`
    private func functionHasRandomNumberGeneratorParameter(_ node: FunctionDeclSyntax) -> Bool {
        let parameterList = node.signature.parameterClause.parameters

        // Check parameter types for RandomNumberGenerator
        for param in parameterList {
            let typeText = param.type.trimmedDescription
            if typeText.contains("RandomNumberGenerator") {
                return true
            }
        }

        // Check generic where clause constraints
        if let genericWhereClause = node.genericWhereClause {
            for requirement in genericWhereClause.requirements {
                let reqText = requirement.trimmedDescription
                if reqText.contains("RandomNumberGenerator") {
                    return true
                }
            }
        }

        // Check generic parameter clause constraints (e.g., <G: RandomNumberGenerator>)
        if let genericParamClause = node.genericParameterClause {
            for param in genericParamClause.parameters {
                if let inheritedType = param.inheritedType {
                    if inheritedType.trimmedDescription.contains("RandomNumberGenerator") {
                        return true
                    }
                }
            }
        }

        return false
    }

    /// Returns true if a function call has a `using:` argument label.
    private func callHasUsingArgument(_ call: FunctionCallExprSyntax) -> Bool {
        call.arguments.contains { arg in
            arg.label?.text == "using"
        }
    }

    private func callHasInoutArgument(_ call: FunctionCallExprSyntax) -> Bool {
        call.arguments.contains { arg in
            arg.expression.is(InOutExprSyntax.self)
        }
    }

    /// Returns true if the current function is in the exempt list.
    private func isExemptFunction() -> Bool {
        guard let name = currentFunctionName else { return false }
        return exemptFunctions.contains(name)
    }

    /// Emits a diagnostic if the line does not contain a stochastic:exempt comment.
    private func emitDiagnostic(
        ruleId: String,
        message: String,
        node: Syntax,
        suggestedFix: String? = nil
    ) {
        let location = node.startLocation(converter: converter)
        let line = location.line
        let column = location.column

        // Per-line exemption. A marker still suppresses whatever it was written to suppress —
        // no gate that passes today starts failing — but one that states no reason is itself
        // reported, so the two populations become distinguishable without reading every site
        // by hand. See `ExemptMarker`.
        let lineIndex = line - 1
        if lineIndex >= 0, lineIndex < sourceLines.count,
           let marker = ExemptMarker.parse(
            line: sourceLines[lineIndex], keyword: Self.exemptKeyword) {
            if !marker.hasJustification, bareExemptLines.insert(line).inserted {
                // One report per line, not one per suppressed finding: the missing reason is a
                // property of the marker, and a line silencing three findings has one marker.
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "`\(Self.exemptKeyword)` states no reason. A marker that costs "
                        + "nothing to write cannot be told apart from a considered decision.",
                    filePath: filePath,
                    lineNumber: line,
                    columnNumber: column,
                    ruleId: "stochastic.exempt-no-justification",
                    suggestedFix: "Say why the unseeded randomness is intentional, e.g. "
                        + "`// \(Self.exemptKeyword) — the documented unseeded path; pass "
                        + "`seed:` for reproducibility`."))
            }
            return
        }

        diagnostics.append(
            Diagnostic(
                severity: .warning,
                message: message,
                filePath: filePath,
                lineNumber: line,
                columnNumber: column,
                ruleId: ruleId,
                suggestedFix: suggestedFix
            )
        )
    }
}
