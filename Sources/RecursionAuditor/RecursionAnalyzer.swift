import Foundation
import QualityGateCore
import SwiftSyntax
import SwiftParser

// MARK: - Protocol name pre-pass

/// Collects every protocol name declared in a Swift source file.
final class ProtocolNameCollector: SyntaxVisitor {
    var protocolNames: Set<String> = []
    /// Protocol name -> the protocols it refines.
    ///
    /// A default in `extension SchemaType` can call a member declared in
    /// `extension QueryType` when `SchemaType: QueryType`, so the overload census has to
    /// look up the conformance chain as well as at the exact type context.
    var inheritedProtocols: [String: Set<String>] = [:]

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        protocolNames.insert(node.name.text)
        if let inherited = node.inheritanceClause?.inheritedTypes {
            inheritedProtocols[node.name.text, default: []]
                .formUnion(inherited.map { $0.type.trimmedDescription })
        }
        return .visitChildren
    }
}

/// Every protocol reachable from `name` by refinement, `name` excluded.
///
/// Guarded against cycles: Swift rejects circular refinement, but this reads whatever is
/// on disk, which may not compile.
func inheritedClosure(of name: String, in edges: [String: Set<String>]) -> Set<String> {
    var seen: Set<String> = []
    var pending = Array(edges[name] ?? [])
    while let next = pending.popLast() {
        guard next != name, seen.insert(next).inserted else { continue }
        pending.append(contentsOf: edges[next] ?? [])
    }
    return seen
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
    /// The distinct *functions* declared under each signature, project-wide.
    ///
    /// Counting declarations was wrong in both directions. Counting only bodied ones —
    /// the previous rule — correctly merged a protocol requirement with the extension
    /// default that satisfies it, but did so by discarding requirements entirely, so two
    /// *sibling* requirements differing only in parameter type counted as one function and
    /// a call to either read as recursion. Counting all declarations instead would split
    /// the requirement/default pair and silence the rule's whole reason for existing.
    ///
    /// Counting distinct type discriminators gets both right for one reason: a requirement
    /// and its default describe the same function and normalize to the same discriminator,
    /// while siblings do not.
    private(set) var signatureDiscriminators: [Signature: Set<TypeDiscriminator>] = [:]

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
        signatureDiscriminators[signature, default: []].insert(typeDiscriminator(of: node))
        let outgoing = body.map { collectCalls(in: Syntax($0), enclosingTypeContext: currentTypeContext) } ?? []
        let baseCase = body.map { hasGuardEarlyExit(in: Syntax($0)) } ?? false
        let selfBaseCase = body.map { hasSelfBaseCase(in: Syntax($0), ownSignature: signature) } ?? false

        // Self-recursion check (covers unconditional-self-call and protocol-extension-default-self).
        if let body {
            let selfRefs = findRecursiveCalls(
                in: Syntax(body),
                ownSignature: signature,
                ownParameterTypes: node.signature.parameterClause.parameters.map {
                    normalizeTypeSpelling($0.type.description)
                }
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
            isCallable: true,
            candidateBaseCases: body.map { candidateBaseCases(in: Syntax($0), converter: converter) } ?? []
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
        let signature = Signature(typeContext: currentTypeContext, displayName: displayName)
        signatureDiscriminators[signature, default: []].insert(typeDiscriminator(of: node))

        // Initializers join the site-keyed handoff to Pass 2 like every other
        // declaration. Without this, an init has no `analysedSites` entry, so the index
        // pass's wasAnalysed guard skips its self-edges — and `convenience-init-self`
        // stays a final syntactic verdict in indexed projects. IndexStoreDB names the
        // symbol `init(y:)`, which is exactly this displayName, so the site join needs
        // no normalisation. Not callable: Pass 1's own name-based cycle detection stays
        // methods-only; the fixture-verified constructor path belongs to Pass 2.
        declarations.append(DeclarationInfo(
            signature: signature,
            location: location,
            hasBaseCase: node.body.map { hasGuardEarlyExit(in: Syntax($0)) } ?? false,
            hasSelfBaseCase: node.body.map { hasSelfBaseCase(in: Syntax($0), ownSignature: signature) } ?? false,
            wasAnalysed: node.body != nil,
            outgoingCalls: [],
            isCallable: false,
            candidateBaseCases: node.body.map { candidateBaseCases(in: Syntax($0), converter: converter) } ?? []
        ))

        let isConvenience = node.modifiers.contains { $0.name.tokenKind == .keyword(.convenience) }

        if isConvenience, let body = node.body, !isSuppressed(atLine: location.line) {
            // Find self.init(...) calls whose argument labels exactly match this init's labels.
            let selfInitCalls = collectSelfInitCalls(in: Syntax(body))
            for call in selfInitCalls where callMatchesDeclaration(
                calleeName: "init",
                parenthesizedLabels: call.labels,
                trailingClosures: call.trailingClosures,
                declaration: makeFunctionDisplayName(name: "init", labels: labels),
                declarationParameterTypes: node.signature.parameterClause.parameters.map {
                    normalizeTypeSpelling($0.type.description)
                }
            ) {
                // Routed through the project-wide census rather than reported directly.
                // Initializers overload on parameter type at least as often as methods do —
                // GRDB's `Row.init(_:)` takes `[AnyHashable: Any]` and delegates to the
                // `[String: DatabaseValueConvertible?]` one, SQLite.swift's `Connection`
                // takes a `String` and delegates to the `Location` one — and this rule
                // asserted recursion on every such pair because it never consulted it.
                pendingSelfCalls.append((signature, Diagnostic(
                    severity: .error,
                    message: "convenience init forwards to itself with identical argument labels '\(displayName)'",
                    filePath: location.file,
                    lineNumber: location.line,
                    columnNumber: location.column,
                    ruleId: "recursion.convenience-init-self",
                    suggestedFix: "Delegate to a different initializer with different argument labels."
                ), Diagnostic(
                    severity: .note,
                    message: "'\(displayName)' is declared more than once with these argument labels, so a call matching them is resolved by parameter type — which a syntactic pass cannot do. Recorded as unresolved rather than reported as recursion; no pass currently adjudicates it.",
                    filePath: location.file,
                    lineNumber: location.line,
                    columnNumber: location.column,
                    ruleId: "recursion.self-reference-unresolved",
                    suggestedFix: "Read the call and confirm which initializer it selects."
                )))
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
                hasBaseCase: getterBody.map { hasGuardEarlyExit(in: $0) } ?? false,
                hasSelfBaseCase: getterBody.map {
                    hasSelfBaseCase(in: $0, ownSignature: propertySignature)
                } ?? false,
                wasAnalysed: getterBody != nil,
                outgoingCalls: [],
                isCallable: false,
                candidateBaseCases: getterBody.map { candidateBaseCases(in: $0, converter: converter) } ?? []
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
        signatureDiscriminators[signature, default: []].insert(typeDiscriminator(of: node))

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
            hasBaseCase: subscriptGetterBody.map { hasGuardEarlyExit(in: $0) } ?? false,
            hasSelfBaseCase: subscriptGetterBody.map {
                hasSelfBaseCase(in: $0, ownSignature: signature)
            } ?? false,
            wasAnalysed: subscriptGetterBody != nil,
            outgoingCalls: [],
            isCallable: false,
            candidateBaseCases: subscriptGetterBody.map { candidateBaseCases(in: $0, converter: converter) } ?? []
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
///
/// This sees only the *parenthesized* arguments. A trailing closure is a separate
/// property of `FunctionCallExprSyntax`, so callers that compare against a declaration
/// must add `trailingClosureCount` — see `callMatchesDeclaration`.
func callArgumentLabels(_ args: LabeledExprListSyntax) -> [String] {
    args.map { $0.label?.text ?? "_" }
}

/// The written type identity of a function declaration.
func typeDiscriminator(of node: FunctionDeclSyntax) -> TypeDiscriminator {
    TypeDiscriminator(
        parameterTypes: node.signature.parameterClause.parameters.map {
            normalizeTypeSpelling($0.type.description)
        },
        isAsync: node.signature.effectSpecifiers?.asyncSpecifier != nil,
        returnType: node.signature.returnClause.map { normalizeTypeSpelling($0.type.description) } ?? ""
    )
}

/// The written type identity of an initializer declaration.
func typeDiscriminator(of node: InitializerDeclSyntax) -> TypeDiscriminator {
    TypeDiscriminator(
        parameterTypes: node.signature.parameterClause.parameters.map {
            normalizeTypeSpelling($0.type.description)
        },
        isAsync: node.signature.effectSpecifiers?.asyncSpecifier != nil,
        returnType: ""
    )
}

/// The written type identity of a subscript declaration.
func typeDiscriminator(of node: SubscriptDeclSyntax) -> TypeDiscriminator {
    TypeDiscriminator(
        parameterTypes: node.parameterClause.parameters.map {
            normalizeTypeSpelling($0.type.description)
        },
        isAsync: false,
        returnType: normalizeTypeSpelling(node.returnClause.type.description)
    )
}

/// How many arguments a call passes as trailing closures.
func trailingClosureCount(_ call: FunctionCallExprSyntax) -> Int {
    (call.trailingClosure == nil ? 0 : 1) + call.additionalTrailingClosures.count
}

/// Splits a display name like `f(_:action:)` back into its base name and labels.
func parseDisplayName(_ display: String) -> (base: String, labels: [String]) {
    guard let open = display.firstIndex(of: "("), display.hasSuffix(")") else {
        return (display, [])
    }
    let base = String(display[display.startIndex..<open])
    let inner = display[display.index(after: open)..<display.index(before: display.endIndex)]
    guard !inner.isEmpty else { return (base, []) }
    return (base, inner.split(separator: ":", omittingEmptySubsequences: false)
        .dropLast().map(String.init))
}

/// Whether a call site could be a call to the declaration named by `declaration`.
///
/// With no trailing closure this is exact display-name equality, as before.
///
/// With one, the trailing argument's *label* is not knowable from the call site, because
/// Swift lets an unlabelled trailing closure fill a labelled parameter. Two signals are
/// then available and both are needed. **Arity**: a call passing three arguments cannot be
/// a call to a two-parameter declaration. **The label at the trailing position**: if the
/// declaration labels it, the call is at best ambiguous between this declaration and any
/// sibling with an unlabelled parameter there — and in practice it is usually the sibling.
/// GRDB's `filter(country: String)` calls `filter { $0.country == country }`, which is the
/// closure-taking `filter(_:)`, not itself; arity alone reported it as recursion.
///
/// So a trailing-closure call is asserted to be a self-call only where the declaration
/// leaves those positions unlabelled. Where it does not, nothing is asserted — which is
/// the same answer this checker gives everywhere else it cannot resolve an overload.
func callMatchesDeclaration(
    calleeName: String,
    parenthesizedLabels: [String],
    trailingClosures: Int,
    declaration: String,
    declarationParameterTypes: [String] = []
) -> Bool {
    guard trailingClosures > 0 else {
        return makeFunctionDisplayName(name: calleeName, labels: parenthesizedLabels) == declaration
    }
    let (base, labels) = parseDisplayName(declaration)
    guard base == calleeName else { return false }
    guard labels.count == parenthesizedLabels.count + trailingClosures else { return false }
    guard Array(labels.prefix(parenthesizedLabels.count)) == parenthesizedLabels else { return false }
    guard labels.suffix(trailingClosures).allSatisfy({ $0 == "_" }) else { return false }

    // A trailing closure can only fill a parameter of function type. GRDB's
    // `init(_ base: some DatabaseCancellable)` writes `self.init { base.cancel() }`, which
    // reaches `init(cancel:)` — it cannot be reaching itself, because `some
    // DatabaseCancellable` is not something a closure literal can be.
    guard !declarationParameterTypes.isEmpty else { return true }
    guard declarationParameterTypes.count == labels.count else { return true }
    return declarationParameterTypes.suffix(trailingClosures).allSatisfy { $0.contains("->") }
}

/// Walks a syntax tree looking for `self.init(...)` calls and returns the
/// argument label list of each one.
func collectSelfInitCalls(in node: Syntax) -> [(labels: [String], trailingClosures: Int)] {
    final class Walker: SyntaxVisitor {
        var calls: [(labels: [String], trailingClosures: Int)] = []
        override func visit(_ call: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
               let base = member.base,
               base.trimmedDescription == "self",
               member.declName.baseName.text == "init" {
                calls.append((callArgumentLabels(call.arguments), trailingClosureCount(call)))
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
        /// A single-expression block is that block's value — an implicit return.
        ///
        /// The *shape* is the same one `hasSelfBaseCase` recognises; the *rule* applied to it
        /// is this walker's stricter one, because a branch handing off to another call may be
        /// handing off to the next participant in the cycle. Ignite's `isType(_:)` terminates
        /// on `true` and `false` as `if`-expression branch values, which this could not see.
        override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
            guard node.count == 1, let only = node.first,
                  case .expr(let expression) = only.item else {
                return .visitChildren
            }
            if !expression.is(FunctionCallExprSyntax.self) {
                found = true
            }
            return .visitChildren
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

/// Test seam: runs the per-file analysis on one source string, with no project-wide
/// protocol knowledge. Production goes through `RecursionAuditor.analyzeFile`, which
/// supplies the protocol graph; tests of declaration collection do not need one.
func analyzeSourceForTesting(_ source: String, fileName: String = "/test/Test.swift") -> FileAnalysis {
    let tree = Parser.parse(source: source)
    let converter = SourceLocationConverter(fileName: fileName, tree: tree)
    let visitor = RecursionVisitor(
        fileName: fileName, source: source, converter: converter, protocolNames: [])
    visitor.walk(tree)
    return FileAnalysis(
        diagnostics: visitor.diagnostics,
        declarations: visitor.declarations,
        pendingSelfCalls: visitor.pendingSelfCalls,
        signatureDiscriminators: visitor.signatureDiscriminators
    )
}

/// The `return <call>` branches syntax cannot judge, each with its callee positions.
///
/// These are exactly the returns `hasGuardEarlyExit` walks past: a `return` whose
/// expression is a call, and a single-expression branch value that is a call (the
/// implicit return an `if`/`switch` expression gives each branch). Pass 1 records the
/// position of every callee name inside the expression — `return self.init(impl:
/// .collated(e, n))` yields `init` and `collated` — and Pass 2 asks the index what each
/// name at each position actually is. Which overload a leading-dot member means is
/// decided by contextual type, so recording evidence here and resolving there is the
/// whole design (`TheIndexKnowsWhichBranchReturns.md` §3.1).
func candidateBaseCases(in node: Syntax, converter: SourceLocationConverter) -> [CandidateBaseCase] {
    final class CalleeTokenCollector: SyntaxVisitor {
        let converter: SourceLocationConverter
        var positions: [CalleePosition] = []
        init(converter: SourceLocationConverter) {
            self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }
        override func visit(_ call: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            let nameToken: TokenSyntax?
            if let identifier = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                nameToken = identifier.baseName
            } else if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
                nameToken = member.declName.baseName
            } else {
                nameToken = nil
            }
            if let token = nameToken {
                let location = converter.location(for: token.positionAfterSkippingLeadingTrivia)
                positions.append(CalleePosition(line: location.line, column: location.column))
            }
            return .visitChildren
        }
    }

    final class Walker: SyntaxVisitor {
        let converter: SourceLocationConverter
        var candidates: [CandidateBaseCase] = []
        init(converter: SourceLocationConverter) {
            self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }
        override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
            if let expression = node.expression, expression.is(FunctionCallExprSyntax.self) {
                record(expression)
            }
            return .visitChildren
        }
        /// The single-expression block shape `hasGuardEarlyExit` recognises, restricted
        /// the same way: only a block whose one item is an expression is a branch value.
        override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
            guard node.count == 1, let only = node.first,
                  case .expr(let expression) = only.item,
                  expression.is(FunctionCallExprSyntax.self) else {
                return .visitChildren
            }
            record(expression)
            return .visitChildren
        }
        private func record(_ expression: ExprSyntax) {
            let collector = CalleeTokenCollector(converter: converter)
            collector.walk(expression)
            // A call whose callee shape we cannot name (a closure invocation, a
            // key-path application) records no position, and a candidate with no
            // positions must not exist: Pass 2 would have nothing to check and an
            // empty check must not read as "every name exits".
            guard !collector.positions.isEmpty else { return }
            candidates.append(CandidateBaseCase(calleePositions: collector.positions))
        }
    }
    let walker = Walker(converter: converter)
    walker.walk(node)
    return walker.candidates
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
func findRecursiveCalls(in body: Syntax, ownSignature: Signature, ownParameterTypes: [String] = []) -> [FunctionCallExprSyntax] {
    final class Walker: SyntaxVisitor {
        let target: Signature
        let parameterTypes: [String]
        var hits: [FunctionCallExprSyntax] = []
        init(target: Signature, parameterTypes: [String]) {
            self.target = target
            self.parameterTypes = parameterTypes
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
                if callMatchesDeclaration(
                    calleeName: name,
                    parenthesizedLabels: callArgumentLabels(call.arguments),
                    trailingClosures: trailingClosureCount(call),
                    declaration: target.displayName,
                    declarationParameterTypes: parameterTypes
                ) {
                    hits.append(call)
                }
            }
            return .visitChildren
        }
    }
    let walker = Walker(target: ownSignature, parameterTypes: ownParameterTypes)
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
                // A trailing closure contributes an argument the parenthesized list does
                // not show. Spelling it `_` is right whenever the parameter is unlabelled,
                // which is the common case (`map { }`, `withLock { }`), and where it is
                // not, the candidate simply fails to match — which beats today's behaviour
                // of matching a *shorter* declaration that the call cannot be to.
                let labels = callArgumentLabels(call.arguments)
                    + Array(repeating: "_", count: trailingClosureCount(call))
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
/// Functions that run a closure later, on a stack this one does not own.
///
/// Deliberately a short, named list rather than a general rule about closures. Measured
/// across the 22-package corpus, 93% of closure-enclosed self-references are handed to
/// something that runs them *immediately* — `map`, `withLock`, `withLockedValue`,
/// `withCriticalRegion` — so containment alone says nothing about deferral. Naming the
/// executors fails safe: an unlisted receiver keeps the reference visible, so the list
/// being incomplete costs precision, never recall.
private let deferringReceivers: Set<String> = [
    "execute", "scheduleTask", "scheduleRepeatedTask", "scheduleRepeatedAsyncTask",
    "async", "asyncAfter", "asyncDetached", "detached", "addTask", "addTaskUnlessCancelled",
    "submit", "enqueue", "setTimeout", "whenComplete", "whenSuccess", "whenFailure",
    "Task", "notify",
]

/// Whether this closure is handed to one of `deferringReceivers`.
///
/// Note `sync` is absent: `DispatchQueue.sync { }` runs the closure on this stack, so a
/// self-reference inside it recurses exactly as a bare one would.
func isDeferredClosure(_ closure: ClosureExprSyntax) -> Bool {
    var current: Syntax? = closure.parent
    while let node = current {
        if let call = node.as(FunctionCallExprSyntax.self) {
            if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
                return deferringReceivers.contains(member.declName.baseName.text)
            }
            if let ident = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                return deferringReceivers.contains(ident.baseName.text)
            }
            return false
        }
        // A nested closure belongs to its own receiver, not to an outer one.
        if node.is(ClosureExprSyntax.self) { return false }
        current = node.parent
    }
    return false
}

/// Whether `name` is referenced in `node`, ignoring references that only occur inside a
/// closure handed to an executor — those run on a different stack and are not recursion.
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
            // swift-nio's `isFulfilled` reads itself inside `eventLoop.execute { … }` and
            // says so in a comment: the closure runs later, on the event loop, where the
            // other branch is taken. Three corpus errors were that shape.
            if isDeferredClosure(node) { return .skipChildren }
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
