import Foundation
import QualityGateCore
import SwiftSyntax

// MARK: - Isolation context

enum IsolationContext: Equatable {
    case none
    case mainActor
    case actor(name: String)

    var isIsolated: Bool {
        switch self {
        case .none: return false
        case .mainActor, .actor: return true
        }
    }
}

// MARK: - Visitor

/// The single visitor that walks a Swift source file, tracks isolation context,
/// and applies all eight ConcurrencyAuditor rules.
final class ConcurrencyVisitor: SyntaxVisitor {
    let fileName: String
    let converter: SourceLocationConverter
    let sourceLines: [String]
    let firstPartyModules: Set<String>
    let allowPreconcurrencyImports: Set<String>
    let justificationKeyword: String

    private(set) var diagnostics: [Diagnostic] = []
    private(set) var overrides: [DiagnosticOverride] = []

    /// Stack of isolation contexts, one per nested decl.
    private var isolationStack: [IsolationContext] = [.none]
    /// Stack of stored property name sets, one per nested type/extension.
    private var storedPropertyStack: [Set<String>] = []
    /// Stack of "is this enclosing type @MainActor" flags, used by deinit rule.
    private var typeIsolationStack: [IsolationContext] = []

    init(
        fileName: String,
        converter: SourceLocationConverter,
        sourceLines: [String],
        firstPartyModules: Set<String>,
        allowPreconcurrencyImports: Set<String>,
        justificationKeyword: String
    ) {
        self.fileName = fileName
        self.converter = converter
        self.sourceLines = sourceLines
        self.firstPartyModules = firstPartyModules
        self.allowPreconcurrencyImports = allowPreconcurrencyImports
        self.justificationKeyword = justificationKeyword
        super.init(viewMode: .sourceAccurate)
    }

    private var currentIsolation: IsolationContext { isolationStack.last ?? .none }
    private var currentTypeIsolation: IsolationContext { typeIsolationStack.last ?? .none }
    private var currentStoredProperties: Set<String> { storedPropertyStack.last ?? [] }

    // MARK: Type decls

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let isolation: IsolationContext = hasMainActorAttribute(node.attributes) ? .mainActor : .none
        isolationStack.append(isolation)
        typeIsolationStack.append(isolation)
        storedPropertyStack.append(collectStoredProperties(memberBlock: node.memberBlock))

