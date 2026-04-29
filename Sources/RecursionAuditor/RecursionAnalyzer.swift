import Foundation
import QualityGateCore
import SwiftSyntax

// MARK: - Protocol name pre-pass

/// Collects every protocol name declared in a Swift source file.
final class ProtocolNameCollector: SyntaxVisitor {
    var protocolNames: Set<String> = []

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        protocolNames.insert(node.name.text)
        return .visitChildren
    }
}

// MARK: - Recursion visitor

/// The main visitor. Walks a single source file, tracks the current type
/// context, applies single-file rules (1-7), and collects declarations to
/// feed the project-wide call graph (rule 8).
final class RecursionVisitor: SyntaxVisitor {
    let fileName: String
    let converter: SourceLocationConverter
    let protocolNames: Set<String>

    private(set) var diagnostics: [Diagnostic] = []
    private(set) var declarations: [DeclarationInfo] = []

    /// Lexical type stack: each element is a type name (or extension target).
    private var typeStack: [String] = []
    /// True at indices where the matching type stack frame is a protocol extension.
    private var inProtocolExtensionStack: [Bool] = []

    init(fileName: String, converter: SourceLocationConverter, protocolNames: Set<String>) {
        self.fileName = fileName
        self.converter = converter
        self.protocolNames = protocolNames
        super.init(viewMode: .sourceAccurate)
    }

    private var currentTypeContext: String { typeStack.joined(separator: ".") }
    private var insideProtocolExtension: Bool { inProtocolExtensionStack.last ?? false }

