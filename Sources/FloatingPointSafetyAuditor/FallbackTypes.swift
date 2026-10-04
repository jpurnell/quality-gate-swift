import Foundation
import SwiftSyntax

// MARK: - Type kinds

/// What the `fallback` rules know about the type of a name.
///
/// `other` is a positive statement, not an absence: it means a declaration was
/// seen and it was not floating-point. That is what lets an inner `periods: Int`
/// shadow an outer `periods: Double`. A name with no declaration in reach has no
/// kind at all, and is skipped.
enum FallbackTypeKind: Sendable, Equatable {
    /// A single floating-point value, which may be a NaN.
    case floatingPoint
    /// A single floating-point value that cannot be a NaN: a constant, or a
    /// `let` computed from integers and literals without dividing.
    ///
    /// Floating-point is a type; able-to-be-NaN is a fact about where a value
    /// came from. `let n = Double(count)` is the first and not the second, and a
    /// rule that cannot tell them apart reports every `Int(n * 0.95)`.
    case finiteFloatingPoint
    /// A collection whose elements are floating-point values.
    case floatingPointCollection
    /// Declared, and not floating-point.
    case other
}

// MARK: - Type spellings

/// Reads floating-point-ness out of type spellings and generic clauses.
///
/// Syntax only. Nothing here resolves a typealias, follows an import or asks the
/// compiler; a spelling this does not recognise is `other`, never a guess.
enum FallbackTypes {

    /// Concrete floating-point types, by their usual spelling.
    ///
    /// `TimeInterval` is a typealias for `Double` that Foundation code spells far
    /// more often than the type it stands for. `Decimal` is absent on purpose: it
    /// has no `nan`-trapping `Int` initialiser.
    static let floatingPointTypeNames: Set<String> = [
        "Double", "Float", "CGFloat", "Float16", "Float32", "Float64", "Float80", "TimeInterval"
    ]

    /// Protocols that make a generic parameter floating-point.
    static let floatingPointProtocols: Set<String> = [
        "Real", "BinaryFloatingPoint", "FloatingPoint"
    ]

