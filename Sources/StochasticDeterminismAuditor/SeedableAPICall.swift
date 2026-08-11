import Foundation
import QualityGateCore
import SwiftSyntax

// MARK: - Signature

/// A callable that declares a defaulted `seed:`, as a call site would have to write it.
///
/// The name alone is not enough, and finding that out cost 42 false positives in one run.
/// BusinessMath declares `MonteCarloScenario.normal(mean:standardDeviation:numberOfScenarios:seed:)`
/// and, in an unrelated file, `ProbabilisticDriver.normal(name:mean:stdDev:)`, which has no
/// seed to omit. Matching on `normal` made every call to the second one a finding — more
/// than a quarter of the rule's output on that project, all of it wrong.
///
/// The argument labels separate them without any type information: a call can only be
/// reaching this callable if every label it writes is one this callable accepts.
struct SeedableSignature: Hashable {
    /// The name a call site writes — the type name for an initializer, the base name otherwise.
    let name: String
    /// External argument labels this callable accepts, including `seed`.
    let labels: Set<String>
}

// MARK: - Pass 1: harvest

/// Collects the names of callables that declare a defaulted `seed:` parameter.
///
/// A SwiftSyntax tree carries no type information, and this rule does not need any. The
/// question "was `seed:` omitted here?" can only be asked of a callable that *has* a
/// `seed:` to omit, and the set of those is readable straight off the declarations. So the
/// project configures the rule itself: no hand-maintained list of API names to go stale,
/// and nothing to configure when a new seedable entry point is added.
///
/// Two deliberate narrowings:
///
/// - **Only a parameter whose *external label* is `seed`.** `func run(from seed: UInt64)`
///   is called `run(from:)`; a call site cannot write `seed:` and it would be nonsense to
///   ask for it.
/// - **Only when that parameter has a default value.** `seed: UInt64? = nil` is the
///   dangerous shape precisely because omission is silent and legal — the compiler will
///   never mention it. A required `seed:` cannot be omitted without a build error, so
///   there is nothing here for a static check to add.
///
/// An initializer is recorded under its enclosing type's name, because that is what a call
/// site writes: `MonteCarloSimulation(iterations:…)`. A method or free function is recorded
/// under its own base name.
final class SeedableAPIHarvester: SyntaxVisitor {

    /// Every callable with a defaulted `seed:`, by name and accepted argument labels.
    private(set) var seedableSignatures: Set<SeedableSignature> = []

    /// Names a call site would write to reach a callable with a defaulted `seed:`.
    var seedableNames: Set<String> { Set(seedableSignatures.map(\.name)) }

    /// Enclosing type names, innermost last.
    private var typeNameStack: [String] = []