    // MARK: Type-context tracking

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        inProtocolExtensionStack.append(false)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) {
        typeStack.removeLast()
        inProtocolExtensionStack.removeLast()
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        inProtocolExtensionStack.append(false)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) {
        typeStack.removeLast()
        inProtocolExtensionStack.removeLast()
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        inProtocolExtensionStack.append(false)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) {
        typeStack.removeLast()
        inProtocolExtensionStack.removeLast()
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        inProtocolExtensionStack.append(false)
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) {
        typeStack.removeLast()
        inProtocolExtensionStack.removeLast()
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        inProtocolExtensionStack.append(false)
        return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) {
        typeStack.removeLast()
        inProtocolExtensionStack.removeLast()
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = extendedTypeName(node.extendedType) ?? "?"
        typeStack.append(name)
        inProtocolExtensionStack.append(protocolNames.contains(name))
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) {
        typeStack.removeLast()
        inProtocolExtensionStack.removeLast()
    }

    private func extendedTypeName(_ type: TypeSyntax) -> String? {
        if let ident = type.as(IdentifierTypeSyntax.self) {
            return ident.name.text
        }
        if let member = type.as(MemberTypeSyntax.self) {
            return member.name.text
        }
        return nil
    }

    // MARK: Function declarations

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        analyzeFunction(node)
        return .visitChildren
    }

    private func analyzeFunction(_ node: FunctionDeclSyntax) {
        let labels = parameterLabels(node.signature.parameterClause)
        let displayName = makeFunctionDisplayName(name: node.name.text, labels: labels)
        let signature = Signature(typeContext: currentTypeContext, displayName: displayName)
        let location = startLocation(of: Syntax(node))

        let body = node.body
        let outgoing = body.map { collectCalls(in: Syntax($0), enclosingTypeContext: currentTypeContext) } ?? []
        let baseCase = body.map { hasGuardEarlyExit(in: Syntax($0)) } ?? false

        // Self-recursion check (covers unconditional-self-call and protocol-extension-default-self).
        if let body {
            let selfRefs = findRecursiveCalls(
                in: Syntax(body),
                ownSignature: signature
            )
            if !selfRefs.isEmpty {
                if insideProtocolExtension {
                    diagnostics.append(Diagnostic(
                        severity: .error,
                        message: "protocol extension default '\(displayName)' calls itself, causing infinite recursion for any conformer that does not override",
                        filePath: location.file,
                        lineNumber: location.line,
                        columnNumber: location.column,
                        ruleId: "recursion.protocol-extension-default-self",
                        suggestedFix: "Delegate to a different protocol requirement instead of calling '\(displayName)'."
                    ))
                } else if !baseCase {
                    diagnostics.append(Diagnostic(
                        severity: .warning,
                        message: "function '\(displayName)' calls itself with no guard-driven base case",
                        filePath: location.file,
                        lineNumber: location.line,
                        columnNumber: location.column,
                        ruleId: "recursion.unconditional-self-call",
                        suggestedFix: "Add a guard clause that returns or throws before recursing."
                    ))
                }
            }
        }

        declarations.append(DeclarationInfo(
            signature: signature,
            location: location,
            hasBaseCase: baseCase,
            outgoingCalls: outgoing,
            isCallable: true
        ))
    }

    // MARK: Initializer declarations

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        analyzeInitializer(node)
        return .visitChildren
    }

    private func analyzeInitializer(_ node: InitializerDeclSyntax) {
        let labels = parameterLabels(node.signature.parameterClause)
        let displayName = makeFunctionDisplayName(name: "init", labels: labels)
        let location = startLocation(of: Syntax(node))

        let isConvenience = node.modifiers.contains { $0.name.tokenKind == .keyword(.convenience) }

        if isConvenience, let body = node.body {
            // Find self.init(...) calls whose argument labels exactly match this init's labels.
            let selfInitCalls = collectSelfInitCalls(in: Syntax(body))
            for call in selfInitCalls where call == labels {
                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: "convenience init forwards to itself with identical argument labels '\(displayName)'",
                    filePath: location.file,
                    lineNumber: location.line,
                    columnNumber: location.column,
                    ruleId: "recursion.convenience-init-self",
                    suggestedFix: "Delegate to a different initializer with different argument labels."
                ))
                break
            }
        }
    }

    // MARK: Variable declarations (computed properties)

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        analyzeVariable(node)
        return .visitChildren
    }

    private func analyzeVariable(_ node: VariableDeclSyntax) {
        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            let name = pattern.identifier.text
            guard let accessorBlock = binding.accessorBlock else { continue }

            let bindingLocation = startLocation(of: Syntax(binding))

            switch accessorBlock.accessors {
            case .getter(let codeBlock):
                // Shorthand getter: `var x: Int { ... }`
                if containsIdentifierReference(in: Syntax(codeBlock), name: name) {
                    diagnostics.append(Diagnostic(
                        severity: .error,
                        message: "computed property '\(name)' references itself in its getter",
                        filePath: bindingLocation.file,
                        lineNumber: bindingLocation.line,
                        columnNumber: bindingLocation.column,
                        ruleId: "recursion.computed-property-self",
                        suggestedFix: "Use a private backing storage property instead of '\(name)'."
                    ))
                }
            case .accessors(let accessors):
                for accessor in accessors {
                    let kind = accessor.accessorSpecifier.text
                    guard let body = accessor.body else { continue }
                    if kind == "get" {
                        if containsIdentifierReference(in: Syntax(body), name: name) {
                            diagnostics.append(Diagnostic(
                                severity: .error,
                                message: "computed property '\(name)' references itself in its getter",
                                filePath: bindingLocation.file,
                                lineNumber: bindingLocation.line,
                                columnNumber: bindingLocation.column,
                                ruleId: "recursion.computed-property-self",
                                suggestedFix: "Use a private backing storage property instead of '\(name)'."
                            ))
                        }
                    } else if kind == "set" {
                        if containsAssignmentTo(name: name, in: Syntax(body)) {
                            diagnostics.append(Diagnostic(
                                severity: .error,
                                message: "computed property setter for '\(name)' assigns to itself",
                                filePath: bindingLocation.file,
                                lineNumber: bindingLocation.line,
                                columnNumber: bindingLocation.column,
                                ruleId: "recursion.setter-self",
                                suggestedFix: "Assign to a private backing storage property instead of '\(name)'."
                            ))
                        }
                    }
                }
            }
        }
    }

    // MARK: Subscript declarations

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        analyzeSubscript(node)
        return .visitChildren
    }

    private func analyzeSubscript(_ node: SubscriptDeclSyntax) {
        let location = startLocation(of: Syntax(node))
        guard let accessorBlock = node.accessorBlock else { return }

        switch accessorBlock.accessors {
        case .getter(let codeBlock):
            if containsSelfSubscriptCall(in: Syntax(codeBlock)) {
                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: "subscript getter calls 'self[…]' recursively",
                    filePath: location.file,
                    lineNumber: location.line,
                    columnNumber: location.column,
                    ruleId: "recursion.subscript-self",
                    suggestedFix: "Delegate to a backing storage collection instead of 'self'."
                ))
            }
        case .accessors(let accessors):
            for accessor in accessors {
                let kind = accessor.accessorSpecifier.text
                guard let body = accessor.body else { continue }
                if kind == "get" {
                    if containsSelfSubscriptCall(in: Syntax(body)) {
                        diagnostics.append(Diagnostic(
                            severity: .error,
                            message: "subscript getter calls 'self[…]' recursively",
                            filePath: location.file,
                            lineNumber: location.line,
                            columnNumber: location.column,
                            ruleId: "recursion.subscript-self",
                            suggestedFix: "Delegate to a backing storage collection instead of 'self'."
                        ))
                    }
                } else if kind == "set" {
                    if containsSelfSubscriptAssignment(in: Syntax(body)) {
                        diagnostics.append(Diagnostic(
                            severity: .error,
                            message: "subscript setter assigns to 'self[…]' recursively",
                            filePath: location.file,
                            lineNumber: location.line,
                            columnNumber: location.column,
                            ruleId: "recursion.subscript-setter-self",
                            suggestedFix: "Assign to a backing storage collection instead of 'self'."
                        ))
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func startLocation(of node: Syntax) -> SourceLocation {
        let location = node.startLocation(converter: converter)
        return SourceLocation(file: fileName, line: location.line, column: location.column)
    }
}

// MARK: - Standalone analysis helpers

/// Extracts argument labels from a parameter clause. Unnamed parameters
/// (`func f(_ x: Int)`) yield "_" so overload resolution treats them
/// distinctly from labeled variants (`func f(x: Int)`).
func parameterLabels(_ clause: FunctionParameterClauseSyntax) -> [String] {
    clause.parameters.map { $0.firstName.text }
}

/// Builds a display name like `f(_:x:)` from a base name and label list.
func makeFunctionDisplayName(name: String, labels: [String]) -> String {
    let labelPart = labels.map { "\($0):" }.joined()
    return "\(name)(\(labelPart))"
}

/// Extracts argument labels from a labeled-expression list (a call site).
func callArgumentLabels(_ args: LabeledExprListSyntax) -> [String] {
    args.map { $0.label?.text ?? "_" }
}

/// Walks a syntax tree looking for `self.init(...)` calls and returns the
/// argument label list of each one.
func collectSelfInitCalls(in node: Syntax) -> [[String]] {
    final class Walker: SyntaxVisitor {
        var calls: [[String]] = []
        override func visit(_ call: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
               let base = member.base,
               base.trimmedDescription == "self",
               member.declName.baseName.text == "init" {
                calls.append(callArgumentLabels(call.arguments))
            }
            return .visitChildren
        }
    }
    let walker = Walker(viewMode: .sourceAccurate)
    walker.walk(node)
    return walker.calls
}

/// True if the body contains a recognizable base case. Heuristic:
/// - Any `guard` statement (assumed to early-exit in its else branch), OR
/// - Any bare `return` (no expression), OR
/// - Any `return` whose expression is NOT a function call (literal, identifier,
///   member access, etc. — i.e. a non-recursing return path).
///
/// This catches both classic guard-based base cases and the visitor / recursive-
/// descent pattern where each branch ends in `return` after delegating to a
/// helper, which is a legitimate non-infinite recursion shape.
func hasGuardEarlyExit(in node: Syntax) -> Bool {
    final class Walker: SyntaxVisitor {
        var found = false
        override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
            found = true
            return .skipChildren
        }
        override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
            // Bare `return` → base case.
            guard let expression = node.expression else {
                found = true
                return .skipChildren
            }
            // `return <non-call>` → base case (literal, identifier, etc.).
            if !expression.is(FunctionCallExprSyntax.self) {
                found = true
            }
            return .skipChildren
        }
    }
    let walker = Walker(viewMode: .sourceAccurate)
    walker.walk(node)
    return walker.found
}

