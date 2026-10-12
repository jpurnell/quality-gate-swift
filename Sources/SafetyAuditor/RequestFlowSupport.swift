import ExternalInputSyntax
import Foundation
import SwiftSyntax

// Small readers `RequestFlowCollector` leans on (`AURLIsNotARequest.md` §3.2).

extension ExternalInputFile {
    /// Whether `node` declares a function, in the sense a binding's scope ends at.
    static func isFunctionDeclaration(_ node: Syntax) -> Bool {
        node.is(FunctionDeclSyntax.self) || node.is(InitializerDeclSyntax.self)
            || node.is(AccessorDeclSyntax.self) || node.is(SubscriptDeclSyntax.self)
            || node.is(DeinitializerDeclSyntax.self)
    }
}

/// Same-file `let` constants bound to a plain string literal, with their text.
///
/// The names are `SecurityVisitor.stringLiteralConstants(in:)`'s; this keeps the text as well,
/// because a constant that holds `"https://api.example.com"` fixes the host of every URL that
/// begins with it.
final class ConstantValueReader: SyntaxVisitor {
    private(set) var values: [String: String?] = [:]

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.bindingSpecifier.tokenKind == .keyword(.let) else { return .visitChildren }
        for binding in node.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let literal = binding.initializer?.value.as(StringLiteralExprSyntax.self),
                  !literal.segments.contains(where: { $0.is(ExpressionSegmentSyntax.self) }) else { continue }
            let text = literal.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
            if let known = values[name], known != text {
                values[name] = .some(nil)
            } else {
                values[name] = text
            }
        }
        return .visitChildren
    }
}

/// The first `URL(string:)` from non-literal input inside a mapping closure.
final class DynamicConstructionFinder: SyntaxVisitor {
    private let collector: RequestFlowCollector
    private var found: RequestFlowCollector.Resolved?

    static func first(in closure: ClosureExprSyntax, using collector: RequestFlowCollector) -> RequestFlowCollector.Resolved? {
        let finder = DynamicConstructionFinder(collector: collector)
        finder.walk(closure)
        return finder.found
    }

    private init(collector: RequestFlowCollector) {
        self.collector = collector
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard found == nil else { return .skipChildren }
        found = collector.dynamicConstruction(node)
        return found == nil ? .visitChildren : .skipChildren
    }
}