    // MARK: Type context

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        typeNameStack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { typeNameStack.removeLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        typeNameStack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { typeNameStack.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        typeNameStack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { typeNameStack.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        typeNameStack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { typeNameStack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        typeNameStack.append(baseTypeName(of: node.extendedType))
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { typeNameStack.removeLast() }

    // MARK: Declarations

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let parameters = node.signature.parameterClause.parameters
        if declaresDefaultedSeed(parameters) {
            seedableSignatures.insert(
                SeedableSignature(name: node.name.text, labels: externalLabels(of: parameters))
            )
        }
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let parameters = node.signature.parameterClause.parameters
        if declaresDefaultedSeed(parameters), let typeName = typeNameStack.last {
            seedableSignatures.insert(
                SeedableSignature(name: typeName, labels: externalLabels(of: parameters))
            )
        }
        return .visitChildren
    }

    // MARK: Helpers

    private func declaresDefaultedSeed(_ parameters: FunctionParameterListSyntax) -> Bool {
        parameters.contains { parameter in
            parameter.firstName.text == "seed" && parameter.defaultValue != nil
        }
    }

    /// External labels, skipping `_` — an unlabelled parameter constrains nothing.
    private func externalLabels(of parameters: FunctionParameterListSyntax) -> Set<String> {
        Set(parameters.map(\.firstName.text).filter { $0 != "_" })
    }

    /// Strips generic arguments and module qualification from an extended type.
    private func baseTypeName(of type: TypeSyntax) -> String {
        let text = type.trimmedDescription
        let withoutGenerics = text.split(separator: "<").first.map(String.init) ?? text
        return withoutGenerics.split(separator: ".").last.map(String.init) ?? withoutGenerics
    }
}

// MARK: - Pass 2: check

/// Flags a call to a harvested seedable API that omits `seed:`.
///
/// The defect this exists for: a test constructs a simulation, leaves the defaulted seed
/// at `nil`, and then asserts a statistical property of the draw. The assertion holds for
/// most draws and not all, so the test passes until the day it does not, and the failure
/// carries no information about the code — only about the seed nobody chose.
///
/// The existing stochastic rules cannot see this. They look for randomness *at the call
/// site*; here the call site is `MonteCarloSimulation(iterations: 100)` and every random
/// number is drawn inside the callee. There is nothing on the line to match. What is
/// wrong with the line is an argument that was never written, which is why the rule has
/// to be told what the argument would have been.
final class UnseededSeedCallVisitor: SyntaxVisitor {

    /// The rule this visitor emits.
    static let ruleId = "stochastic-unseeded-test-call"

    private let seedableSignatures: Set<SeedableSignature>
    private let filePath: String
    private let converter: SourceLocationConverter
    private let sourceLines: [String]
    private let justificationKeyword: String
    private let validator = JustificationValidator()

    /// Accumulated diagnostics from the walk.
    private(set) var diagnostics: [Diagnostic] = []

    /// Creates a visitor for the omitted-seed rule.
    /// - Parameters:
    ///   - seedableSignatures: Callables harvested from the project's own sources.
    ///   - filePath: Absolute path used in diagnostic output.
    ///   - converter: Source location converter for line/column lookup.
    ///   - sourceLines: The source split by newline, for marker lookup.
    ///   - justificationKeyword: The opt-out keyword; matches ConcurrencyAuditor's.
    init(
        seedableSignatures: Set<SeedableSignature>,
        filePath: String,
        converter: SourceLocationConverter,
        sourceLines: [String],
        justificationKeyword: String = "Justification:"
    ) {
        self.seedableSignatures = seedableSignatures
        self.filePath = filePath
        self.converter = converter
        self.sourceLines = sourceLines
        self.justificationKeyword = justificationKeyword
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let name = calleeName(of: node) else { return .visitChildren }
        guard !node.arguments.contains(where: { $0.label?.text == "seed" }) else {
            return .visitChildren
        }
        // A call with no arguments at all is a different overload — `MonteCarloSimulation()`
        // resolves to a no-argument initializer that has no `seed:` to pass. In BusinessMath
        // those calls are handles whose seed goes to `runCorrelated(…, seed:)` a line later,
        // and the rule catches that call instead. Flagging the handle would be wrong twice:
        // the advice is impossible to follow, and the seed is already there.
        guard !node.arguments.isEmpty || node.trailingClosure != nil else {
            return .visitChildren
        }
        // Every label written here must be one the seedable callable accepts, or this is a
        // different callable that happens to share a name.
        let writtenLabels = Set(node.arguments.compactMap { $0.label?.text })
        guard seedableSignatures.contains(where: { $0.name == name && writtenLabels.isSubset(of: $0.labels) }) else {
            return .visitChildren
        }

        let location = node.startLocation(converter: converter)
        emit(callee: name, line: location.line, column: location.column)
        return .visitChildren
    }

    // MARK: - Emission

    private func emit(callee: String, line: Int, column: Int) {
        let risk = "an unseeded run makes that assertion hold for most draws rather than all"

        switch markerVerdict(atLine: line) {
        case .absent:
            diagnostics.append(Diagnostic(
                severity: .warning,
                message: "`\(callee)` declares `seed:` with a default and this call omits it; \(risk). Pass a seed, or mark the test deliberately unseeded.",
                filePath: filePath,
                lineNumber: line,
                columnNumber: column,
                ruleId: Self.ruleId,
                suggestedFix: "Pass `seed:` at this call site, or add a single-line `// \(justificationKeyword) <why this test must be unseeded>` comment on the line above."
            ))
        case .inadequate(let detail):
            diagnostics.append(Diagnostic(
                severity: .warning,
                message: "`\(callee)` is called without `seed:`, and its `// \(justificationKeyword)` marker does not state a reason (\(detail)); \(risk).",
                filePath: filePath,
                lineNumber: line,
                columnNumber: column,
                ruleId: Self.ruleId,
                suggestedFix: "Pass `seed:` at this call site, or say in the `// \(justificationKeyword)` comment what this test is checking that a seed would defeat."
            ))
        case .accepted:
            break
        }
    }

    // MARK: - Opt-out

    /// What the opt-out marker on or above a call amounts to.
    private enum MarkerVerdict {
        case absent
        case inadequate(String)
        case accepted
    }

    /// Reads the opt-out marker for a call.
    ///
    /// The spelling is `ConcurrencyAuditor`'s, deliberately: `// Justification: …` inline
    /// on the line or on the line directly above, validated by the same
    /// ``JustificationValidator``. A rule people are meant to obey should not ask them to
    /// remember a second dialect of the same idea — and the reason requirement is the
    /// point. Some tests genuinely are *about* the unseeded path and must stay unseeded;
    /// a bare suppression would let every other one hide there too.
    private func markerVerdict(atLine line: Int) -> MarkerVerdict {
        guard let text = markerText(atLine: line) else { return .absent }
        switch validator.validate(text, keyword: justificationKeyword) {
        case .valid:
            return .accepted
        case .tooShort(let wordCount):
            return .inadequate("\(wordCount) word\(wordCount == 1 ? "" : "s")")
        case .generic(let phrase):
            return .inadequate("'\(phrase)' is not an explanation")
        case .duplicate:
            return .inadequate("the same text is used elsewhere")
        }
    }

    private func markerText(atLine line: Int) -> String? {
        let index = line - 1
        if index >= 0, index < sourceLines.count {
            let lineText = sourceLines[index]
            if let range = lineText.range(of: "//") {
                let comment = String(lineText[range.upperBound...])
                if comment.contains(justificationKeyword) {
                    return comment.trimmingCharacters(in: .whitespaces)
                }
            }
        }
        let above = index - 1
        if above >= 0, above < sourceLines.count {
            let previous = sourceLines[above].trimmingCharacters(in: .whitespaces)
            if previous.hasPrefix("//"), previous.contains(justificationKeyword) {
                return previous
            }
        }
        return nil
    }

    // MARK: - Callee resolution

    /// The name a call site writes, or nil when the callee is an expression we cannot name.
    private func calleeName(of call: FunctionCallExprSyntax) -> String? {
        var expression = call.calledExpression
        if let specialized = expression.as(GenericSpecializationExprSyntax.self) {
            expression = specialized.expression
        }
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text
        }
        if let member = expression.as(MemberAccessExprSyntax.self) {
            let base = member.declName.baseName.text
            // `MonteCarloSimulation.init(…)` names the type, not `init`.
            if base == "init" {
                return member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text
            }
            return base
        }
        return nil
    }
}
