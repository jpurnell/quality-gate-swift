import Foundation
import SwiftParser
import SwiftSyntax

/// The named ranges a `contains` test may be read against.
///
/// `guard (1.0..<1e10).contains(df)` has always bounded `df`. The same test against a
/// name — `guard degreesOfFreedomRange.contains(df)` — did not, because a name could
/// be a `Set`, and membership of a set bounds nothing. A name is accepted here only
/// when it can be nothing else: a `let` whose value is a range between two numeric
/// literals.
struct FallbackRangeConstants: Sendable, Equatable {

    /// Names of members and file-scope constants that are a constant literal range
    /// in every declaration this file makes of them, whether member, local, parameter
    /// or pattern.
    ///
    /// A *local* range constant is not here. It vouches for the body that declares
    /// it — which the body's own facts read — and not for a member of the same name
    /// used bare in another function.
    var names: Set<String> = []

    /// `Type.member` spellings of the members among them.
    var qualifiedNames: Set<String> = []

    /// Names this file declares as anything else. Kept so that a project-wide
    /// reading can withdraw a constant another file contradicts.
    var otherNames: Set<String> = []

    /// `Type.member` constants declared anywhere in the project and contradicted
    /// nowhere in it.
    var projectQualifiedNames: Set<String> = []

    /// No constants.
    static let none = FallbackRangeConstants()

    /// True if `base`, the receiver of a `contains` call, names a constant range.
    ///
    /// - Parameter base: The expression `contains` is called on.
    func isConstantRange(_ base: ExprSyntax) -> Bool {
        if let reference = base.as(DeclReferenceExprSyntax.self) {
            return names.contains(reference.baseName.text)
        }
        guard let member = base.as(MemberAccessExprSyntax.self), let owner = member.base else {
            return false
        }
        let name = member.declName.baseName.text
        // `self.allowed`, `Self.allowed`.
        if let reference = owner.as(DeclReferenceExprSyntax.self),
           reference.baseName.text == "self" || reference.baseName.text == "Self" {
            return names.contains(name)
        }
        // `Limits.allowed`, `Outer.Limits.allowed`: matched on the last two components.
        let ownerName: String
        if let reference = owner.as(DeclReferenceExprSyntax.self) {
            ownerName = reference.baseName.text
        } else if let nested = owner.as(MemberAccessExprSyntax.self) {
            ownerName = nested.declName.baseName.text
        } else {
            return false
        }
        let qualified = ownerName + "." + name
        return qualifiedNames.contains(qualified) || projectQualifiedNames.contains(qualified)
    }
}

/// Collects ``FallbackRangeConstants`` from one file.
///
/// Every binding of a name is read, not only members: a parameter called `allowed`
/// shadows a constant called `allowed`, and syntax cannot say which one a use refers
/// to. One declaration that is not a constant range withdraws the name.
final class FallbackRangeConstantCollector: SyntaxVisitor {
    private var constantCounts: [String: Int] = [:]
    private var qualified: Set<String> = []
    private var otherNames: Set<String> = []
    private var accepted: Set<SyntaxIdentifier> = []
    private var typeNames: [String] = []

    /// Creates a collector.
    init() {
        super.init(viewMode: .sourceAccurate)
    }

    /// Collects the constant ranges one parsed file declares.
    static func collect(from tree: SourceFileSyntax) -> FallbackRangeConstants {
        let collector = FallbackRangeConstantCollector()
        collector.walk(tree)
        let names = Set(collector.constantCounts.keys).subtracting(collector.otherNames)
        return FallbackRangeConstants(
            names: names,
            qualifiedNames: collector.qualified.filter { spelling in
                guard let dot = spelling.lastIndex(of: ".") else { return false }
                return names.contains(String(spelling[spelling.index(after: dot)...]))
            },
            otherNames: collector.otherNames
        )
    }

    /// True for `1..<1e10` and `-90.0...90.0`: both ends numeric literals.
    ///
    /// `1...` and `0...Double.infinity` are not: a range with an open or infinite
    /// end contains `1e300`.
    static func isLiteralRange(_ expr: ExprSyntax) -> Bool {
        let parts: [ExprSyntax]
        if let sequence = expr.as(SequenceExprSyntax.self) {
            parts = Array(sequence.elements)
        } else if let infix = expr.as(InfixOperatorExprSyntax.self) {
            parts = [infix.leftOperand, infix.operator, infix.rightOperand]
        } else {
            return false
        }
        guard parts.count == 3,
              let op = parts[1].as(BinaryOperatorExprSyntax.self),
              op.operator.text == "..." || op.operator.text == "..<" else {
            return false
        }
        return FallbackTypes.isSignedNumericLiteral(parts[0]) && FallbackTypes.isSignedNumericLiteral(parts[2])
    }