    /// Integer types whose unlabelled initialiser traps on an unrepresentable value.
    static let integerTypeNames: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64"
    ]

    /// Generic collection types read as "a collection of their argument".
    private static let collectionTypeNames = ["Array", "ArraySlice", "ContiguousArray"]

    /// Classifies a type as written in source.
    ///
    /// - Parameters:
    ///   - raw: The type spelling.
    ///   - genericNames: Generic parameters in scope that are constrained to a
    ///     floating-point protocol.
    ///   - depth: Recursion budget for nested collection spellings. Guarded so the
    ///     walk terminates on any input.
    /// - Returns: The kind the spelling denotes.
    static func kind(
        ofTypeText raw: String,
        genericNames: Set<String>,
        depth: Int = 0
    ) -> FallbackTypeKind {
        guard depth < 4 else { return .other }

        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("?") || text.hasSuffix("!") {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else { return .other }

        if floatingPointTypeNames.contains(text) || genericNames.contains(text) {
            return .floatingPoint
        }
        guard let element = elementTypeText(of: text) else { return .other }
        let elementKind = kind(ofTypeText: element, genericNames: genericNames, depth: depth + 1)
        return elementKind == .floatingPoint ? .floatingPointCollection : .other
    }

    /// The element type of a collection spelling, or nil if `text` is not one.
    private static func elementTypeText(of text: String) -> String? {
        // Sugared array: `[Double]`. A dictionary `[K: V]` is not one.
        if text.hasPrefix("["), text.hasSuffix("]") {
            let inner = String(text.dropFirst().dropLast())
            return inner.contains(":") ? nil : inner
        }
        for generic in collectionTypeNames where text.hasPrefix(generic + "<") && text.hasSuffix(">") {
            return String(text.dropFirst(generic.count + 1).dropLast())
        }
        return nil
    }

    // MARK: Parameters

    /// One parameter, as its body sees it.
    struct Parameter {
        /// The name the body uses: the internal name where there is one.
        let name: String
        /// The type as written, with ownership and attributes removed, or nil
        /// for a closure parameter that has none.
        let typeText: String?
        /// Whether the parameter is variadic — `Double...` is a collection of
        /// `Double`, and its `typeText` is the element's.
        let isVariadic: Bool
    }

    /// A type as written, without what is wrapped around it.
    ///
    /// `inout Double`, `borrowing Double` and `consuming Double` are `Double`:
    /// the specifier says how the value is passed, not what it is. Reading the
    /// whole spelling made every such parameter an unknown type.
    static func spelling(of type: TypeSyntax) -> String {
        if let attributed = type.as(AttributedTypeSyntax.self) {
            return attributed.baseType.trimmedDescription
        }
        return type.trimmedDescription
    }

    /// The parameters of a function, initializer or subscript. `_` is skipped:
    /// the body cannot name it.
    static func parameters(of list: FunctionParameterListSyntax) -> [Parameter] {
        list.compactMap { parameter in
            let name = (parameter.secondName ?? parameter.firstName).text
            guard name != "_" else { return nil }
            return Parameter(
                name: name,
                typeText: spelling(of: parameter.type),
                isVariadic: parameter.ellipsis != nil
            )
        }
    }

    /// The parameters a closure names in its signature. `{ x, d in … }` names
    /// them without types; they are declared all the same, and shadow.
    static func parameters(of signature: ClosureSignatureSyntax?) -> [Parameter] {
        guard let clause = signature?.parameterClause else { return [] }
        switch clause {
        case .simpleInput(let names):
            return names.compactMap { name in
                name.name.text == "_" ? nil : Parameter(name: name.name.text, typeText: nil, isVariadic: false)
            }
        case .parameterClause(let typed):
            return typed.parameters.compactMap { parameter in
                let name = (parameter.secondName ?? parameter.firstName).text
                guard name != "_" else { return nil }
                return Parameter(
                    name: name,
                    typeText: parameter.type.map(spelling(of:)),
                    isVariadic: parameter.ellipsis != nil
                )
            }
        }
    }

    /// True for a `let` whose value is a numeric literal.
    ///
    /// `static let deadline: TimeInterval = 30` is floating-point and is also
    /// thirty, now and at every call. Converting it cannot trap, and there is
    /// nothing a guard could add. A `var` that starts from a literal is only
    /// where it started.
    static func isLiteralConstant(_ binding: PatternBindingSyntax, in declaration: VariableDeclSyntax) -> Bool {
        guard declaration.bindingSpecifier.tokenKind == .keyword(.let),
              let value = binding.initializer?.value else {
            return false
        }
        if let negated = value.as(PrefixOperatorExprSyntax.self), negated.operator.text == "-" {
            return isNumericLiteral(negated.expression)
        }
        return isNumericLiteral(value)
    }

    private static func isNumericLiteral(_ expr: ExprSyntax) -> Bool {
        expr.is(FloatLiteralExprSyntax.self) || expr.is(IntegerLiteralExprSyntax.self)
    }

    /// True if a constraint spelling — `Real`, `Real & Sendable & Codable` —
    /// includes a floating-point protocol.
    static func namesFloatingPointProtocol(_ constraint: String) -> Bool {
        constraint
            .split(separator: "&")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { floatingPointProtocols.contains($0) }
    }

    /// The generic parameters a declaration constrains to floating-point.
    ///
    /// - Parameters:
    ///   - parameters: The declaration's `<T: Real>` clause, if it has one.
    ///   - whereClause: The declaration's `where T: Real` clause, if it has one.
    /// - Returns: The names so constrained. `T == Double` counts.
    static func genericFloatingPointNames(
        parameters: GenericParameterClauseSyntax?,
        whereClause: GenericWhereClauseSyntax?
    ) -> Set<String> {
        var names: Set<String> = []

        if let parameters {
            for parameter in parameters.parameters {
                guard let inherited = parameter.inheritedType else { continue }
                if namesFloatingPointProtocol(inherited.trimmedDescription) {
                    names.insert(parameter.name.text)
                }
            }
        }

        if let whereClause {
            for requirement in whereClause.requirements {
                switch requirement.requirement {
                case .conformanceRequirement(let conformance):
                    if namesFloatingPointProtocol(conformance.rightType.trimmedDescription) {
                        names.insert(conformance.leftType.trimmedDescription)
                    }
                case .sameTypeRequirement(let sameType):
                    if floatingPointTypeNames.contains(sameType.rightType.trimmedDescription) {
                        names.insert(sameType.leftType.trimmedDescription)
                    }
                case .layoutRequirement:
                    continue
                }
            }
        }
        return names
    }
}

// MARK: - File-local declarations

/// What one file declares about its own members and functions.
struct FallbackDeclarations: Sendable {
    /// Member and tuple-label names whose every declaration in the file agrees
    /// on a kind.
    var memberKinds: [String: FallbackTypeKind] = [:]

    /// Function names whose every declaration in the file agrees on a return kind.
    var returnKinds: [String: FallbackTypeKind] = [:]

    /// Floating-point generic parameters of the types the file declares, by type name.
    var typeGenerics: [String: Set<String>] = [:]
}

/// Collects ``FallbackDeclarations`` from one file.
///
/// This is how `entry.tenor` gets a type without a type checker. The label
/// `tenor` is looked up by name, which is only honest while every declaration of
/// that name in the file agrees: a name declared `Double` in one struct and `Int`
/// in another is dropped, because choosing between them needs the type of the
/// base and syntax does not have it. A member declared in another file is never
/// seen, so it stays unknown.
///
/// Run it twice. An extension may precede the type it extends, so the first pass
/// exists to learn every type's generic parameters and the second reads members
/// with those in hand.
final class FallbackDeclarationCollector: SyntaxVisitor {
    private let knownTypeGenerics: [String: Set<String>]

    private var memberKinds: [String: FallbackTypeKind] = [:]
    private var ambiguousMembers: Set<String> = []
    private var returnKinds: [String: FallbackTypeKind] = [:]
    private var ambiguousFunctions: Set<String> = []
    private var typeGenerics: [String: Set<String>] = [:]

    /// Generic floating-point names in scope, innermost last. Each entry already
    /// includes everything enclosing it.
    private var genericStack: [Set<String>] = [[]]