        // Rule: @unchecked Sendable on class
        checkUncheckedSendableInheritance(node.inheritanceClause, declStartLine: startLine(of: Syntax(node)))
        // Rule: Sendable class with mutable state / non-Sendable property
        if hasPlainSendableInheritance(node.inheritanceClause) {
            checkSendableClassMembers(memberBlock: node.memberBlock)
        }
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) {
        isolationStack.removeLast()
        typeIsolationStack.removeLast()
        storedPropertyStack.removeLast()
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let isolation: IsolationContext = hasMainActorAttribute(node.attributes) ? .mainActor : .none
        isolationStack.append(isolation)
        typeIsolationStack.append(isolation)
        storedPropertyStack.append(collectStoredProperties(memberBlock: node.memberBlock))
        checkUncheckedSendableInheritance(node.inheritanceClause, declStartLine: startLine(of: Syntax(node)))
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) {
        isolationStack.removeLast()
        typeIsolationStack.removeLast()
        storedPropertyStack.removeLast()
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let isolation: IsolationContext = hasMainActorAttribute(node.attributes) ? .mainActor : .none
        isolationStack.append(isolation)
        typeIsolationStack.append(isolation)
        storedPropertyStack.append([])
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) {
        isolationStack.removeLast()
        typeIsolationStack.removeLast()
        storedPropertyStack.removeLast()
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        let isolation = IsolationContext.actor(name: node.name.text)
        isolationStack.append(isolation)
        typeIsolationStack.append(isolation)
        storedPropertyStack.append(collectStoredProperties(memberBlock: node.memberBlock))
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) {
        isolationStack.removeLast()
        typeIsolationStack.removeLast()
        storedPropertyStack.removeLast()
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let isolation: IsolationContext = hasMainActorAttribute(node.attributes) ? .mainActor : .none
        isolationStack.append(isolation)
        typeIsolationStack.append(isolation)
        storedPropertyStack.append([])
        checkUncheckedSendableInheritance(node.inheritanceClause, declStartLine: startLine(of: Syntax(node)))
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) {
        isolationStack.removeLast()
        typeIsolationStack.removeLast()
        storedPropertyStack.removeLast()
    }

    // MARK: Function-level decls (inherit isolation unless explicit)

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let isolation: IsolationContext = hasMainActorAttribute(node.attributes) ? .mainActor : currentIsolation
        isolationStack.append(isolation)
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) {
        isolationStack.removeLast()
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        isolationStack.append(currentIsolation)
        return .visitChildren
    }
    override func visitPost(_ node: InitializerDeclSyntax) {
        isolationStack.removeLast()
    }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        isolationStack.append(currentIsolation)
        // Rule: @MainActor deinit touches state
        if currentTypeIsolation == .mainActor, let body = node.body {
            checkDeinitTouchesState(body: body, declStartLine: startLine(of: Syntax(node)))
        }
        return .visitChildren
    }
    override func visitPost(_ node: DeinitializerDeclSyntax) {
        isolationStack.removeLast()
    }

    // MARK: Variable / accessor

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        // Rule: nonisolated(unsafe)
        if hasNonisolatedUnsafeModifier(node.modifiers) {
            let line = startLine(of: Syntax(node))
            if let override = overrideIfJustified(line: line, ruleId: "concurrency.nonisolated-unsafe-no-justification") {
                overrides.append(override)
            } else {
                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: "nonisolated(unsafe) requires a justification comment explaining why this is safe",
                    filePath: fileName,
                    lineNumber: line,
                    columnNumber: 1,
                    ruleId: "concurrency.nonisolated-unsafe-no-justification",
                    suggestedFix: "Add a // \(justificationKeyword) ... comment on the line directly above."
                ))
            }
        }
        return .visitChildren
    }

    // MARK: Function call expressions (Task / DispatchQueue)

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // Rule: Task { ... } captures self in actor / @MainActor context
        if currentIsolation.isIsolated, isTaskCall(node) {
            if let closure = trailingClosureBody(of: node) {
                if closureCapturesEnclosingSelf(body: closure, storedProperties: currentStoredProperties) {
                    let line = startLine(of: Syntax(node))
                    diagnostics.append(Diagnostic(
                        severity: .error,
                        message: "Task closure captures isolated state without an explicit isolation hop; use 'await self.method()' instead",
                        filePath: fileName,
                        lineNumber: line,
                        columnNumber: 1,
                        ruleId: "concurrency.task-captures-self-no-isolation",
                        suggestedFix: "Replace direct property access with an awaited isolated method call."
                    ))
                }
            }
        }
        // Rule: DispatchQueue inside actor isolation
        if currentIsolation.isIsolated, isDispatchQueueAsyncCall(node) {
            let line = startLine(of: Syntax(node))
            diagnostics.append(Diagnostic(
                severity: .error,
                message: "DispatchQueue used inside actor-isolated context; prefer await MainActor.run or stay on-actor",
                filePath: fileName,
                lineNumber: line,
                columnNumber: 1,
                ruleId: "concurrency.dispatch-queue-in-actor",
                suggestedFix: "Use await MainActor.run { ... } or refactor to remain on the actor."
            ))
        }
        return .visitChildren
    }

    // MARK: Imports

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        // Rule: @preconcurrency import of first-party module
        guard hasPreconcurrencyAttribute(node.attributes) else { return .visitChildren }
        guard let firstComponent = node.path.first?.name.text else { return .visitChildren }
        if firstPartyModules.contains(firstComponent),
           !allowPreconcurrencyImports.contains(firstComponent) {
            let line = startLine(of: Syntax(node))
            diagnostics.append(Diagnostic(
                severity: .error,
                message: "@preconcurrency import of first-party module '\(firstComponent)' should be removed; fix the underlying concurrency issues instead",
                filePath: fileName,
                lineNumber: line,
                columnNumber: 1,
                ruleId: "concurrency.preconcurrency-first-party-import",
                suggestedFix: "Remove the @preconcurrency attribute and resolve the strict-concurrency warnings in '\(firstComponent)'."
            ))
        }
        return .visitChildren
    }

    // MARK: - Per-rule helpers

    private func checkUncheckedSendableInheritance(_ clause: InheritanceClauseSyntax?, declStartLine: Int) {
        guard let clause else { return }
        for inherited in clause.inheritedTypes {
            let text = inherited.type.trimmedDescription
            if text.contains("@unchecked") && text.contains("Sendable") {
                if let override = overrideIfJustified(line: declStartLine, ruleId: "concurrency.unchecked-sendable-no-justification") {
                    overrides.append(override)
                } else {
                    diagnostics.append(Diagnostic(
                        severity: .error,
                        message: "@unchecked Sendable requires a justification comment explaining why this is safe",
                        filePath: fileName,
                        lineNumber: declStartLine,
                        columnNumber: 1,
                        ruleId: "concurrency.unchecked-sendable-no-justification",
                        suggestedFix: "Add a // \(justificationKeyword) ... comment on the line directly above."
                    ))
                }
                return
            }
        }
    }

    private func hasPlainSendableInheritance(_ clause: InheritanceClauseSyntax?) -> Bool {
        guard let clause else { return false }
        for inherited in clause.inheritedTypes {
            let text = inherited.type.trimmedDescription
            if text == "Sendable" { return true }
        }
        return false
    }

    private func checkSendableClassMembers(memberBlock: MemberBlockSyntax) {
        for member in memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            // Skip computed properties (have accessor block).
            for binding in varDecl.bindings {
                let isStored = binding.accessorBlock == nil
                guard isStored else { continue }
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                let name = pattern.identifier.text
                let line = startLine(of: Syntax(binding))

                let isVar = varDecl.bindingSpecifier.text == "var"
                if isVar {
                    diagnostics.append(Diagnostic(
                        severity: .error,
                        message: "Sendable class has mutable stored property '\(name)'; declare it 'let' or use @unchecked Sendable with a justification",
                        filePath: fileName,
                        lineNumber: line,
                        columnNumber: 1,
                        ruleId: "concurrency.sendable-class-mutable-state",
                        suggestedFix: "Make '\(name)' immutable, or move synchronization out of band."
                    ))
                } else {
                    // let property: check if it's a non-Sendable closure type
                    if let typeAnnotation = binding.typeAnnotation,
                       isNonSendableClosureType(typeAnnotation.type) {
                        diagnostics.append(Diagnostic(
                            severity: .error,
                            message: "Sendable class has stored closure property '\(name)' that is not @Sendable",
                            filePath: fileName,
                            lineNumber: line,
                            columnNumber: 1,
                            ruleId: "concurrency.sendable-class-non-sendable-property",
                            suggestedFix: "Mark the closure type as @Sendable, or store a Sendable wrapper instead."
                        ))
                    }
                }
            }
        }
    }

    private func isNonSendableClosureType(_ type: TypeSyntax) -> Bool {
        if let attributed = type.as(AttributedTypeSyntax.self) {
            // If marked @Sendable, do not flag.
            for attr in attributed.attributes {
                if let attribute = attr.as(AttributeSyntax.self),
                   attribute.attributeName.trimmedDescription == "Sendable" {
                    return false
                }
            }
            return attributed.baseType.is(FunctionTypeSyntax.self)
        }
        return type.is(FunctionTypeSyntax.self)
    }

    private func checkDeinitTouchesState(body: CodeBlockSyntax, declStartLine: Int) {
        let propertyNames = currentStoredProperties
        guard !propertyNames.isEmpty else { return }

        final class Walker: SyntaxVisitor {
            let names: Set<String>
            var found = false
            init(names: Set<String>) {
                self.names = names
                super.init(viewMode: .sourceAccurate)
            }
            override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
                if names.contains(node.baseName.text) {
                    found = true
                }
                return .skipChildren
            }
            override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
                // Exclude Self.x (static)
                if let base = node.base, base.trimmedDescription == "Self" {
                    return .skipChildren
                }
                // self.x or implicit
                if names.contains(node.declName.baseName.text) {
                    if let base = node.base, base.trimmedDescription == "self" {
                        found = true
                    }
                }
                return .visitChildren
            }
        }
        let walker = Walker(names: propertyNames)
        walker.walk(body)
        if walker.found {
            diagnostics.append(Diagnostic(
                severity: .error,
                message: "@MainActor class deinit touches isolated stored state; deinit is non-isolated in Swift 6 and will trap at runtime",
                filePath: fileName,
                lineNumber: declStartLine,
                columnNumber: 1,
                ruleId: "concurrency.main-actor-deinit-touches-state",
                suggestedFix: "Move cleanup that touches isolated state into an explicit isolated method called before deallocation."
            ))
        }
    }

    private func isTaskCall(_ call: FunctionCallExprSyntax) -> Bool {
        guard let ident = call.calledExpression.as(DeclReferenceExprSyntax.self) else { return false }
        return ident.baseName.text == "Task"
    }

    private func trailingClosureBody(of call: FunctionCallExprSyntax) -> CodeBlockItemListSyntax? {
        if let trailing = call.trailingClosure {
            return trailing.statements
        }
        return nil
    }

    private func closureCapturesEnclosingSelf(body: CodeBlockItemListSyntax, storedProperties: Set<String>) -> Bool {
        final class Walker: SyntaxVisitor {
            let names: Set<String>
            var found = false
            init(names: Set<String>) {
                self.names = names
                super.init(viewMode: .sourceAccurate)
            }
            override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind {
                // Properly hopped — skip the entire await subtree.
                return .skipChildren
            }
            override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                // Skip nested Task calls — they get their own diagnostic at their own visit.
                if let ident = node.calledExpression.as(DeclReferenceExprSyntax.self),
                   ident.baseName.text == "Task" {
                    return .skipChildren
                }
                return .visitChildren
            }
            override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
                if let base = node.base, base.trimmedDescription == "self" {
                    found = true
                }
                return .visitChildren
            }
            override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
                if names.contains(node.baseName.text) {
                    found = true
                }
                return .visitChildren
            }
        }
        let walker = Walker(names: storedProperties)
        walker.walk(body)
        return walker.found
    }

    private func isDispatchQueueAsyncCall(_ call: FunctionCallExprSyntax) -> Bool {
        // Match `DispatchQueue.<chain>.async { }` or .sync { }
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self) else { return false }
        let methodName = member.declName.baseName.text
        guard methodName == "async" || methodName == "sync" || methodName == "asyncAfter" else { return false }
        // Walk back through the receiver chain to find DispatchQueue at the root.
        var current: ExprSyntax? = member.base
        while let expr = current {
            if let ident = expr.as(DeclReferenceExprSyntax.self), ident.baseName.text == "DispatchQueue" {
                return true
            }
            if let inner = expr.as(MemberAccessExprSyntax.self) {
                current = inner.base
                continue
            }
            if let funcCall = expr.as(FunctionCallExprSyntax.self) {
                if let calleeMember = funcCall.calledExpression.as(MemberAccessExprSyntax.self) {
                    current = calleeMember.base
                    continue
                }
                if let calleeIdent = funcCall.calledExpression.as(DeclReferenceExprSyntax.self),
                   calleeIdent.baseName.text == "DispatchQueue" {
                    return true
                }
                return false
            }
            return false
        }
        return false
    }

    // MARK: - Source-level helpers

    private func startLine(of node: Syntax) -> Int {
        node.startLocation(converter: converter).line
    }

    private func overrideIfJustified(line: Int, ruleId: String) -> DiagnosticOverride? {
        let zeroIndexed = line - 1
        // Same-line trailing comment
        if zeroIndexed >= 0 && zeroIndexed < sourceLines.count {
            let lineText = sourceLines[zeroIndexed]
            if let commentRange = lineText.range(of: "//") {
                let commentText = String(lineText[commentRange.upperBound...])
                if commentText.contains(justificationKeyword) {
                    return DiagnosticOverride(
                        ruleId: ruleId,
                        justification: commentText.trimmingCharacters(in: .whitespaces),
                        filePath: fileName,
                        lineNumber: line
                    )
                }
            }
        }
        // Line directly above (no blank line between)
        let aboveIndex = zeroIndexed - 1
        if aboveIndex >= 0 && aboveIndex < sourceLines.count {
            let prev = sourceLines[aboveIndex].trimmingCharacters(in: .whitespaces)
            if prev.hasPrefix("//") && prev.contains(justificationKeyword) {
                return DiagnosticOverride(
                    ruleId: ruleId,
                    justification: prev,
                    filePath: fileName,
                    lineNumber: line
                )
            }
        }
        return nil
    }
}

