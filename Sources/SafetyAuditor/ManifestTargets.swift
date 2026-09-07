import Foundation
import QualityGateCore
import SwiftSyntax
import SwiftParser
#if canImport(os)
import os
#endif

extension TargetTypeMap {

    /// Builds the map by **parsing** `Package.swift`, resolving nothing.
    ///
    /// ## Why not `swift package describe`
    ///
    /// `describe` evaluates the manifest properly, which means SwiftPM compiles `Package.swift`
    /// into an executable, runs it, and resolves the dependency graph to do so. Surveying nine
    /// third-party packages that way wrote **2.7 GB** into repositories the operator does not
    /// own — proven by their `.build` directories all carrying timestamps inside the scan
    /// window — and took 34 minutes, most of it network.
    ///
    /// None of it was needed. The checkers read the AST through `Parser.parse(source:)`, which
    /// works on text: a package whose dependencies cannot be resolved at all still parses and
    /// still reports its force unwraps. The manifest was wanted for one thing — deciding
    /// whether a file sits in an executable, a library, a test or a plugin, so `TrapPolicy`
    /// can pick a severity — and that is a question about the manifest's *syntax*.
    ///
    /// So it is read the way this tool reads every other Swift file.
    ///
    /// ## Why the syntax tree rather than a search
    ///
    /// `.plugin`, `.library` and `.executable` appear in `products:` as well as `targets:` —
    /// this package declares `.plugin(` twice and has exactly one plugin *target*. Matching the
    /// call name anywhere in the file would count both. Walking the `targets:` argument of the
    /// `Package(…)` call cannot make that mistake.
    ///
    /// - Parameter packageRoot: Directory containing `Package.swift`.
    /// - Returns: The parsed map, or `TargetTypeMap.fromLayout(packageRoot:)` when there is no
    ///   manifest or it yields nothing.
    public static func parsingManifest(packageRoot: String) -> TargetTypeMap {
        let manifestPath = (packageRoot as NSString).appendingPathComponent("Package.swift")
        guard let source = SourceFileReader.read(manifestPath, checker: "safety") else {
            return .fromLayout(packageRoot: packageRoot)
        }

        let tree = Parser.parse(source: source)
        let collector = ManifestTargetCollector()
        collector.walk(tree)

        // A manifest that parsed but declared nothing recognisable is indistinguishable from a
        // malformed one for this purpose, and the convention is the better answer than an empty
        // map — which would classify every file as `.executable`, the strict reading, for a
        // package whose layout is perfectly ordinary.
        guard !collector.targets.isEmpty else {
            return .fromLayout(packageRoot: packageRoot)
        }
        return TargetTypeMap(targets: collector.targets)
    }
}

/// Collects target declarations from the `targets:` argument of a `Package(…)` call.
private final class ManifestTargetCollector: SyntaxVisitor {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "ManifestTargets")

    /// SwiftPM's target factory names, mapped to the type strings `describe` would have emitted.
    ///
    /// `.macro` resolves to `library`: a macro target is compiled and linked like one, and
    /// `TrapPolicy` only distinguishes "an end user is watching" from "a programmer is".
    private static let targetKinds: [String: String] = [
        "target": "library",
        "executableTarget": "executable",
        "testTarget": "test",
        "plugin": "plugin",
        "macro": "library",
        "systemLibrary": "library",
        "binaryTarget": "library",
    ]

    /// Where each kind lives when the manifest states no explicit `path:`.
    private static let conventionalContainer: [String: String] = [
        "library": "Sources", "executable": "Sources", "test": "Tests", "plugin": "Plugins",
    ]

    private(set) var targets: [TargetTypeMap.Target] = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: LabeledExprSyntax) -> SyntaxVisitorContinueKind {
        // Only the `targets:` argument. `products:` holds `.library`/`.plugin` too, and counting
        // those is the mistake a textual search makes.
        guard node.label?.text == "targets",
              let array = node.expression.as(ArrayExprSyntax.self) else {
            return .visitChildren
        }
        for element in array.elements {
            guard let call = element.expression.as(FunctionCallExprSyntax.self),
                  let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                  let type = Self.targetKinds[member.declName.baseName.text] else { continue }
            guard let name = Self.stringArgument(labelled: "name", of: call) else { continue }

            let path = Self.stringArgument(labelled: "path", of: call)
                ?? "\(Self.conventionalContainer[type] ?? "Sources")/\(name)"
            targets.append(TargetTypeMap.Target(name: name, type: type, path: path))
        }
        // A nested `targets:` inside a target's own dependency list cannot declare a target, and
        // descending would let `.target(name:)` inside `dependencies:` be counted.
        return .skipChildren
    }

    /// The value of a string-literal argument, when it is a plain literal.
    ///
    /// A computed name — `name: prefix + "Tests"` — yields `nil` and the target is skipped
    /// rather than guessed at. That is rare in manifests and a wrong path is worse than a
    /// missing one: it would classify somebody else's files.
    private static func stringArgument(
        labelled label: String, of call: FunctionCallExprSyntax
    ) -> String? {
        for argument in call.arguments where argument.label?.text == label {
            guard let literal = argument.expression.as(StringLiteralExprSyntax.self) else {
                logger.debug("Manifest argument \(label, privacy: .public) is not a literal; skipping")
                return nil
            }
            return literal.representedLiteralValue
        }
        return nil
    }
}
