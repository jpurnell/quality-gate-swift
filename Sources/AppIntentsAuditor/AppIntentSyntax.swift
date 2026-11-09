import SwiftSyntax

/// Syntax readings shared by the per-file visitor and the project-wide passes, so the two
/// cannot disagree about what a tool intent or a conformance is.
enum AppIntentSyntax {

    /// `@AppIntent(.tool)` or `@AppIntent(.tool, schema:)`: the unlabeled `.tool` argument.
    static func hasToolTrait(_ attributes: AttributeListSyntax) -> Bool {
        for attr in attributes {
            guard let attribute = attr.as(AttributeSyntax.self),
                  attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "AppIntent",
                  let args = attribute.arguments?.as(LabeledExprListSyntax.self) else { continue }
            if args.contains(where: {
                $0.label == nil && $0.expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "tool"
            }) { return true }
        }
        return false
    }

    /// The simple names in an inheritance clause. A qualified name (`AppIntents.IndexedEntity`)
    /// is not an identifier type and is not read.
    static func inheritedTypeNames(_ clause: InheritanceClauseSyntax?) -> Set<String> {
        guard let clause else { return [] }
        var names: Set<String> = []
        for inherited in clause.inheritedTypes {
            if let id = inherited.type.as(IdentifierTypeSyntax.self) {
                names.insert(id.name.text)
            }
        }
        return names
    }

    /// Every identifier a type mentions, so `[Book]?`, `Array<Book>` and
    /// `some IntentResult & ReturnsValue<Book>` all yield `Book`.
    static func identifiers(in type: TypeSyntax) -> Set<String> {
        var names: Set<String> = []
        for token in type.tokens(viewMode: .sourceAccurate) {
            if case .identifier(let text) = token.tokenKind { names.insert(text) }
        }
        return names
    }
}