// MARK: - Standalone helpers

func hasMainActorAttribute(_ attributes: AttributeListSyntax) -> Bool {
    for element in attributes {
        if let attribute = element.as(AttributeSyntax.self),
           attribute.attributeName.trimmedDescription == "MainActor" {
            return true
        }
    }
    return false
}

func hasPreconcurrencyAttribute(_ attributes: AttributeListSyntax) -> Bool {
    for element in attributes {
        if let attribute = element.as(AttributeSyntax.self),
           attribute.attributeName.trimmedDescription == "preconcurrency" {
            return true
        }
    }
    return false
}

func hasNonisolatedUnsafeModifier(_ modifiers: DeclModifierListSyntax) -> Bool {
    for modifier in modifiers {
        if modifier.name.text == "nonisolated",
           let detail = modifier.detail,
           detail.detail.text == "unsafe" {
            return true
        }
    }
    return false
}

func collectStoredProperties(memberBlock: MemberBlockSyntax) -> Set<String> {
    var names: Set<String> = []
    for member in memberBlock.members {
        guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
        // Skip static
        let isStatic = varDecl.modifiers.contains { $0.name.text == "static" }
        if isStatic { continue }
        for binding in varDecl.bindings {
            let isStored = binding.accessorBlock == nil
            guard isStored else { continue }
            if let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
                names.insert(pattern.identifier.text)
            }
        }
    }
    return names
}
