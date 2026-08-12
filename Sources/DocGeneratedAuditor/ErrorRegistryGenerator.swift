import Foundation
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// Generates the error-registry table from the cases of `QualityGateError`.
///
/// This is the role table in its purest form: a set of enum cases, prose adjacent to each,
/// and a document asserting the set is complete. The document that says *"All custom error
/// cases must be registered here before implementation"* was missing a case that shipped with
/// a whole feature, which is the exact failure this generator makes impossible to repeat —
/// after it, the sentence describing a case lives beside the case, and forgetting to write
/// one is visible where it is written rather than in a table nobody opened.
///
/// The `Added` column of the hand-written table is deliberately not produced. A version
/// column cannot be derived from the tree, and a column that cannot be derived is a column
/// that will eventually be wrong.
public struct ErrorRegistryGenerator: RegionGenerator {

    /// The enum whose cases the registry documents.
    public static let enumName = "QualityGateError"

    /// The id that appears in the region's delimiters.
    public let id = "error-registry"

    /// What a reader should check when this region disagrees with the document.
    public let derivedFrom = "the cases of `QualityGateError`, each with its `///` abstract"

    /// Creates the generator.
    public init() {}

    /// One table row per case, in declaration order.
    ///
    /// - Parameters:
    ///   - projectRoot: The package root; only `Sources/` is read.
    ///   - currentBody: Ignored. Every column here is derived, so nothing is preserved —
    ///     which is the point: a description that drifts from the `///` beside the case is
    ///     drift, not authorship.
    ///   - configuration: Unused by this generator.
    /// - Returns: The rows, newline-separated, with no trailing newline.
    /// - Throws: ``RegionGeneratorError/ungeneratable(reason:)`` when the enum is absent.
    public func generate(
        projectRoot: URL, currentBody: String, configuration: Configuration
    ) throws -> String {
        guard let found = Self.locate(enumName: Self.enumName, under: projectRoot) else {
            throw RegionGeneratorError.ungeneratable(
                reason: "No `enum \(Self.enumName)` was found under Sources/, so there is "
                    + "nothing to derive an error registry from.")
        }
        let rows = found.cases.map { entry in
            let description = entry.abstract.isEmpty
                ? "<!-- needs a `///` abstract on the case -->"
                : entry.abstract
            return "| `\(Self.enumName).\(entry.name)` | \(found.module) | \(description) |"
        }
        return rows.joined(separator: "\n")
    }

    /// One case and the prose written beside it.
    struct CaseEntry: Equatable {
        let name: String
        let abstract: String
    }

    /// Where an enum was declared and what it contains.
    struct Located {
        let module: String
        let cases: [CaseEntry]
    }

    /// Finds the enum by walking `Sources/` and parsing each file.
    ///
    /// A file walk is sound here in a way it is not for a roster: the walk decides *where to
    /// look*, and a miss produces a loud `ungeneratable` finding rather than a silently
    /// shortened list.
    static func locate(enumName: String, under projectRoot: URL) -> Located? {
        let sources = projectRoot.appendingPathComponent("Sources", isDirectory: true)
        let manager = FileManager.default
        guard let walker = manager.enumerator(
            at: sources, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let files = walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }

        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { // silent: an unreadable source file is skipped so one bad file cannot make the whole registry ungeneratable; an enum that is never found is still reported
                continue
            }
            guard source.contains("enum \(enumName)") else { continue }
            let collector = EnumCaseCollector(enumName: enumName, viewMode: .sourceAccurate)
            collector.walk(Parser.parse(source: source))
            guard collector.found else { continue }
            return Located(module: module(of: file, under: sources), cases: collector.cases)
        }
        return nil
    }

    /// The module directory a source file belongs to.
    ///
    /// Shared with ``CheckerTableGenerator``, which needs the same answer for the same reason:
    /// the module column names the directory, and the type's own name is not it.
    static func module(of file: URL, under sources: URL) -> String {
        PackageTargets.module(of: file, under: sources)
    }

    /// Collects the cases of one named enum, with the abstract from each case's `///` run.
    private final class EnumCaseCollector: SyntaxVisitor {
        let enumName: String
        var found = false
        var cases: [CaseEntry] = []

        init(enumName: String, viewMode: SyntaxTreeViewMode) {
            self.enumName = enumName
            super.init(viewMode: viewMode)
        }

        override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
            guard node.name.text == enumName else { return .skipChildren }
            found = true
            for member in node.memberBlock.members {
                guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
                let abstract = Self.abstract(from: caseDecl.leadingTrivia)
                for element in caseDecl.elements {
                    cases.append(CaseEntry(name: element.name.text, abstract: abstract))
                }
            }
            return .skipChildren
        }

        /// The first paragraph of a `///` run, joined onto one line.
        ///
        /// A table cell cannot hold a line break, and the abstract is by convention the first
        /// paragraph — so the run is cut at the first blank doc line and the rest is folded
        /// into a single space-separated sentence.
        static func abstract(from trivia: Trivia) -> String {
            var lines: [String] = []
            for piece in trivia {
                switch piece {
                case .docLineComment(let text):
                    let body = text.hasPrefix("///")
                        ? String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                        : text.trimmingCharacters(in: .whitespaces)
                    if body.isEmpty {
                        if !lines.isEmpty { return join(lines) }
                    } else {
                        lines.append(body)
                    }
                case .docBlockComment:
                    continue
                default:
                    continue
                }
            }
            return join(lines)
        }

        private static func join(_ lines: [String]) -> String {
            lines.joined(separator: " ")
                .replacingOccurrences(of: "|", with: "\\|")
                .trimmingCharacters(in: .whitespaces)
        }
    }
}
