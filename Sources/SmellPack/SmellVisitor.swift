import Foundation
import QualityGateCore
import SwiftSyntax

/// SwiftSyntax walker computing every smell metric for one parsed file.
///
/// Purely syntactic and single-pass: parameter counts and body spans are
/// emitted at the declaration, nesting depth is emitted when the enclosing
/// function context pops, and god-object member tallies (including same-file
/// extensions) are emitted by ``finalizeGodObjects()`` after the walk.
final class SmellVisitor: SyntaxVisitor {

    private let config: SmellConfig
    private let filePath: String
    private let lines: [String]
    private let converter: SourceLocationConverter

    /// Advisory findings collected so far (unsorted; the caller sorts).
    private(set) var findings: [Diagnostic] = []
    /// Recorded `// smell:exempt` suppressions.
    private(set) var overrides: [DiagnosticOverride] = []

    /// One function body's nesting measurement in progress.
    private struct FunctionContext {
        let describedName: String
        let line: Int
        let column: Int
        var currentDepth = 0
        var maxDepth = 0
    }
    /// Innermost-last stack of function bodies being measured.
    private var functionStack: [FunctionContext] = []

    /// A nominal type declaration's location and own-body member count.
    private struct TypeTally {
        let line: Int
        let column: Int
        var memberCount: Int
    }
    /// Member tallies keyed by dot-qualified type name.
    private var typeTallies: [String: TypeTally] = [:]
    /// Declaration order of `typeTallies` keys, for deterministic output.
    private var declaredOrder: [String] = []
    /// Extension member counts keyed by the extended type's written name.
    private var extensionCounts: [String: Int] = [:]
    /// Enclosing type names, for qualifying nested declarations.
    private var typeNameStack: [String] = []

    /// Creates a visitor over one parsed source file.
    init(config: SmellConfig, filePath: String, source: String, tree: SourceFileSyntax) {
        self.config = config
        self.filePath = filePath
        self.lines = source.lines
        self.converter = SourceLocationConverter(fileName: filePath, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Functions (parameter count + nesting context)

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let location = startLocation(of: node)
        checkParameterCount(
            node.signature.parameterClause.parameters.count,
            describedName: "function '\(node.name.text)'",
            location: location)
        pushFunction(describedName: "function '\(node.name.text)'", location: location)
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) { popFunction() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let location = startLocation(of: node)
        checkParameterCount(
            node.signature.parameterClause.parameters.count,
            describedName: "initializer",
            location: location)
        pushFunction(describedName: "initializer", location: location)
        return .visitChildren
    }

    override func visitPost(_ node: InitializerDeclSyntax) { popFunction() }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        pushFunction(describedName: "deinitializer", location: startLocation(of: node))
        return .visitChildren
    }

    override func visitPost(_ node: DeinitializerDeclSyntax) { popFunction() }

