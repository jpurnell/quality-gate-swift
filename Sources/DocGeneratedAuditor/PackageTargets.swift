import Foundation
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// The package's own list of what it builds, read from `Package.swift`.
///
/// ## Why the manifest and not a directory walk
///
/// §8.6 of the design is a worked example of the difference. The script that measured revision
/// 1's drift walked `Sources/` and reported two phantom modules; one of them,
/// `QualityGatePlugin`, is a real target that lives under `Plugins/`. The manifest is the only
/// place that knows a target's directory is not implied by its name, and it is also the only
/// place that distinguishes a module from a test target, a fixture directory, or a folder
/// somebody left behind. A roster derived from a walk would have deleted a real module's line.
public enum PackageTargets {

    /// Every non-test target the manifest declares, in declaration order.
    ///
    /// - Parameter projectRoot: The package root.
    /// - Returns: The target names, or `nil` when there is no manifest or it declares no
    ///   `targets:` — which the caller reports as ungeneratable rather than as an empty package.
    ///   A package with genuinely zero targets and a package whose manifest could not be read
    ///   produce the same roster, and only one of those is a document worth rewriting.
    public static func load(projectRoot: URL) -> [String]? {
        let manifest = projectRoot.appendingPathComponent("Package.swift")
        guard let source = try? String(contentsOf: manifest, encoding: .utf8) else { return nil } // silent: an absent or unreadable manifest is the nil case this function is documented to return, and the caller turns it into an `ungeneratable` finding that names the file
        let collector = TargetCollector(viewMode: .sourceAccurate)
        collector.walk(Parser.parse(source: source))
        return collector.names.isEmpty ? nil : collector.names
    }

    /// The abstract from a module's DocC catalogue, if it has one.
    ///
    /// The abstract is DocC's own convention: the first paragraph under the symbol heading. It
    /// is folded onto one line because the roster line it lands in cannot hold a break.
    ///
    /// - Parameters:
    ///   - module: The target name, which is also the catalogue and article name by convention.
    ///   - projectRoot: The package root.
    /// - Returns: The abstract, or `nil` when the module has no catalogue or the article carries
    ///   only headings.
    public static func doccAbstract(of module: String, projectRoot: URL) -> String? {
        let candidates = ["Sources", "Plugins"].map {
            projectRoot
                .appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent(module, isDirectory: true)
                .appendingPathComponent("\(module).docc", isDirectory: true)
                .appendingPathComponent("\(module).md")
        }
        for url in candidates {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue } // silent: most modules have no catalogue at either candidate path, so absence is the ordinary case and produces a visible placeholder rather than an error
            if let abstract = abstract(fromArticle: contents) { return abstract }
        }
        return nil
    }

    /// The module a source file belongs to — the first path component under `Sources/`.
    ///
    /// - Parameters:
    ///   - file: The source file.
    ///   - sources: The `Sources/` directory it was found under.
    /// - Returns: The module directory's name, or `""` when the file is not under `sources`.
    static func module(of file: URL, under sources: URL) -> String {
        let sourceComponents = sources.standardizedFileURL.pathComponents
        let fileComponents = file.standardizedFileURL.pathComponents
        guard fileComponents.count > sourceComponents.count else { return "" }
        return fileComponents[sourceComponents.count]
    }

    /// The first paragraph after the symbol heading, joined onto one line.
    ///
    /// Stops at the first blank line, and refuses anything that begins a new block — a `##`
    /// heading, a fence, a directive. An article that opens straight into `## Overview` has no
    /// abstract, and saying so is better than promoting a section title into a description.
    static func abstract(fromArticle contents: String) -> String? {
        var seenHeading = false
        var paragraph: [String] = []

        for line in contents.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard seenHeading else {
                if trimmed.hasPrefix("# ") { seenHeading = true }
                continue
            }
            if trimmed.isEmpty {
                if !paragraph.isEmpty { break }
                continue
            }
            guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix("```"), !trimmed.hasPrefix("@") else {
                break
            }
            paragraph.append(trimmed)
        }

        guard !paragraph.isEmpty else { return nil }
        return paragraph.joined(separator: " ")
    }

    /// Collects the names in the `Package(targets:)` array, and only there.
    ///
    /// Two nearby constructs use the same spelling and neither declares a module: a product's
    /// `targets: ["Alpha"]` list, and a dependency written `.target(name: "Beta")`. Matching
    /// every `.target(name:)` in the file would invent modules out of both, so the visitor
    /// descends from the `Package(…)` call to its `targets:` argument and reads only the direct
    /// elements of that array.
    private final class TargetCollector: SyntaxVisitor {
        private static let declaring: Set<String> = [
            "target", "executableTarget", "plugin", "macro", "systemLibrary", "binaryTarget",
        ]

        var names: [String] = []

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            guard node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "Package",
                  let argument = node.arguments.first(where: { $0.label?.text == "targets" }),
                  let array = argument.expression.as(ArrayExprSyntax.self)
            else {
                return .visitChildren
            }
            for element in array.elements {
                guard let call = element.expression.as(FunctionCallExprSyntax.self),
                      let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                      Self.declaring.contains(member.declName.baseName.text),
                      let name = call.arguments.first(where: { $0.label?.text == "name" }),
                      let literal = name.expression.as(StringLiteralExprSyntax.self)
                else {
                    continue
                }
                names.append(literal.segments.description)
            }
            return .skipChildren
        }
    }
}