    /// Creates a collector.
    /// - Parameter knownTypeGenerics: Type generics from an earlier pass over
    ///   the same file, used to resolve `T` inside an extension.
    init(knownTypeGenerics: [String: Set<String>] = [:]) {
        self.knownTypeGenerics = knownTypeGenerics
        super.init(viewMode: .sourceAccurate)
    }

    /// Collects declarations from a parsed file, in the two passes the type needs.
    static func collect(from tree: SourceFileSyntax) -> FallbackDeclarations {
        let first = FallbackDeclarationCollector()
        first.walk(tree)
        let second = FallbackDeclarationCollector(knownTypeGenerics: first.typeGenerics)
        second.walk(tree)
        return second.declarations
    }

    /// What the walk found, with every ambiguous name removed.
    var declarations: FallbackDeclarations {
        FallbackDeclarations(
            memberKinds: memberKinds.filter { !ambiguousMembers.contains($0.key) },
            returnKinds: returnKinds.filter { !ambiguousFunctions.contains($0.key) },
            typeGenerics: typeGenerics
        )
    }

    private var genericNames: Set<String> { genericStack.last ?? [] }

    private func push(_ names: Set<String>) {
        genericStack.append(genericNames.union(names))
    }

    private func pop() {
        guard genericStack.count > 1 else { return }
        genericStack.removeLast()
    }

    private func recordMember(_ name: String, kind: FallbackTypeKind) {
        if let existing = memberKinds[name], existing != kind {
            ambiguousMembers.insert(name)
        }
        memberKinds[name] = kind
    }

    private func enterType(
        named name: String,
        parameters: GenericParameterClauseSyntax?,
        whereClause: GenericWhereClauseSyntax?
    ) {
        let own = FallbackTypes.genericFloatingPointNames(parameters: parameters, whereClause: whereClause)
        push(own)
        typeGenerics[name] = genericNames
    }

    // MARK: Types

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(named: node.name.text, parameters: node.genericParameterClause, whereClause: node.genericWhereClause)
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) { pop() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(named: node.name.text, parameters: node.genericParameterClause, whereClause: node.genericWhereClause)
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) { pop() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(named: node.name.text, parameters: node.genericParameterClause, whereClause: node.genericWhereClause)
        return .visitChildren
    }

    override func visitPost(_ node: ActorDeclSyntax) { pop() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(named: node.name.text, parameters: node.genericParameterClause, whereClause: node.genericWhereClause)
        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) { pop() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let own = FallbackTypes.genericFloatingPointNames(parameters: nil, whereClause: node.genericWhereClause)
        let inherited = knownTypeGenerics[node.extendedType.trimmedDescription] ?? []
        push(own.union(inherited))
        return .visitChildren
    }

    override func visitPost(_ node: ExtensionDeclSyntax) { pop() }

    // MARK: Functions

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        push(FallbackTypes.genericFloatingPointNames(
            parameters: node.genericParameterClause,
            whereClause: node.genericWhereClause
        ))

        let name = node.name.text
        guard let returnClause = node.signature.returnClause else {
            // No written return type: it returns nothing, and it makes any
            // sibling of the same name ambiguous.
            ambiguousFunctions.insert(name)
            return .visitChildren
        }
        let kind = FallbackTypes.kind(
            ofTypeText: returnClause.type.trimmedDescription,
            genericNames: genericNames
        )
        if let existing = returnKinds[name], existing != kind {
            ambiguousFunctions.insert(name)
        }
        returnKinds[name] = kind
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) { pop() }

    // MARK: Members and tuple labels

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        // Members only. A local is resolved through the scope stack, where
        // shadowing is known; recording it here would make it answer for every
        // member of the same name in the file.
        guard node.parent?.is(MemberBlockItemSyntax.self) == true else { return .visitChildren }

        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            let name = pattern.identifier.text

            if FallbackTypes.isLiteralConstant(binding, in: node) {
                let annotated = binding.typeAnnotation.map {
                    FallbackTypes.kind(ofTypeText: $0.type.trimmedDescription, genericNames: genericNames)
                }
                let isFloatingPoint = annotated == .floatingPoint
                    || binding.initializer?.value.is(FloatLiteralExprSyntax.self) == true
                recordMember(name, kind: isFloatingPoint ? .finiteFloatingPoint : .other)
            } else if let annotation = binding.typeAnnotation {
                let kind = FallbackTypes.kind(
                    ofTypeText: annotation.type.trimmedDescription,
                    genericNames: genericNames
                )
                recordMember(name, kind: kind)
            } else if binding.initializer?.value.is(FloatLiteralExprSyntax.self) == true {
                recordMember(name, kind: .floatingPoint)
            } else {
                recordMember(name, kind: .other)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: TupleTypeElementSyntax) -> SyntaxVisitorContinueKind {
        guard let label = node.firstName, label.text != "_" else { return .visitChildren }
        let kind = FallbackTypes.kind(ofTypeText: node.type.trimmedDescription, genericNames: genericNames)
        recordMember(label.text, kind: kind)
        return .visitChildren
    }
}