    // MARK: Type names

    private func enter(_ name: String) -> SyntaxVisitorContinueKind {
        typeNames.append(name)
        return .visitChildren
    }

    private func leave() {
        guard !typeNames.isEmpty else { return }
        typeNames.removeLast()
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text) }
    override func visitPost(_ node: StructDeclSyntax) { leave() }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text) }
    override func visitPost(_ node: ClassDeclSyntax) { leave() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text) }
    override func visitPost(_ node: ActorDeclSyntax) { leave() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text) }
    override func visitPost(_ node: EnumDeclSyntax) { leave() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        // `extension Outer.Limits` declares members of `Limits`.
        let spelling = node.extendedType.trimmedDescription
        let last = spelling.split(separator: ".").last.map(String.init) ?? spelling
        return enter(last)
    }

    override func visitPost(_ node: ExtensionDeclSyntax) { leave() }

    // MARK: Bindings

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.bindingSpecifier.tokenKind == .keyword(.let) else { return .visitChildren }
        let isMember = node.parent?.is(MemberBlockItemSyntax.self) == true
        let isFileScope = node.parent?.parent?.parent?.is(SourceFileSyntax.self) == true
        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                  let value = binding.initializer?.value,
                  Self.isLiteralRange(value) else {
                continue
            }
            let name = pattern.identifier.text
            accepted.insert(pattern.id)
            // A local is a constant range and not a contradiction, and is read by the
            // body that declares it.
            guard isMember || isFileScope else { continue }
            constantCounts[name, default: 0] += 1
            if isMember, let owner = typeNames.last {
                qualified.insert(owner + "." + name)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        if !accepted.contains(node.id) {
            otherNames.insert(node.identifier.text)
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        otherNames.insert((node.secondName ?? node.firstName).text)
        return .visitChildren
    }

    override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
        otherNames.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        otherNames.insert((node.secondName ?? node.firstName).text)
        return .visitChildren
    }
}

// MARK: - Across a project

/// Reads the range constants a whole project declares, so that a constant declared in
/// one file bounds a value tested against it in another.
enum FallbackProjectRanges {

    /// The `Type.member` range constants declared in `sources` and contradicted in
    /// none of them.
    ///
    /// A constant is honoured across files only when no file declares its member name
    /// as anything else. Two passes keep that cheap: the files that can declare a
    /// range at all are parsed first, and the rest are parsed only if they mention a
    /// candidate's name.
    ///
    /// - Parameter sources: The text of every file the project audits.
    /// - Returns: The qualified spellings that are safe to honour anywhere.
    static func qualifiedConstants(in sources: [String]) -> Set<String> {
        var candidates: Set<String> = []
        var contradicted: Set<String> = []
        var unread: [String] = []

        for source in sources {
            guard mayDeclareRangeConstant(source) else {
                unread.append(source)
                continue
            }
            let found = FallbackRangeConstantCollector.collect(from: Parser.parse(source: source))
            candidates.formUnion(found.qualifiedNames)
            contradicted.formUnion(found.otherNames)
        }
        guard !candidates.isEmpty else { return [] }

        let memberNames = Set(candidates.compactMap(memberName(of:)))
        for source in unread where memberNames.contains(where: { source.contains($0) }) {
            let found = FallbackRangeConstantCollector.collect(from: Parser.parse(source: source))
            contradicted.formUnion(found.otherNames)
        }
        return candidates.filter { spelling in
            guard let name = memberName(of: spelling) else { return false }
            return !contradicted.contains(name)
        }
    }

    /// True if some line of `source` holds both a `let` and a range operator.
    ///
    /// A range operator alone is in most files — every `0..<count` — and each of those
    /// would be parsed here a second time for nothing. A
    /// constant whose range sits on a different line from its `let` is not found, and
    /// so is not honoured across files: the cheap reading errs towards reporting.
    private static func mayDeclareRangeConstant(_ source: String) -> Bool {
        guard source.contains("...") || source.contains("..<") else { return false }
        return source.split(whereSeparator: \.isNewline).contains { line in
            line.contains("let ") && (line.contains("...") || line.contains("..<"))
        }
    }

    /// `allowed` from `Limits.allowed`.
    private static func memberName(of spelling: String) -> String? {
        guard let dot = spelling.lastIndex(of: ".") else { return nil }
        return String(spelling[spelling.index(after: dot)...])
    }
}
