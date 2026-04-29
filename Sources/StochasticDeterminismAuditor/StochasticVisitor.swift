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

    /// Whether the current enclosing function accepts an RNG parameter.
    private var functionHasRNGParameter = false

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

    // MARK: - Test File Skip

    /// Returns true if the file path indicates a test file that should be skipped.
    private var isTestFile: Bool {
        filePath.contains("/Tests/") || filePath.hasPrefix("Tests/")
    }

    // MARK: - Function Declaration Tracking

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !isTestFile else { return .skipChildren }

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
        guard !isTestFile else { return .skipChildren }

        let memberName = node.declName.baseName.text

        // Check for .random() / .random(in:)
        if memberName == "random" {
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

        // Check for .shuffled() / .shuffle() without using: parameter
        if flagCollectionShuffle && (memberName == "shuffled" || memberName == "shuffle") {
            if let parent = node.parent, parent.is(FunctionCallExprSyntax.self) {
                if let call = parent.as(FunctionCallExprSyntax.self),
                   !callHasUsingArgument(call) {
                    if !functionHasRNGParameter && !isExemptFunction() {
                        emitDiagnostic(
                            ruleId: "stochastic-collection-shuffle",
                            message: "`.\(memberName)()` called without `using:` parameter; results are non-deterministic",
                            node: Syntax(node),
                            suggestedFix: "Use `.\(memberName)(using: &rng)` with an injected RandomNumberGenerator"
                        )
                    }
                }
            }
        }

        return .visitChildren
    }

    // MARK: - Declaration Reference Detection (SystemRandomNumberGenerator, global funcs)

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        guard !isTestFile else { return .skipChildren }

        let name = node.baseName.text

        // Skip exempt references (UUID, SecRandomCopyBytes)
        if exemptReferenceNames.contains(name) {
            return .visitChildren
        }

        // Check for SystemRandomNumberGenerator
        if name == "SystemRandomNumberGenerator" {
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
                suggestedFix: "Replace with Swift's `.random(in:using:)` API and inject a `RandomNumberGenerator`"
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

        // Per-line exemption: skip if the source line contains the exempt comment
        let lineIndex = line - 1
        if lineIndex >= 0, lineIndex < sourceLines.count {
            if sourceLines[lineIndex].contains("// stochastic:exempt") {
                return
            }
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
