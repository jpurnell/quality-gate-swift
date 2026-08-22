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
    private let sourceLines: [String]

    private(set) var diagnostics: [Diagnostic] = []
    private(set) var declarations: [DeclarationInfo] = []
    /// Self-call findings held until the whole file is walked. Whether a matching call
    /// resolves to *this* declaration or to a sibling overload depends on declarations
    /// that may not have been visited yet, so the decision cannot be made inline.
    private(set) var pendingSelfCalls: [(signature: Signature, confident: Diagnostic, unresolved: Diagnostic)] = []
    /// How many *implementations* each signature has, which is what decides overloading.
    ///
    /// Bodyless declarations are excluded deliberately: a protocol requirement and the
    /// extension default that satisfies it share a signature but are one function, and
    /// counting the pair as two overloads would silence the very rule that exists to
    /// catch `extension P { func f() { f() } }`.
    private(set) var bodiedSignatureCounts: [Signature: Int] = [:]

    /// Lexical type stack: each element is a type name (or extension target).
    private var typeStack: [String] = []
    /// True at indices where the matching type stack frame is a protocol extension.
    private var inProtocolExtensionStack: [Bool] = []

    /// Inline suppression annotation: `// recursion:safe`
    private static let suppressionMarker = "// recursion:safe"

    init(fileName: String, source: String, converter: SourceLocationConverter, protocolNames: Set<String>) {
        self.fileName = fileName
        self.converter = converter
        self.protocolNames = protocolNames
        self.sourceLines = source.lines
        super.init(viewMode: .sourceAccurate)
    }

    /// Returns true if the given line (1-based) contains the suppression annotation.
    private func isSuppressed(atLine line: Int) -> Bool {
        let index = line - 1
        guard index >= 0, index < sourceLines.count else { return false }
        return sourceLines[index].contains(Self.suppressionMarker)
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

    /// The dotted name an extension extends, matching the context a nested declaration
    /// builds from its lexical stack.
    ///
    /// `extension Row.ScopesView` previously yielded "ScopesView" while `struct
    /// ScopesView` nested in `Row` yielded "Row.ScopesView", so the two never shared a
    /// type context and every signature declared across the pair looked unique. GRDB's
    /// `ScopesView` declares one subscript in each half.
    private func extendedTypeName(_ type: TypeSyntax) -> String? {
        if let ident = type.as(IdentifierTypeSyntax.self) {
            return ident.name.text
        }
        if let member = type.as(MemberTypeSyntax.self) {
            guard let base = extendedTypeName(member.baseType) else {
                return member.name.text
            }
            return "\(base).\(member.name.text)"
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
        if body != nil {
            bodiedSignatureCounts[signature, default: 0] += 1
        }
        let outgoing = body.map { collectCalls(in: Syntax($0), enclosingTypeContext: currentTypeContext) } ?? []
        let baseCase = body.map { hasGuardEarlyExit(in: Syntax($0)) } ?? false
        let selfBaseCase = body.map { hasSelfBaseCase(in: Syntax($0), ownSignature: signature) } ?? false

        // Self-recursion check (covers unconditional-self-call and protocol-extension-default-self).
        if let body {
            let selfRefs = findRecursiveCalls(
                in: Syntax(body),
                ownSignature: signature
            )
            if !selfRefs.isEmpty, !isSuppressed(atLine: location.line) {
                let unresolved = Diagnostic(
                    severity: .note,
                    message: "'\(displayName)' is declared more than once with these argument labels, so a call matching them is resolved by parameter type — which a syntactic pass cannot do. Recorded as unresolved rather than reported as recursion; no pass currently adjudicates it.",
                    filePath: location.file,
                    lineNumber: location.line,
                    columnNumber: location.column,
                    ruleId: "recursion.self-reference-unresolved",
                    suggestedFix: "Read the call and confirm which overload it selects. The index pass resolves this automatically where it can see the file — overloads are distinct symbols there — so a site reaching this note is one it could not see: code excluded by a platform condition or a package trait, a test target, or a failed index build. The pass reports which of those applies."
                )
                if insideProtocolExtension {
                    pendingSelfCalls.append((signature, Diagnostic(
                        severity: .error,
                        message: "protocol extension default '\(displayName)' calls itself, causing infinite recursion for any conformer that does not override",
                        filePath: location.file,
                        lineNumber: location.line,
                        columnNumber: location.column,
                        ruleId: "recursion.protocol-extension-default-self",
                        suggestedFix: "Delegate to a different protocol requirement instead of calling '\(displayName)'."
                    ), unresolved))
                } else if !selfBaseCase {
                    pendingSelfCalls.append((signature, Diagnostic(
                        severity: .warning,
                        message: "function '\(displayName)' calls itself with no guard-driven base case",
                        filePath: location.file,
                        lineNumber: location.line,
                        columnNumber: location.column,
                        ruleId: "recursion.unconditional-self-call",
                        suggestedFix: "Add a guard clause that returns or throws before recursing."
                    ), unresolved))
                }
            }
        }

        declarations.append(DeclarationInfo(
            signature: signature,
            location: location,
            hasBaseCase: baseCase,
            hasSelfBaseCase: selfBaseCase,
            wasAnalysed: body != nil,
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

        if isConvenience, let body = node.body, !isSuppressed(atLine: location.line) {
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
        let siblings = siblingFunctionNames(of: node)
        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            let name = pattern.identifier.text
            guard let accessorBlock = binding.accessorBlock else { continue }

            let bindingLocation = startLocation(of: Syntax(binding))

            // Recorded so the index pass can learn this getter's base case. Not callable:
            // cycle detection filters on that flag, and a property has never been one of
            // its participants.
            let getterBody: Syntax? = switch accessorBlock.accessors {
            case .getter(let codeBlock): Syntax(codeBlock)
            case .accessors(let accessors):
                accessors.first { $0.accessorSpecifier.text == "get" }?.body.map(Syntax.init)
            }
            let propertySignature = Signature(typeContext: currentTypeContext, displayName: name)
            declarations.append(DeclarationInfo(
                signature: propertySignature,
                location: bindingLocation,
                hasBaseCase: false,
                hasSelfBaseCase: getterBody.map {
                    hasSelfBaseCase(in: $0, ownSignature: propertySignature)
                } ?? false,
                wasAnalysed: getterBody != nil,
                outgoingCalls: [],
                isCallable: false
            ))

            switch accessorBlock.accessors {
            case .getter(let codeBlock):
                // Shorthand getter: `var x: Int { ... }`
                if containsIdentifierReference(in: Syntax(codeBlock), name: name, siblingFunctions: siblings),
                   !isSuppressed(atLine: bindingLocation.line) {
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
                        if containsIdentifierReference(in: Syntax(body), name: name, siblingFunctions: siblings),
                           !isSuppressed(atLine: bindingLocation.line) {
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
                        if containsAssignmentTo(name: name, in: Syntax(body)),
                           !isSuppressed(atLine: bindingLocation.line) {
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

        // Labels first: `self[key: k]` inside `subscript(sub:)` selects a different
        // subscript, and matching every `self[…]` regardless of labels is what made
        // SwiftyJSON — which declares five — report on all of them.
        let labels = subscriptParameterLabels(node.parameterClause)
        let displayName = makeFunctionDisplayName(name: "subscript", labels: labels)
        let signature = Signature(typeContext: currentTypeContext, displayName: displayName)
        bodiedSignatureCounts[signature, default: 0] += 1

        // Recorded for the same reason as a computed property: the index graph admits a
        // subscript's accessors, so a subscript that plainly returns has to be able to
        // say so. Not callable — cycle detection filters on that flag.
        let subscriptGetterBody: Syntax? = switch accessorBlock.accessors {
        case .getter(let codeBlock): Syntax(codeBlock)
        case .accessors(let accessors):
            accessors.first { $0.accessorSpecifier.text == "get" }?.body.map(Syntax.init)
        }
        declarations.append(DeclarationInfo(
            signature: signature,
            location: location,
            hasBaseCase: false,
            hasSelfBaseCase: subscriptGetterBody.map {
                hasSelfBaseCase(in: $0, ownSignature: signature)
            } ?? false,
            wasAnalysed: subscriptGetterBody != nil,
            outgoingCalls: [],
            isCallable: false
        ))

        guard !isSuppressed(atLine: location.line) else { return }

        let unresolved = Diagnostic(
            severity: .note,
            message: "'\(displayName)' is declared more than once with these argument labels, so a call matching them is resolved by parameter type — which a syntactic pass cannot do. Recorded as unresolved rather than reported as recursion; no pass currently adjudicates it.",
            filePath: location.file,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "recursion.self-reference-unresolved",
            suggestedFix: "Read the call and confirm which subscript it selects. Resolving these automatically needs USR identity, which the index pass has and the syntactic pass does not."
        )

        func reportGetter() {
            pendingSelfCalls.append((signature, Diagnostic(
                severity: .error,
                message: "subscript getter calls 'self[…]' recursively",
                filePath: location.file,
                lineNumber: location.line,
                columnNumber: location.column,
                ruleId: "recursion.subscript-self",
                suggestedFix: "Delegate to a backing storage collection instead of 'self'."
            ), unresolved))
        }

        func reportSetter() {
            pendingSelfCalls.append((signature, Diagnostic(
                severity: .error,
                message: "subscript setter assigns to 'self[…]' recursively",
                filePath: location.file,
                lineNumber: location.line,
                columnNumber: location.column,
                ruleId: "recursion.subscript-setter-self",
                suggestedFix: "Assign to a backing storage collection instead of 'self'."
            ), unresolved))
        }

        switch accessorBlock.accessors {
        case .getter(let codeBlock):
            if containsSelfSubscriptCall(in: Syntax(codeBlock), labels: labels) {
                reportGetter()
            }
        case .accessors(let accessors):
            for accessor in accessors {
                let kind = accessor.accessorSpecifier.text
                guard let body = accessor.body else { continue }
                if kind == "get" {
                    if containsSelfSubscriptCall(in: Syntax(body), labels: labels) {
                        reportGetter()
                    }
                } else if kind == "set" {
                    if containsSelfSubscriptAssignment(in: Syntax(body), labels: labels) {
                        reportSetter()
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

/// Argument labels for a *subscript* parameter clause.
///
/// Subscripts do not promote a parameter's name to an argument label the way functions
/// do: `subscript(index: Int)` is called `self[index]` with no label at all, and a label
/// appears only when a second name is written — `subscript(index index: Int)` is called
/// `self[index: i]`. Reusing `parameterLabels` here reads every subscript as labelled and
/// so matches nothing.
func subscriptParameterLabels(_ clause: FunctionParameterClauseSyntax) -> [String] {
    clause.parameters.map { $0.secondName == nil ? "_" : $0.firstName.text }
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
/// True if the body has a branch that exits without calling anything.
///
/// The strict reading, and the one mutual-cycle detection needs: a branch that returns
/// some *other* call is not a base case for a cycle, because that call may be the next
/// participant. `hasSelfBaseCase` asks the looser question the self-call rules need.
func hasGuardEarlyExit(in node: Syntax) -> Bool {
    final class Walker: SyntaxVisitor {
        var found = false
        override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
            found = true
            return .skipChildren
        }
        override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
            guard let expression = node.expression else {
                found = true
                return .skipChildren
            }
            if !expression.is(FunctionCallExprSyntax.self) {
                found = true
            }
            // Keep descending. A returned expression can carry closures, and a guard
            // inside one bounds the function just as a top-level guard does —
            // swift-collections' `_subtracting_slow` reaches its guard through two
            // nested `read { }` closures. Stopping here made every such function read
            // as unbounded.
            return .visitChildren
        }
    }
    let walker = Walker(viewMode: .sourceAccurate)
    walker.walk(node)
    return walker.found
}

/// True if the body has a branch that exits without re-entering *this* function.
///
/// Direct self-recursion is bounded by any path that does not call itself again,
/// whatever that path returns. Two shapes the statement-level heuristic missed:
///
/// - `return someOtherFunction(…)` — GRDB's `SQLExpression.between` terminates by
///   returning `self.init(…)`, which is a call, so every branch looked recursive.
/// - an implicit return — `if`/`switch` *expressions* make each branch a value with no
///   `return` keyword, which is how Ignite's `flatten(_:)` reaches `[]`.
func hasSelfBaseCase(in node: Syntax, ownSignature: Signature) -> Bool {
    final class Walker: SyntaxVisitor {
        let target: Signature
        var found = false
        init(target: Signature) {
            self.target = target
            super.init(viewMode: .sourceAccurate)
        }
        override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
            found = true
            return .skipChildren
        }
        override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
            guard let expression = node.expression else {
                found = true
                return .skipChildren
            }
            if findRecursiveCalls(in: Syntax(expression), ownSignature: target).isEmpty {
                found = true
            }
            // Keep descending, for the same reason as `hasGuardEarlyExit`: a guard
            // inside a closure within the returned expression still bounds this call.
            return .visitChildren
        }
        /// Restricted to blocks holding exactly one item, so `{ recurse(); cleanup() }`
        /// — where the trailing expression is a statement, not the branch's value — is
        /// not mistaken for a terminating branch.
        override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
            guard node.count == 1, let only = node.first,
                  case .expr(let expression) = only.item else {
                return .visitChildren
            }
            if findRecursiveCalls(in: Syntax(expression), ownSignature: target).isEmpty {
                found = true
            }
            return .visitChildren
        }
    }
    let walker = Walker(target: ownSignature)
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

/// True if the syntax tree contains a self-referencing identifier with the given name.
///
/// Three things that carry the name are *not* references to the enclosing declaration,
/// and each was found misreported across the 22-package survey corpus:
///
/// - a key path component — `\.retryCount` resolves against the key path's root type;
/// - a call to a same-named method — `asISO8601()` where the type declares one;
/// - any identifier shadowed by a local binding, tracked by ``LexicalScope``.
func containsIdentifierReference(
    in node: Syntax,
    name: String,
    siblingFunctions: Set<String> = []
) -> Bool {
    final class Walker: SyntaxVisitor {
        let target: String
        let siblingFunctions: Set<String>
        var found = false
        private var scope = LexicalScope()

        init(target: String, siblingFunctions: Set<String>) {
            self.target = target
            self.siblingFunctions = siblingFunctions
            super.init(viewMode: .sourceAccurate)
        }

        // MARK: Scopes

        override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
            scope.push()
            return .visitChildren
        }
        override func visitPost(_ node: CodeBlockSyntax) { scope.pop() }

        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
            scope.push()
            return .visitChildren
        }
        override func visitPost(_ node: ClosureExprSyntax) { scope.pop() }

        override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
            scope.push()
            return .visitChildren
        }
        override func visitPost(_ node: SwitchCaseSyntax) { scope.pop() }

        // MARK: Declarations
        //
        // Recorded in `visitPost` so the initializer is walked first: in `let x = x`
        // the right-hand `x` binds to the outer declaration, which is how Swift reads
        // it. Declaring on the way out is what makes the stack lexically ordered.

        override func visitPost(_ node: VariableDeclSyntax) {
            for binding in node.bindings {
                declareNames(in: Syntax(binding.pattern))
            }
        }

        override func visitPost(_ node: OptionalBindingConditionSyntax) {
            declareNames(in: Syntax(node.pattern))
        }

        override func visitPost(_ node: ValueBindingPatternSyntax) {
            declareNames(in: Syntax(node.pattern))
        }

        override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
            scope.declare((node.secondName ?? node.firstName).text)
            return .visitChildren
        }

        override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
            scope.declare(node.name.text)
            return .visitChildren
        }

        override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
            scope.declare((node.secondName ?? node.firstName).text)
            return .visitChildren
        }

        /// Collects the names a pattern binds.
        ///
        /// `case let .complete(completion)` parses as an expression pattern, so the
        /// bindings are `DeclReferenceExpr` nodes rather than `IdentifierPattern`s.
        /// The case name itself is the callee and binds nothing.
        private func declareNames(in node: Syntax) {
            final class Finder: SyntaxVisitor {
                var names: [String] = []
                override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
                    names.append(node.identifier.text)
                    return .skipChildren
                }
                override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
                    if let base = node.base { walk(base) }
                    return .skipChildren
                }
                override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                    for argument in node.arguments { walk(Syntax(argument)) }
                    return .skipChildren
                }
                override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
                    names.append(node.baseName.text)
                    return .skipChildren
                }
            }
            let finder = Finder(viewMode: .sourceAccurate)
            finder.walk(node)
            for boundName in finder.names { scope.declare(boundName) }
        }

        // MARK: References

        /// A key path component names a member of the key path's root type, never the
        /// enclosing declaration. Subscript arguments inside a key path are ordinary
        /// expressions and are still visited.
        override func visit(_ node: KeyPathPropertyComponentSyntax) -> SyntaxVisitorContinueKind {
            .skipChildren
        }

        override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
            // `self.name` names the property whatever locals are in scope, so the
            // shadow stack deliberately does not apply on this branch.
            if let base = node.base, base.trimmedDescription == "self",
               node.declName.baseName.text == target {
                // `self.name(...)` still resolves to a sibling method, for the same
                // reason the unqualified call does.
                if siblingFunctions.contains(target),
                   let call = node.parent?.as(FunctionCallExprSyntax.self),
                   call.calledExpression.id == node.id {
                    return .skipChildren
                }
                found = true
                return .skipChildren
            }
            return .visitChildren
        }

        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            guard node.baseName.text == target, !scope.shadows(target) else {
                return .skipChildren
            }
            // `other.name` — qualified by something that is not `self`, so the
            // member belongs to another value. The `self.name` case is decided by
            // the member-access override above, which never reaches here.
            if let member = node.parent?.as(MemberAccessExprSyntax.self),
               member.declName.id == node.id {
                return .skipChildren
            }
            // `name(...)` where the enclosing type declares `func name` resolves to
            // that method. A property is only callable when its own type is a
            // function type, and then no sibling method of the name exists.
            if siblingFunctions.contains(target),
               let call = node.parent?.as(FunctionCallExprSyntax.self),
               call.calledExpression.id == node.id {
                return .skipChildren
            }
            found = true
            return .skipChildren
        }
    }
    let walker = Walker(target: name, siblingFunctions: siblingFunctions)
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
func containsSelfSubscriptCall(in node: Syntax, labels: [String]) -> Bool {
    final class Walker: SyntaxVisitor {
        let target: [String]
        var found = false
        init(target: [String]) {
            self.target = target
            super.init(viewMode: .sourceAccurate)
        }
        override func visit(_ node: SubscriptCallExprSyntax) -> SyntaxVisitorContinueKind {
            if node.calledExpression.trimmedDescription == "self",
               callArgumentLabels(node.arguments) == target {
                found = true
            }
            return .visitChildren
        }
    }
    let walker = Walker(target: labels)
    walker.walk(node)
    return walker.found
}

/// True if the syntax tree contains an assignment whose LHS is `self[…]`.
func containsSelfSubscriptAssignment(in node: Syntax, labels: [String]) -> Bool {
    final class Walker: SyntaxVisitor {
        let target: [String]
        var found = false
        init(target: [String]) {
            self.target = target
            super.init(viewMode: .sourceAccurate)
        }
        override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
            let elements = Array(node.elements)
            for (index, element) in elements.enumerated() {
                if element.as(AssignmentExprSyntax.self) != nil, index > 0 {
                    let lhs = elements[index - 1]
                    if let sub = lhs.as(SubscriptCallExprSyntax.self),
                       sub.calledExpression.trimmedDescription == "self",
                       callArgumentLabels(sub.arguments) == target {
                        found = true
                    }
                }
            }
            return .visitChildren
        }
    }
    let walker = Walker(target: labels)
    walker.walk(node)
    return walker.found
}
