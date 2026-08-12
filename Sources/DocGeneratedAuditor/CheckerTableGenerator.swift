import Foundation
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// Generates one section of `README.md`'s checker reference from the registry that decides
/// which checkers actually run.
///
/// ## The drift this closes
///
/// Adding a checker meant remembering to add a README row, and four people did not. By the time
/// this generator was written the count was seven — three of them shipped by the branch that
/// built the mechanism to stop it. The registry is the thing that decides what runs, so it is
/// the thing the reference should be derived from.
///
/// ## Why it parses instead of imports
///
/// `QualityGateCLI` depends on this module, so this module cannot import it back. The generator
/// therefore reads `checkerRegistry`'s array literal with SwiftSyntax and then reads each named
/// type's `id`, `summary` and `category` from its own source — the same shape as
/// ``ErrorRegistryGenerator``, which parses `QualityGateError` rather than reflecting over it.
///
/// That has a consequence worth stating: the `summary` protocol requirement buys the *compile
/// error* when a new checker forgets a description, not this generator's input. Both are worth
/// having, and only the first one was obvious when the requirement was proposed.
///
/// ## What the literal array deliberately excludes
///
/// `PluginChecker` and `CustomRulesChecker` are appended conditionally — they exist only when a
/// project configures them. Documenting them as shipped checkers would describe a package
/// nobody has, so reading only the direct elements of the literal is the correct behaviour
/// rather than a limitation.
public struct CheckerTableGenerator: RegionGenerator {

    /// Shown when a checker's `summary` is empty, so the gap is visible in the table itself.
    static let placeholder = "<!-- needs a `summary` on the checker -->"

    /// The README section this generator fills.
    public let category: CheckerCategory

    /// The id that appears in the region's delimiters, one per section.
    public var id: String { "checker-table-\(category.rawValue)" }

    /// What a reader should check when this region disagrees with the document.
    public var derivedFrom: String {
        "`checkerRegistry` in QualityGateCLI, and each checker's `summary` and `category`"
    }

    /// Creates the generator for one section.
    ///
    /// - Parameter category: The README section whose rows this generator produces.
    public init(category: CheckerCategory) {
        self.category = category
    }

    /// One row per registered checker in this category, in registry order.
    ///
    /// - Parameters:
    ///   - projectRoot: The package root; the CLI's registry and each checker's source are read.
    ///   - currentBody: Ignored. Every column is derived, so a row that disagrees is drift.
    ///   - configuration: Unused by this generator.
    /// - Returns: The rows, newline-separated, with no trailing newline. Empty when no
    ///   registered checker claims this category.
    /// - Throws: ``RegionGeneratorError/ungeneratable(reason:)`` when the registry cannot be
    ///   read, or when a registered type's source cannot be found — a table that silently
    ///   shortened itself would be the one failure a generated reference must not have.
    public func generate(
        projectRoot: URL, currentBody: String, configuration: Configuration
    ) throws -> String {
        let registry = projectRoot
            .appendingPathComponent("Sources/QualityGateCLI/QualityGateCLI.swift")
        guard let source = try? String(contentsOf: registry, encoding: .utf8) else { // silent: an unreadable registry is turned into the `ungeneratable` finding below, which names the file
            throw RegionGeneratorError.ungeneratable(
                reason: "`Sources/QualityGateCLI/QualityGateCLI.swift` is absent or unreadable, "
                    + "so there is no registry to derive the checker reference from.")
        }

        let collector = RegistryCollector(viewMode: .sourceAccurate)
        collector.walk(Parser.parse(source: source))
        guard !collector.types.isEmpty else {
            throw RegionGeneratorError.ungeneratable(
                reason: "No `checkerRegistry` array literal was found. An empty reference would "
                    + "claim this package ships no checkers.")
        }

        let declarations = Self.declarations(under: projectRoot)
        var rows: [String] = []
        for type in collector.types {
            guard let checker = declarations[type] else {
                throw RegionGeneratorError.ungeneratable(
                    reason: "`\(type)` is registered in `checkerRegistry` but no declaration for "
                        + "it was found under Sources/. Omitting it would shorten the reference "
                        + "without saying so.")
            }
            guard checker.category == category else { continue }
            let summary = checker.summary.isEmpty ? Self.placeholder : checker.summary
            rows.append("| `\(checker.id)` | \(checker.module) | \(summary) |")
        }
        return rows.joined(separator: "\n")
    }