    // MARK: - Nesting constructs

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        pushNesting()
        return .visitChildren
    }

    override func visitPost(_ node: IfExprSyntax) { popNesting() }

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        pushNesting()
        return .visitChildren
    }

    override func visitPost(_ node: GuardStmtSyntax) { popNesting() }

    override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
        pushNesting()
        return .visitChildren
    }

    override func visitPost(_ node: SwitchExprSyntax) { popNesting() }

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        pushNesting()
        return .visitChildren
    }

    override func visitPost(_ node: ForStmtSyntax) { popNesting() }

    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        pushNesting()
        return .visitChildren
    }

    override func visitPost(_ node: WhileStmtSyntax) { popNesting() }

    override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind {
        pushNesting()
        return .visitChildren
    }

    override func visitPost(_ node: RepeatStmtSyntax) { popNesting() }

    // MARK: - Closures (nesting + closure length)

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        pushNesting()
        let leftLine = converter.location(for: node.leftBrace.positionAfterSkippingLeadingTrivia).line
        let rightLine = converter.location(for: node.rightBrace.positionAfterSkippingLeadingTrivia).line
        let span = rightLine - leftLine + 1
        if span > config.maxClosureLength {
            let location = startLocation(of: node)
            emit(
                ruleId: "smell.closure-length",
                message: "closure body spans \(span) lines (threshold \(config.maxClosureLength))",
                line: location.line,
                column: location.column)
        }
        return .visitChildren
    }

    override func visitPost(_ node: ClosureExprSyntax) { popNesting() }

    // MARK: - Types (member tally + body length)

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        recordType(name: node.name.text, memberBlock: node.memberBlock, declaration: Syntax(node))
        typeNameStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) { _ = typeNameStack.popLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        recordType(name: node.name.text, memberBlock: node.memberBlock, declaration: Syntax(node))
        typeNameStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) { _ = typeNameStack.popLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        recordType(name: node.name.text, memberBlock: node.memberBlock, declaration: Syntax(node))
        typeNameStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: ActorDeclSyntax) { _ = typeNameStack.popLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        recordType(name: node.name.text, memberBlock: node.memberBlock, declaration: Syntax(node))
        typeNameStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) { _ = typeNameStack.popLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let target = node.extendedType.trimmedDescription
        extensionCounts[target, default: 0] += Self.memberCount(of: node.memberBlock)
        typeNameStack.append(target)
        return .visitChildren
    }

    override func visitPost(_ node: ExtensionDeclSyntax) { _ = typeNameStack.popLast() }

    // MARK: - God-object finalization

    /// Emits `smell.god-object` findings after the walk, once every same-file
    /// extension has been tallied against its type.
    func finalizeGodObjects() {
        for qualified in declaredOrder {
            guard let tally = typeTallies[qualified] else { continue }
            let total = tally.memberCount + (extensionCounts[qualified] ?? 0)
            if total > config.maxTypeMemberCount {
                emit(
                    ruleId: "smell.god-object",
                    message: "type '\(qualified)' has \(total) members (threshold \(config.maxTypeMemberCount))",
                    line: tally.line,
                    column: tally.column)
            }
        }
    }

    // MARK: - Metric helpers

    /// The declaration-start location (after leading trivia) of a node.
    private func startLocation(of node: some SyntaxProtocol) -> SourceLocation {
        converter.location(for: node.positionAfterSkippingLeadingTrivia)
    }

    /// Flags a parameter list strictly over the configured maximum.
    private func checkParameterCount(_ count: Int, describedName: String, location: SourceLocation) {
        guard count > config.maxParameterCount else { return }
        emit(
            ruleId: "smell.parameter-count",
            message: "\(describedName) has \(count) parameters (threshold \(config.maxParameterCount))",
            line: location.line,
            column: location.column)
    }

    /// Opens a nesting-measurement context for a function-like body.
    private func pushFunction(describedName: String, location: SourceLocation) {
        functionStack.append(FunctionContext(
            describedName: describedName,
            line: location.line,
            column: location.column))
    }

    /// Closes the innermost function context, flagging over-threshold depth.
    private func popFunction() {
        guard let context = functionStack.popLast() else { return }
        if context.maxDepth > config.maxNestingDepth {
            emit(
                ruleId: "smell.nesting-depth",
                message: "\(context.describedName) reaches nesting depth \(context.maxDepth) (threshold \(config.maxNestingDepth))",
                line: context.line,
                column: context.column)
        }
    }

    /// Deepens the innermost function context by one nesting level.
    ///
    /// Balanced with ``popNesting()`` by syntax-tree structure: functions
    /// pushed inside a construct are always popped before the construct is.
    private func pushNesting() {
        guard !functionStack.isEmpty else { return }
        let index = functionStack.count - 1
        functionStack[index].currentDepth += 1
        functionStack[index].maxDepth = max(functionStack[index].maxDepth, functionStack[index].currentDepth)
    }

    /// Shallows the innermost function context by one nesting level.
    private func popNesting() {
        guard !functionStack.isEmpty else { return }
        let index = functionStack.count - 1
        if functionStack[index].currentDepth > 0 {
            functionStack[index].currentDepth -= 1
        }
    }

    /// Tallies a nominal type's own members and flags an over-long body.
    private func recordType(name: String, memberBlock: MemberBlockSyntax, declaration: Syntax) {
        let qualified = (typeNameStack + [name]).joined(separator: ".")
        let location = startLocation(of: declaration)
        let ownCount = Self.memberCount(of: memberBlock)

        if var existing = typeTallies[qualified] {
            // Duplicate declarations of one name in a file: merge tallies.
            existing.memberCount += ownCount
            typeTallies[qualified] = existing
        } else {
            typeTallies[qualified] = TypeTally(
                line: location.line,
                column: location.column,
                memberCount: ownCount)
            declaredOrder.append(qualified)
        }

        let leftLine = converter.location(for: memberBlock.leftBrace.positionAfterSkippingLeadingTrivia).line
        let rightLine = converter.location(for: memberBlock.rightBrace.positionAfterSkippingLeadingTrivia).line
        let span = rightLine - leftLine + 1
        if span > config.maxTypeBodyLength {
            emit(
                ruleId: "smell.type-length",
                message: "type '\(qualified)' body spans \(span) lines (threshold \(config.maxTypeBodyLength))",
                line: location.line,
                column: location.column)
        }
    }

    /// Counts the members of one member block: stored/computed property
    /// bindings, enum-case elements, methods, initializers, deinitializers,
    /// subscripts, and nested type declarations.
    static func memberCount(of memberBlock: MemberBlockSyntax) -> Int {
        var count = 0
        for item in memberBlock.members {
            let decl = item.decl
            if let variable = decl.as(VariableDeclSyntax.self) {
                count += variable.bindings.count
            } else if let enumCase = decl.as(EnumCaseDeclSyntax.self) {
                count += enumCase.elements.count
            } else if decl.is(FunctionDeclSyntax.self)
                || decl.is(InitializerDeclSyntax.self)
                || decl.is(DeinitializerDeclSyntax.self)
                || decl.is(SubscriptDeclSyntax.self)
                || decl.is(StructDeclSyntax.self)
                || decl.is(ClassDeclSyntax.self)
                || decl.is(ActorDeclSyntax.self)
                || decl.is(EnumDeclSyntax.self)
                || decl.is(TypeAliasDeclSyntax.self) {
                count += 1
            }
        }
        return count
    }

    // MARK: - Emission (exemption-aware)

    /// Emits an advisory `.note`, unless the flagged declaration's line
    /// carries `// smell:exempt` — then the suppression is recorded as a
    /// ``DiagnosticOverride`` instead. Recorded, never silent.
    private func emit(ruleId: String, message: String, line: Int, column: Int) {
        if line >= 1, line <= lines.count, lines[line - 1].contains("// smell:exempt") {
            overrides.append(DiagnosticOverride(
                ruleId: ruleId,
                justification: "// smell:exempt",
                filePath: filePath,
                lineNumber: line))
            return
        }
        findings.append(Diagnostic(
            severity: .note,
            message: message,
            filePath: filePath,
            lineNumber: line,
            columnNumber: column,
            ruleId: ruleId))
    }
}
