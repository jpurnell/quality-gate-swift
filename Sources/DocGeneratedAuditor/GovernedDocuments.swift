import Foundation
import QualityGateCore

/// A document `doc-generated` is responsible for.
public struct GovernedDocument: Sendable, Equatable {

    /// Absolute location on disk.
    public let url: URL

    /// Path relative to the project root, which is what diagnostics report.
    public let relativePath: String

    /// Whether `excludePatterns` removed it from scanning.
    ///
    /// An excluded document is still *counted*: the coverage line reports how many regions
    /// live in files the run did not check, so the gap between regions present and regions
    /// verified is visible rather than silently zero.
    public let isExcluded: Bool

    /// Creates a governed document record.
    public init(url: URL, relativePath: String, isExcluded: Bool) {
        self.url = url
        self.relativePath = relativePath
        self.isExcluded = isExcluded
    }
}

/// Decides which markdown files `doc-generated` is responsible for.
///
/// ## Why a named set and not a tree walk
///
/// Regions are opt-in per site, and the set of documents that carry derived content about a
/// package is small and known: the README a stranger reads, the CHANGELOG a release links
/// from, and the master plan the project keeps. A recursive walk would additionally sweep in
/// vendored guidelines, design proposals — including the one that specifies this convention,
/// which shows the delimiters in prose — and every fixture. The knob is additive for the same
/// reason `DocCodeConfig`'s is: a configured path can widen coverage and can never narrow it.
public enum GovernedDocuments {

    /// The governed set for a project root, in a stable order.
    ///
    /// - Parameters:
    ///   - projectRoot: The package root.
    ///   - configuration: Supplies the master plan's location, the extra files, and the
    ///     shared exclude patterns.
    /// - Returns: Only documents that exist, sorted by relative path.
    public static func discover(projectRoot: URL, configuration: Configuration) -> [GovernedDocument] {
        var relatives = ["README.md", "CHANGELOG.md"]

        let guidelines = configuration.status.guidelinesPath
        let plan = (guidelines as NSString).appendingPathComponent(configuration.status.masterPlanPath)
        relatives.append(normalise(plan))
        relatives.append(contentsOf: configuration.docGenerated.additionalFiles.map(normalise))

        var seen: Set<String> = []
        var documents: [GovernedDocument] = []
        let manager = FileManager.default

        for relative in relatives where seen.insert(relative).inserted {
            let url = projectRoot.appendingPathComponent(relative)
            // SAFETY: CLI tool resolves a governed document path under the project root
            guard manager.fileExists(atPath: url.path) else { continue }
            let excluded = configuration.excludePatterns.contains { relative.contains($0) || url.path.contains($0) }
            documents.append(GovernedDocument(
                url: url, relativePath: relative, isExcluded: excluded))
        }
        return documents.sorted { $0.relativePath < $1.relativePath }
    }

    /// Strips a leading `./` so two spellings of one path are one entry.
    private static func normalise(_ path: String) -> String {
        var value = path
        while value.hasPrefix("./") { value.removeFirst(2) }
        return value
    }
}