    /// One checker, as its source declares it.
    struct Declaration {
        let id: String
        let summary: String
        let category: CheckerCategory
        let module: String
    }

    /// Every `QualityChecker` declaration under `Sources/`, keyed by type name.
    ///
    /// Walked once per generate rather than per type: six generators over forty-odd checkers
    /// would otherwise re-read the tree hundreds of times for a table that fits on a screen.
    static func declarations(under projectRoot: URL) -> [String: Declaration] {
        let sources = projectRoot.appendingPathComponent("Sources", isDirectory: true)
        let manager = FileManager.default
        guard let walker = manager.enumerator(
            at: sources, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var found: [String: Declaration] = [:]
        for case let file as URL in walker where file.pathExtension == "swift" {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { // silent: one unreadable file must not empty the whole reference; a type that is never found is reported by the caller as ungeneratable
                continue
            }
            guard source.contains("QualityChecker") || source.contains("FixableChecker") else {
                continue
            }
            let collector = DeclarationCollector(
                module: PackageTargets.module(of: file, under: sources),
                viewMode: .sourceAccurate)
            collector.walk(Parser.parse(source: source))
            found.merge(collector.declarations) { existing, _ in existing }
        }
        return found
    }

    /// Reads the type names constructed directly in `checkerRegistry`'s array literal.
    private final class RegistryCollector: SyntaxVisitor {
        var types: [String] = []

        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            guard node.name.text == "checkerRegistry" else { return .skipChildren }
            guard let array = Self.firstArray(in: Syntax(node)) else { return .skipChildren }
            for element in array.elements {
                guard let call = element.expression.as(FunctionCallExprSyntax.self),
                      let callee = call.calledExpression.as(DeclReferenceExprSyntax.self)
                else {
                    continue
                }
                types.append(callee.baseName.text)
            }
            return .skipChildren
        }

        /// The registry's own array, which is the first one in the function.
        ///
        /// The conditional tails (`+ configuration.plugins.map { … }`, and the ternary that
        /// appends custom rules) contain arrays too, and neither lists a shipped checker.
        private static func firstArray(in node: Syntax) -> ArrayExprSyntax? {
            for child in node.children(viewMode: .sourceAccurate) {
                if let array = child.as(ArrayExprSyntax.self), !array.elements.isEmpty {
                    return array
                }
                if let nested = firstArray(in: child) { return nested }
            }
            return nil
        }
    }

    /// Reads `id`, `summary` and `category` off each checker declaration in one file.
    private final class DeclarationCollector: SyntaxVisitor {
        let module: String
        var declarations: [String: Declaration] = [:]

        init(module: String, viewMode: SyntaxTreeViewMode) {
            self.module = module
            super.init(viewMode: viewMode)
        }

        override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
            collect(name: node.name.text, members: node.memberBlock.members)
            return .skipChildren
        }

        override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
            collect(name: node.name.text, members: node.memberBlock.members)
            return .skipChildren
        }

        private func collect(name: String, members: MemberBlockItemListSyntax) {
            var values: [String: String] = [:]
            var category: CheckerCategory?

            for member in members {
                guard let variable = member.decl.as(VariableDeclSyntax.self),
                      let binding = variable.bindings.first,
                      let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?
                          .identifier.text,
                      let initializer = binding.initializer?.value
                else {
                    continue
                }
                if let literal = initializer.as(StringLiteralExprSyntax.self) {
                    values[identifier] = literal.segments.description
                } else if identifier == "category",
                          let member = initializer.as(MemberAccessExprSyntax.self) {
                    category = CheckerCategory(caseName: member.declName.baseName.text)
                }
            }

            guard let id = values["id"], let summary = values["summary"], let category else {
                return
            }
            declarations[name] = Declaration(
                id: id, summary: summary, category: category, module: module)
        }
    }
}

extension CheckerCategory {

    /// The category a Swift case name refers to, for reading `CheckerCategory.x` out of source.
    ///
    /// The case name and the raw value differ for the hyphenated ones (`safetySecurity` against
    /// `safety-security`), and source spells the case, not the raw value.
    init?(caseName: String) {
        let match = Self.allCases.first { category in
            String(describing: category) == caseName
        }
        guard let match else { return nil }
        self = match
    }
}
