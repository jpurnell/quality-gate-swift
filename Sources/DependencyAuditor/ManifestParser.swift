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

    /// Whether this factory call is a direct element of `Package(targets:)`.
    ///
    /// Walks up to the enclosing array and asks whether that array is the `targets:`
    /// argument of a `Package(…)` call. A dependency reference sits inside a
    /// `dependencies:` array instead, and fails the test.
    static func declaresTarget(_ node: FunctionCallExprSyntax) -> Bool {
        var current = Syntax(node).parent
        while let syntax = current {
            if let argument = syntax.as(LabeledExprSyntax.self) {
                // LabeledExprSyntax -> LabeledExprListSyntax -> FunctionCallExprSyntax
                if argument.label?.text == "targets",
                   let call = syntax.parent?.parent?.as(FunctionCallExprSyntax.self),
                   call.calledExpression.as(DeclReferenceExprSyntax.self)?
                       .baseName.text == "Package" {
                    return true
                }
                // Reached a labelled argument that is not `Package(targets:)` — a
                // `dependencies:` list. This call is a reference, not a declaration.
                if argument.label != nil { return false }
            }
            current = syntax.parent
        }
        // Reached the top without passing through any labelled argument, so this is a
        // bare `.target(…)` fragment rather than something nested in a manifest.
        // Callers legitimately pass such fragments — `extractExcludePaths` is documented
        // against one — and a fragment is a declaration by construction.
        return true
    }

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

        // Only a factory call that is a *direct element of `Package(targets:)`* declares a
        // target. Two nearby constructs use the same spelling and declare nothing: a
        // dependency written `.target(name: "Beta")`, and a product's `targets: ["Alpha"]`.
        // Counting those invented modules — `extractTargetNames` returned
        // ["Target0", "SomeDependency"] for a manifest declaring one target — and an invented
        // module name makes the hallucinated-import check treat an undeclared import as
        // declared, which is a false negative in the one direction that matters.
        //
        // `DocGeneratedAuditor.PackageTargets` already descends correctly and carries the same
        // comment; this parser did not, and no example test covered a manifest whose target had
        // a `.target(name:)` dependency.
        if Self.targetFactories.contains(name), Self.declaresTarget(node) {
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
