import Foundation
import QualityGateCore

/// A documentation catalogue and the module its articles are written against.
public struct Catalogue: Sendable {

    /// The module the articles document — `Sources/<Module>/<Module>.docc` — which is what
    /// the assembled program imports.
    public let moduleName: String

    /// Every markdown article in the catalogue, sorted by path so runs are reproducible.
    public let articles: [URL]
}

/// Finds the markdown this checker is responsible for.
public enum ArticleDiscovery {

    /// Every `.docc` catalogue under the project, plus any configured extras.
    ///
    /// The module name comes from the catalogue's enclosing source directory rather than
    /// from the catalogue's own name, because that is the directory SwiftPM builds into a
    /// module — and it is the import the article's code needs in order to mean anything.
    ///
    /// - Parameters:
    ///   - projectRoot: The package root.
    ///   - configuration: Supplies `docCode` extras and the shared exclude patterns.
    /// - Returns: The catalogues, sorted by module name. Empty when the project has none.
    public static func catalogues(projectRoot: URL, configuration: Configuration) -> [Catalogue] {
        let manager = FileManager.default
        let sources = projectRoot.appendingPathComponent("Sources", isDirectory: true)

        var byModule: [String: [URL]] = [:]

        if let walker = manager.enumerator(
            at: sources, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in walker where url.pathExtension == "docc" {
                let module = url.deletingLastPathComponent().lastPathComponent
                byModule[module, default: []] += markdown(under: url, excluding: configuration.excludePatterns)
                walker.skipDescendants()
            }
        }

        // Extras attach to the largest catalogue's module, because that is the module a
        // README or a top-level guide is overwhelmingly written against. They are additive:
        // a configured path can widen coverage and can never narrow it.
        var extras: [URL] = []
        if configuration.docCode.includeReadme {
            let readme = projectRoot.appendingPathComponent("README.md")
            // SAFETY: CLI tool checks for the project's own README
            if manager.fileExists(atPath: readme.path) { extras.append(readme) }
        }
        for relative in configuration.docCode.additionalArticles {
            let url = projectRoot.appendingPathComponent(relative)
            // SAFETY: CLI tool resolves a configured article path under the project root
            if manager.fileExists(atPath: url.path) { extras.append(url) }
        }

        if !extras.isEmpty {
            let host = byModule.max { $0.value.count < $1.value.count }?.key
            if let host {
                byModule[host, default: []] += extras
            }
        }

        return byModule
            .map { Catalogue(moduleName: $0.key, articles: $0.value.sorted { $0.path < $1.path }) }
            .sorted { $0.moduleName < $1.moduleName }
    }

    /// Markdown files under a catalogue, excluding anything the configuration excludes.
    static func markdown(under catalogue: URL, excluding patterns: [String]) -> [URL] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(
            at: catalogue, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "md" }
            .filter { url in !patterns.contains { url.path.contains($0) } }
    }

    /// The directory holding the built modules, or `nil` when nothing has been built.
    ///
    /// Both SwiftPM layouts are accepted: `.build/debug/<Module>.swiftmodule` and the older
    /// `.build/debug/Modules/<Module>.swiftmodule`.
    ///
    /// - Returns: The search path to pass to `swiftc -I`, or `nil` when the module is
    ///   absent — which the checker reports as a skip rather than as a wall of `no such
    ///   module` findings against the documentation.
    public static func moduleSearchPath(
        projectRoot: URL, moduleName: String, configuration: Configuration
    ) -> String? {
        let manager = FileManager.default
        let base = configuration.docCode.moduleSearchPath.map { URL(fileURLWithPath: $0) }
            ?? projectRoot.appendingPathComponent(".build/debug", isDirectory: true)

        for directory in [base, base.appendingPathComponent("Modules", isDirectory: true)] {
            for suffix in ["swiftmodule", "swiftinterface"] {
                let candidate = directory.appendingPathComponent("\(moduleName).\(suffix)")
                // SAFETY: CLI tool looks for the project's own built module
                if manager.fileExists(atPath: candidate.path) {
                    return base.path
                }
            }
        }
        return nil
    }
}
