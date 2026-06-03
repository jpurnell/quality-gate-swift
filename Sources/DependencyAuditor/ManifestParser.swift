import SwiftSyntax
import SwiftParser

enum ManifestParser {
    struct ManifestInfo: Sendable {
        var packageURLs: [String] = []
        var declaredNames: [String] = []
        var targetNames: [String] = []
        var productNames: [String] = []
        var excludePaths: [String] = []
    }

    static func parse(source: String) -> ManifestInfo {
        let tree = Parser.parse(source: source)
        let visitor = ManifestVisitor(viewMode: .sourceAccurate)
        visitor.walk(tree)
        return visitor.info
    }
}

private final class ManifestVisitor: SyntaxVisitor {
    var info = ManifestParser.ManifestInfo()

    private static let targetFactories: Set<String> = [
        "target", "executableTarget", "testTarget", "plugin",
        "systemLibrary", "binaryTarget", "macro",
    ]

    private static let productFactories: Set<String> = [
        "library", "executable", "plugin", "product",
    ]

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self) else {
            return .visitChildren
        }

        let name = memberAccess.declName.baseName.text

        if name == "package" {
            if let url = stringArgument(labeled: "url", in: node) {
                info.packageURLs.append(url)
            }
            if let declaredName = stringArgument(labeled: "name", in: node) {
                info.declaredNames.append(declaredName)
            }
        }

        if Self.targetFactories.contains(name) {
            if let targetName = stringArgument(labeled: "name", in: node) {
                info.targetNames.append(targetName)
            }
            if let excludeArg = node.arguments.first(where: { $0.label?.text == "exclude" }),
               let arrayExpr = excludeArg.expression.as(ArrayExprSyntax.self) {
                for element in arrayExpr.elements {
                    if let path = stringLiteralValue(element.expression) {
                        info.excludePaths.append(path)
                    }
                }
            }
        }

        if Self.productFactories.contains(name) {
            if let productName = stringArgument(labeled: "name", in: node) {
                info.productNames.append(productName)
            }
        }

        return .visitChildren
    }

    private func stringArgument(labeled label: String, in call: FunctionCallExprSyntax) -> String? {
        for arg in call.arguments {
            guard arg.label?.text == label else { continue }
            return stringLiteralValue(arg.expression)
        }
        return nil
    }

    private func stringLiteralValue(_ expr: ExprSyntax) -> String? {
        guard let literal = expr.as(StringLiteralExprSyntax.self),
              literal.segments.count == 1,
              let segment = literal.segments.first?.as(StringSegmentSyntax.self) else {
            return nil
        }
        return segment.content.text
    }
}