/// Walks a function body and finds calls to the function with the given
/// signature (matching display name; type context is inferred from lexical scope).
func findRecursiveCalls(in body: Syntax, ownSignature: Signature) -> [FunctionCallExprSyntax] {
    final class Walker: SyntaxVisitor {
        let target: Signature
        var hits: [FunctionCallExprSyntax] = []
        init(target: Signature) {
            self.target = target
            super.init(viewMode: .sourceAccurate)
        }
        override func visit(_ call: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            // Resolve callee base name.
            let calleeName: String?
            if let ident = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                calleeName = ident.baseName.text
            } else if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                      let base = member.base,
                      base.trimmedDescription == "self" {
                calleeName = member.declName.baseName.text
            } else {
                calleeName = nil
            }
            if let name = calleeName {
                let labels = callArgumentLabels(call.arguments)
                let display = makeFunctionDisplayName(name: name, labels: labels)
                if display == target.displayName {
                    hits.append(call)
                }
            }
            return .visitChildren
        }
    }
    let walker = Walker(target: ownSignature)
    walker.walk(body)
    return walker.hits
}

/// Collects every call site within a body, recording its candidate signatures.
/// `enclosingTypeContext` is the lexical type context of the body itself, used
/// to add a "method on enclosing type" candidate for bare calls.
func collectCalls(in body: Syntax, enclosingTypeContext: String) -> [CallSite] {
    final class Walker: SyntaxVisitor {
        let enclosingType: String
        var calls: [CallSite] = []
        init(enclosingType: String) {
            self.enclosingType = enclosingType
            super.init(viewMode: .sourceAccurate)
        }
        override func visit(_ call: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            // Free / self call: `b()` or `self.b()` → candidates with empty type context AND any
            // type contexts get appended later by the orchestrator. For simplicity we generate
            // both: empty (free) and a "method on receiver type" candidate when receiver is
            // `Foo()` (constructor).
            var calleeName: String?
            var receiverType: String?

            if let ident = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                calleeName = ident.baseName.text
            } else if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
                calleeName = member.declName.baseName.text
                if let base = member.base {
                    if base.trimmedDescription == "self" {
                        // self call — still a free name, type context resolved by orchestrator
                        receiverType = nil
                    } else if let baseCall = base.as(FunctionCallExprSyntax.self),
                              let receiverIdent = baseCall.calledExpression.as(DeclReferenceExprSyntax.self),
                              receiverIdent.baseName.text.first?.isUppercase == true {
                        // `Foo()` constructor call → receiver type is "Foo"
                        receiverType = receiverIdent.baseName.text
                    } else if let receiverIdent = base.as(DeclReferenceExprSyntax.self),
                              receiverIdent.baseName.text.first?.isUppercase == true {
                        // `Foo.staticCall()` → receiver type is "Foo"
                        receiverType = receiverIdent.baseName.text
                    }
                }
            }

            if let name = calleeName {
                let labels = callArgumentLabels(call.arguments)
                let display = makeFunctionDisplayName(name: name, labels: labels)
                var candidates: [Signature] = [Signature(typeContext: "", displayName: display)]
                if let receiverType {
                    candidates.append(Signature(typeContext: receiverType, displayName: display))
                }
                if !enclosingType.isEmpty {
                    candidates.append(Signature(typeContext: enclosingType, displayName: display))
                }
                calls.append(CallSite(candidateSignatures: candidates))
            }
            return .visitChildren
        }
    }
    let walker = Walker(enclosingType: enclosingTypeContext)
    walker.walk(body)
    return walker.calls
}

