import Foundation
import SwiftSyntax
import SwiftParser

/// Parses a `Package.swift` manifest and extracts the set of first-party
/// target names.
///
/// This is a structural string-literal scan, not a full SwiftPM evaluation.
/// It looks for any function call expression whose called member is one of
/// `target`, `executableTarget`, `testTarget`, `plugin`, `systemLibrary`,
/// `binaryTarget`, or `macro`, and pulls out the `name:` argument's literal
/// string value when present.
///
/// Returns an empty set if `Package.swift` is missing or unreadable. The
/// caller can then choose whether to skip rules that depend on first-party
/// detection.
enum PackageManifestParser {
    private static let targetFactoryNames: Set<String> = [
        "target",
        "executableTarget",
        "testTarget",
        "plugin",
        "systemLibrary",
        "binaryTarget",
        "macro",
    ]

    /// Reads `<projectRoot>/Package.swift` and returns first-party target names.
    static func firstPartyTargets(at projectRoot: String) -> Set<String> {
        let manifestPath = (projectRoot as NSString).appendingPathComponent("Package.swift")
        guard let source = try? String(contentsOfFile: manifestPath, encoding: .utf8) else {
            return []
        }
        return firstPartyTargets(in: source)
    }

    /// Parses an in-memory `Package.swift` source string. Useful for tests.
    static func firstPartyTargets(in source: String) -> Set<String> {
        let tree = Parser.parse(source: source)
        let collector = TargetNameCollector(viewMode: .sourceAccurate)
        collector.walk(tree)
        return collector.names
    }

    private final class TargetNameCollector: SyntaxVisitor {
        var names: Set<String> = []

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            // Match `.target(name: "Foo", ...)` style calls — the called
            // expression is a MemberAccessExprSyntax whose declName is one
            // of the target factory names. The leading-dot form leaves the
            // base nil (implicit member chain).
            if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
               targetFactoryNames.contains(member.declName.baseName.text),
               let nameArg = node.arguments.first(where: { $0.label?.text == "name" }),
               let literal = nameArg.expression.as(StringLiteralExprSyntax.self),
               let value = literal.representedLiteralValue {
                names.insert(value)
            }
            return .visitChildren
        }
    }
}
