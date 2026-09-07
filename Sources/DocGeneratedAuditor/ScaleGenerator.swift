import Foundation
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// Generates the package's headline counts — targets and registered checkers.
///
/// ## Why this region exists
///
/// These numbers drifted three times, and every correction was somebody noticing by accident:
///
/// | | tests | suites / targets | checkers |
/// | --- | --- | --- | --- |
/// | until 2026-08-12 | 1,662+ | 211+ | 29 |
/// | until 2026-09-07 | 2,809 | 362 | 42 |
/// | README, same day | 3,326 | 59 test targets | 45 |
/// | measured | 3,213 | 433 / 60 | 46 |
///
/// Three documents asserting three different answers, none matching `Package.swift`. The master
/// plan had already diagnosed itself — *"nothing derives the three numbers above … the only
/// thing keeping them true is somebody re-counting"* — and being right about that did not stop
/// it happening twice more. A claim maintained by vigilance is a claim with a half-life.
///
/// ## What it deliberately does not generate
///
/// **The test and suite totals.** `RegionGenerator` may read only files under `projectRoot`, and
/// those numbers exist only after `swift test` runs: `@Test(arguments:)` expands to one run per
/// argument, so counting declarations statically produces a smaller, different number.
///
/// Emitting a static count under a label readers would take for the run count would be the same
/// error in new clothes — a figure that looks derived while answering a question nobody asked.
/// So the run totals stay outside this region, carrying the date they were measured, and what is
/// inside it is only what the tree can prove.
public struct ScaleGenerator: RegionGenerator {

    /// The id that appears in the region's delimiters.
    public let id = "scale"

    /// What a reader should check when this region disagrees with the document.
    public let derivedFrom =
        "the targets declared in Package.swift and the `checkerRegistry` array in QualityGateCLI.swift"

    /// Creates the generator.
    public init() {}

    /// The counts, one per line.
    ///
    /// - Parameters:
    ///   - projectRoot: The package root; `Package.swift` and the CLI registry are read.
    ///   - currentBody: Unused — every line here is computed, so there is nothing of the
    ///     author's to preserve.
    ///   - configuration: Unused by this generator.
    /// - Returns: The lines, newline-separated, with no trailing newline.
    /// - Throws: ``RegionGeneratorError/ungeneratable(reason:)`` when the manifest or the
    ///   registry cannot be read. A count nothing derived is worse than no count.
    public func generate(
        projectRoot: URL, currentBody: String, configuration: Configuration
    ) throws -> String {
        guard let sourceTargets = PackageTargets.load(projectRoot: projectRoot) else {
            throw RegionGeneratorError.ungeneratable(
                reason: "`Package.swift` is absent or declares no targets, so there is nothing "
                    + "to count. A zero here would be a claim, not a measurement.")
        }
        let testTargets = PackageTargets.testTargetNames(projectRoot: projectRoot)
        let checkers = try Self.registeredCheckerCount(projectRoot: projectRoot)

        return [
            "- **\(sourceTargets.count + testTargets.count) targets** — "
                + "\(sourceTargets.count) source, \(testTargets.count) test",
            "- **\(checkers) registered checkers**",
        ].joined(separator: "\n")
    }

    /// How many checkers `checkerRegistry` registers.
    private static func registeredCheckerCount(projectRoot: URL) throws -> Int {
        let registry = projectRoot
            .appendingPathComponent("Sources/QualityGateCLI/QualityGateCLI.swift")
        guard let source = SourceFileReader.read(registry, checker: "doc-generated") else {
            throw RegionGeneratorError.ungeneratable(
                reason: "`Sources/QualityGateCLI/QualityGateCLI.swift` is absent or unreadable, "
                    + "so the checker count cannot be derived.")
        }
        let collector = RegistryCountCollector(viewMode: .sourceAccurate)
        collector.walk(Parser.parse(source: source))
        guard collector.count > 0 else {
            throw RegionGeneratorError.ungeneratable(
                reason: "No `checkerRegistry` array literal was found. Reporting zero checkers "
                    + "would claim this package ships none.")
        }
        return collector.count
    }

    /// Counts the elements of the `checkerRegistry` array, and only there.
    ///
    /// Deliberately a count rather than a name list: ``CheckerTableGenerator`` already owns
    /// naming them, and two generators resolving the same names independently is two places to
    /// disagree.
    private final class RegistryCountCollector: SyntaxVisitor {
        var count = 0

        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            guard node.name.text == "checkerRegistry" else { return .skipChildren }
            guard let array = Self.firstArray(in: Syntax(node)) else { return .skipChildren }
            for element in array.elements
            where element.expression.as(FunctionCallExprSyntax.self)?
                .calledExpression.as(DeclReferenceExprSyntax.self) != nil {
                count += 1
            }
            return .skipChildren
        }

        /// The registry's own array, which is the first one in the function.
        private static func firstArray(in node: Syntax) -> ArrayExprSyntax? {
            if let array = node.as(ArrayExprSyntax.self) { return array }
            for child in node.children(viewMode: .sourceAccurate) {
                if let found = firstArray(in: child) { return found }
            }
            return nil
        }
    }
}
