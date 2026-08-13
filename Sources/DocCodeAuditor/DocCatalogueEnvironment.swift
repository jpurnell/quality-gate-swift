import Foundation
import QualityGateCore

/// The compiler flags one catalogue's articles are checked under.
///
/// Extracted so every rung of the ladder derives them the same way. If `doc-run` computed
/// its own SDK, header and language-mode flags, an article could typecheck under one set and
/// execute under another — and the difference would surface as a documentation finding for a
/// tooling fact, which is the failure mode this whole checker family is designed against.
enum DocCatalogueEnvironment {

    /// What one catalogue needs, and anything worth saying about how it was derived.
    struct Resolved {

        /// Flags for the typechecker, or `nil` when the module has not been built.
        let options: DocCodeAuditOptions?

        /// Notes about the environment — an unbuilt module, an undetermined language mode,
        /// a `swiftSettings` entry that could not be translated.
        let notes: [Diagnostic]
    }

    /// Resolves the environment for one catalogue.
    ///
    /// - Parameters:
    ///   - projectRoot: The package root.
    ///   - catalogue: The catalogue and the module its articles are written against.
    ///   - configuration: Supplies the `doc-code` knobs, which every rung shares.
    ///   - checkerId: Prefix for the notes' rule ids, so a reader can tell which rung spoke.
    /// - Returns: The options and notes. `options` is `nil` when there is no built module,
    ///   which is reported as a note rather than as a wall of `no such module` findings
    ///   against documentation that is very probably fine.
    static func resolve(
        projectRoot: URL, catalogue: Catalogue, configuration: Configuration, checkerId: String
    ) -> Resolved {
        guard let searchPath = ArticleDiscovery.moduleSearchPath(
            projectRoot: projectRoot, moduleName: catalogue.moduleName, configuration: configuration
        ) else {
            return Resolved(
                options: nil,
                notes: [
                    Diagnostic(
                        severity: .note,
                        message: """
                            Skipped \(catalogue.moduleName): no built module found under \
                            .build/debug. Run the build first — this checker compiles \
                            documentation against the module, it does not build it.
                            """,
                        ruleId: "\(checkerId).module-unavailable")
                ])
        }

        var notes: [Diagnostic] = []
        let mode = ManifestLanguageMode.read(projectRoot: projectRoot, target: catalogue.moduleName)
        if !mode.isDetermined {
            notes.append(
                Diagnostic(
                    severity: .note,
                    message: "\(catalogue.moduleName): \(mode.explanation)",
                    ruleId: "\(checkerId).language-mode"))
        }
        if !mode.unrecognisedSettings.isEmpty {
            notes.append(
                Diagnostic(
                    severity: .note,
                    message: """
                        \(catalogue.moduleName): these swiftSettings were not translated \
                        into compiler flags, so documentation is checked under slightly \
                        different rules than the build: \
                        \(mode.unrecognisedSettings.joined(separator: ", ")).
                        """,
                    ruleId: "\(checkerId).language-mode"))
        }

        var options = DocCodeAuditOptions()
        options.moduleSearchPath = searchPath
        options.imports = ["Foundation", catalogue.moduleName] + configuration.docCode.extraImports
        options.languageFlags = mode.flags
        options.headerSearchPaths = DocCodeAuditor.headerSearchPaths(
            projectRoot: projectRoot, configuration: configuration)
        options.moduleMapFiles = DocCodeAuditor.generatedModuleMaps(projectRoot: projectRoot)
        // The package's own macro plugins, for the same reason swift-testing's are passed: a
        // fence using a macro this package declares would otherwise fail on a missing
        // implementation, which is a fact about the build rather than about the documentation.
        options.toolchainFlags += MacroPlugins.flags(
            projectRoot: projectRoot, buildDirectory: searchPath)

        return Resolved(options: options, notes: notes)
    }
}
