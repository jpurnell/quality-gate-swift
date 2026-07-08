import Foundation
import SwiftSyntax
import SwiftParser

/// The kind of a public declaration discovered on a module's surface.
enum PublicSymbolKind: String, Sendable, Codable, Equatable {
    case classDecl = "class"
    case structDecl = "struct"
    case enumDecl = "enum"
    case protocolDecl = "protocol"
    case actorDecl = "actor"
    case function
    case property
    case typealiasDecl = "typealias"
    case initializer

    /// Whether this is a type declaration.
    ///
    /// The over-public rule considers only *types*: a public type used solely
    /// within its module is a clean "could be internal" signal, whereas a public
    /// *member* of a public type is part of that type's contract, not an
    /// independent over-exposure.
    var isType: Bool {
        switch self {
        case .classDecl, .structDecl, .enumDecl, .protocolDecl, .actorDecl:
            return true
        case .function, .property, .typealiasDecl, .initializer:
            return false
        }
    }
}

/// A single `public` or `open` declaration on a module's API surface.
///
/// This is the structural (SwiftSyntax) view of the surface — it records *what is
/// exposed* and how it is documented, independent of whether the symbol is
/// actually referenced anywhere. Reference facts come from the IndexStore pass;
/// joining the two is what lets the analyzer distinguish "over-exposed but alive"
/// (a legibility concern) from "dead" (owned by `UnreachableCodeAuditor`).
struct PublicSymbol: Sendable, Codable, Equatable {
    /// The declared name (for initializers, `"init"`).
    let name: String

    /// The kind of declaration.
    let kind: PublicSymbolKind

    /// 1-based line of the declaration.
    let line: Int

    /// Whether the declaration is `open` (as opposed to `public`).
    let isOpen: Bool

    /// Whether a doc comment (`///` or `/** */`) precedes the declaration.
    let hasDocComment: Bool

    /// Whether an acknowledgment marker (e.g. `// legibility:reserved`) precedes
    /// the declaration, deliberately opting it out of the over-public rule.
    let hasReservedMarker: Bool

    /// Creates a public-symbol record.
    init(
        name: String,
        kind: PublicSymbolKind,
        line: Int,
        isOpen: Bool,
        hasDocComment: Bool,
        hasReservedMarker: Bool
    ) {
        self.name = name
        self.kind = kind
        self.line = line
        self.isOpen = isOpen
        self.hasDocComment = hasDocComment
        self.hasReservedMarker = hasReservedMarker
    }
}

/// Scans Swift source for its `public`/`open` declarations using SwiftSyntax.
///
/// Symbols are returned in source order. Nested public members (e.g. a `public`
/// method of a `public` struct) are included, since they too widen the apparent
/// contract a reader must account for.
struct PublicSurfaceScanner: Sendable {

    /// Creates a public-surface scanner.
    init() {}

    /// Scans `source` and returns its public/open declarations in source order.
    ///
    /// - Parameters:
    ///   - source: Swift source text.
    ///   - fileName: Name used for line resolution (diagnostics only).
    ///   - reservedMarker: Substring that, when present in a declaration's leading
    ///     comment, marks it as an acknowledged over-public exception.
    func scan(
        source: String,
        fileName: String = "<source>",
        reservedMarker: String = "legibility:reserved"
    ) -> [PublicSymbol] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let visitor = PublicSurfaceVisitor(converter: converter, reservedMarker: reservedMarker)
        visitor.walk(tree)
        return visitor.symbols
    }
}

private final class PublicSurfaceVisitor: SyntaxVisitor {
    private let converter: SourceLocationConverter
    private let reservedMarker: String
    private(set) var symbols: [PublicSymbol] = []

    init(converter: SourceLocationConverter, reservedMarker: String) {
        self.converter = converter
        self.reservedMarker = reservedMarker
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node, modifiers: node.modifiers, name: node.name.text, kind: .function)
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node, modifiers: node.modifiers, name: node.name.text, kind: .structDecl)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node, modifiers: node.modifiers, name: node.name.text, kind: .classDecl)
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node, modifiers: node.modifiers, name: node.name.text, kind: .actorDecl)
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node, modifiers: node.modifiers, name: node.name.text, kind: .enumDecl)
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node, modifiers: node.modifiers, name: node.name.text, kind: .protocolDecl)
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node, modifiers: node.modifiers, name: node.name.text, kind: .typealiasDecl)
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard isPublic(node.modifiers) else { return .visitChildren }
        guard
            let firstBinding = node.bindings.first,
            let identifier = firstBinding.pattern.as(IdentifierPatternSyntax.self)
        else { return .visitChildren }
        record(node, modifiers: node.modifiers, name: identifier.identifier.text, kind: .property)
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node, modifiers: node.modifiers, name: "init", kind: .initializer)
        return .visitChildren
    }

    // MARK: - Helpers

    private func record(
        _ node: some SyntaxProtocol,
        modifiers: DeclModifierListSyntax,
        name: String,
        kind: PublicSymbolKind
    ) {
        guard isPublic(modifiers) else { return }
        let location = node.startLocation(converter: converter)
        symbols.append(
            PublicSymbol(
                name: name,
                kind: kind,
                line: location.line,
                isOpen: isOpen(modifiers),
                hasDocComment: hasDocComment(node),
                hasReservedMarker: hasReservedMarker(node)
            )
        )
    }

    private func isPublic(_ modifiers: DeclModifierListSyntax) -> Bool {
        for modifier in modifiers {
            if modifier.name.tokenKind == .keyword(.public) || modifier.name.tokenKind == .keyword(.open) {
                return true
            }
        }
        return false
    }

    private func isOpen(_ modifiers: DeclModifierListSyntax) -> Bool {
        for modifier in modifiers where modifier.name.tokenKind == .keyword(.open) {
            return true
        }
        return false
    }

    private func hasDocComment(_ node: some SyntaxProtocol) -> Bool {
        for piece in node.leadingTrivia {
            switch piece {
            case .docLineComment, .docBlockComment:
                return true
            default:
                continue
            }
        }
        return false
    }

    private func hasReservedMarker(_ node: some SyntaxProtocol) -> Bool {
        for piece in node.leadingTrivia {
            switch piece {
            case .lineComment(let text), .blockComment(let text):
                if text.contains(reservedMarker) { return true }
            default:
                continue
            }
        }
        return false
    }
}