/// True if the syntax tree contains an identifier reference with the given
/// name, either as a bare identifier or as `self.name`.
func containsIdentifierReference(in node: Syntax, name: String) -> Bool {
    final class Walker: SyntaxVisitor {
        let target: String
        var found = false
        init(target: String) {
            self.target = target
            super.init(viewMode: .sourceAccurate)
        }
        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            if node.baseName.text == target {
                found = true
            }
            return .skipChildren
        }
        override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
            if let base = node.base, base.trimmedDescription == "self",
               node.declName.baseName.text == target {
                found = true
                return .skipChildren
            }
            return .visitChildren
        }
    }
    let walker = Walker(target: name)
    walker.walk(node)
    return walker.found
}

/// True if the syntax tree contains an assignment whose LHS identifier is `name`
/// (either bare or `self.name`).
func containsAssignmentTo(name: String, in node: Syntax) -> Bool {
    final class Walker: SyntaxVisitor {
        let target: String
        var found = false
        init(target: String) {
            self.target = target
            super.init(viewMode: .sourceAccurate)
        }
        override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
            // Look for `LHS = RHS` patterns within a sequence expression.
            let elements = Array(node.elements)
            for (index, element) in elements.enumerated() {
                if let _ = element.as(AssignmentExprSyntax.self), index > 0 {
                    let lhs = elements[index - 1]
                    if matches(lhs) {
                        found = true
                    }
                }
            }
            return .visitChildren
        }
        private func matches(_ expr: ExprSyntax) -> Bool {
            if let ident = expr.as(DeclReferenceExprSyntax.self), ident.baseName.text == target {
                return true
            }
            if let member = expr.as(MemberAccessExprSyntax.self),
               let base = member.base, base.trimmedDescription == "self",
               member.declName.baseName.text == target {
                return true
            }
            return false
        }
    }
    let walker = Walker(target: name)
    walker.walk(node)
    return walker.found
}

/// True if the syntax tree contains a subscript call on `self`, e.g. `self[i]`.
func containsSelfSubscriptCall(in node: Syntax) -> Bool {
    final class Walker: SyntaxVisitor {
        var found = false
        override func visit(_ node: SubscriptCallExprSyntax) -> SyntaxVisitorContinueKind {
            if node.calledExpression.trimmedDescription == "self" {
                found = true
            }
            return .visitChildren
        }
    }
    let walker = Walker(viewMode: .sourceAccurate)
    walker.walk(node)
    return walker.found
}

/// True if the syntax tree contains an assignment whose LHS is `self[…]`.
func containsSelfSubscriptAssignment(in node: Syntax) -> Bool {
    final class Walker: SyntaxVisitor {
        var found = false
        override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
            let elements = Array(node.elements)
            for (index, element) in elements.enumerated() {
                if element.as(AssignmentExprSyntax.self) != nil, index > 0 {
                    let lhs = elements[index - 1]
                    if let sub = lhs.as(SubscriptCallExprSyntax.self),
                       sub.calledExpression.trimmedDescription == "self" {
                        found = true
                    }
                }
            }
            return .visitChildren
        }
    }
    let walker = Walker(viewMode: .sourceAccurate)
    walker.walk(node)
    return walker.found
}
