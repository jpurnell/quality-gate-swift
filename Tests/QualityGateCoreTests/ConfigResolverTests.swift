import Foundation
import Testing
@testable import QualityGateCore

/// Phase 1, workstream 1 — layered config resolution (the overlay model).
///
/// Resolution order, first hit per top-level section:
/// repo `.quality-gate.yml` → overlay `config.yml` → user-global `config.yml`
/// → built-in defaults. A repo's own config always wins where present; an
/// overlay fills gaps, it never overrides declared policy. Merging happens at
/// the raw YAML key level so every section — including ones added after this
/// test was written — inherits overlay support without per-field plumbing.
@Suite("ConfigResolver precedence")
struct ConfigResolverTests {

    // MARK: - Fixture helpers

    /// Creates an isolated directory tree for one test case.
    private func makeSandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Writes YAML into the sandbox and returns the file URL.
    private func write(_ yaml: String, to directory: URL, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A sandbox with a repo root, overlay dir, and global dir, all empty.
    private func makeLayout() throws -> (repo: URL, overlay: URL, global: URL) {
        let root = try makeSandbox()
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let overlay = root.appendingPathComponent("overlay", isDirectory: true)
        let global = root.appendingPathComponent("global", isDirectory: true)
        for dir in [repo, overlay, global] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return (repo, overlay, global)
    }

    // MARK: - Precedence table

    @Test("repo section beats overlay and global")
    func repoSectionWins() throws {
        let (repo, overlay, global) = try makeLayout()
        _ = try write("""
        parallelWorkers: 3
        complexity:
          cognitiveThreshold: 7
        """, to: repo, named: ".quality-gate.yml")
        _ = try write("""
        parallelWorkers: 9
        complexity:
          cognitiveThreshold: 99
        """, to: overlay, named: "config.yml")
        _ = try write("parallelWorkers: 11", to: global, named: "config.yml")

        let resolver = ConfigResolver(
            repoRoot: repo,
            overlayConfigURL: overlay.appendingPathComponent("config.yml"),
            userGlobalConfigURL: global.appendingPathComponent("config.yml"))
        let (configuration, provenance) = try resolver.resolve()

        #expect(configuration.parallelWorkers == 3)
        #expect(configuration.complexity.cognitiveThreshold == 7)
        #expect(provenance.origin(of: "parallelWorkers") == .repo)
        #expect(provenance.origin(of: "complexity") == .repo)
    }

    @Test("overlay fills sections the repo config lacks")
    func overlayFillsGaps() throws {
        let (repo, overlay, global) = try makeLayout()
        _ = try write("parallelWorkers: 3", to: repo, named: ".quality-gate.yml")
        _ = try write("""
        legibility:
          minFanInForCentral: 4
        """, to: overlay, named: "config.yml")

        let resolver = ConfigResolver(
            repoRoot: repo,
            overlayConfigURL: overlay.appendingPathComponent("config.yml"),
            userGlobalConfigURL: global.appendingPathComponent("config.yml"))
        let (configuration, provenance) = try resolver.resolve()

        #expect(configuration.parallelWorkers == 3)
        #expect(configuration.legibility.minFanInForCentral == 4)
        #expect(provenance.origin(of: "parallelWorkers") == .repo)
        #expect(provenance.origin(of: "legibility") == .overlay)
    }

    @Test("user-global fills sections neither repo nor overlay set")
    func userGlobalFillsLast() throws {
        let (repo, overlay, global) = try makeLayout()
        _ = try write("excludePatterns: [\"RepoExcluded/\"]", to: repo, named: ".quality-gate.yml")
        _ = try write("parallelWorkers: 9", to: overlay, named: "config.yml")
        _ = try write("""
        parallelWorkers: 11
        vendorPaths: ["GlobalVendor/"]
        """, to: global, named: "config.yml")

        let resolver = ConfigResolver(
            repoRoot: repo,
            overlayConfigURL: overlay.appendingPathComponent("config.yml"),
            userGlobalConfigURL: global.appendingPathComponent("config.yml"))
        let (configuration, provenance) = try resolver.resolve()

        #expect(configuration.excludePatterns == ["RepoExcluded/"])
        #expect(configuration.parallelWorkers == 9)
        #expect(configuration.vendorPaths == ["GlobalVendor/"])
        #expect(provenance.origin(of: "excludePatterns") == .repo)
        #expect(provenance.origin(of: "parallelWorkers") == .overlay)
        #expect(provenance.origin(of: "vendorPaths") == .userGlobal)
    }

    @Test("sections are atomic — a repo section is never deep-merged with an overlay's")
    func sectionsAreAtomic() throws {
        let (repo, overlay, global) = try makeLayout()
        _ = try write("""
        concurrency:
          justificationKeyword: "RepoJustification"
        """, to: repo, named: ".quality-gate.yml")
        _ = try write("""
        concurrency:
          justificationKeyword: "OverlayJustification"
          allowPreconcurrencyImports: ["OverlayImport"]
        """, to: overlay, named: "config.yml")

        let resolver = ConfigResolver(
            repoRoot: repo,
            overlayConfigURL: overlay.appendingPathComponent("config.yml"),
            userGlobalConfigURL: global.appendingPathComponent("config.yml"))
        let (configuration, _) = try resolver.resolve()

        #expect(configuration.concurrency.justificationKeyword == "RepoJustification")
        // The overlay's sub-key must NOT leak into the repo-owned section.
        #expect(configuration.concurrency.allowPreconcurrencyImports
            == ConcurrencyAuditorConfig.default.allowPreconcurrencyImports)
    }

    @Test("unset sections fall through to built-in defaults")
    func builtinWhenAbsent() throws {
        let (repo, overlay, global) = try makeLayout()
        _ = try write("parallelWorkers: 3", to: repo, named: ".quality-gate.yml")

        let resolver = ConfigResolver(
            repoRoot: repo,
            overlayConfigURL: overlay.appendingPathComponent("config.yml"),
            userGlobalConfigURL: global.appendingPathComponent("config.yml"))
        let (configuration, provenance) = try resolver.resolve()

        #expect(configuration.docCoverage == DocCoverageConfig.default)
        #expect(configuration.legibility == LegibilityAnalyzerConfig.default)
        #expect(provenance.origin(of: "docCoverage") == .builtin)
        #expect(provenance.origin(of: "legibility") == .builtin)
    }

    @Test("no config anywhere resolves to pure defaults with empty provenance")
    func noConfigAnywhere() throws {
        let (repo, overlay, global) = try makeLayout()

        let resolver = ConfigResolver(
            repoRoot: repo,
            overlayConfigURL: overlay.appendingPathComponent("config.yml"),
            userGlobalConfigURL: global.appendingPathComponent("config.yml"))
        let (configuration, provenance) = try resolver.resolve()

        #expect(configuration == Configuration())
        #expect(provenance.sections.isEmpty)
        #expect(provenance.repoConfigPath == nil)
        #expect(provenance.overlayConfigPath == nil)
        #expect(provenance.userGlobalConfigPath == nil)
    }

    @Test("repo-only resolution matches Configuration.load byte-for-byte")
    func repoOnlyMatchesLegacyLoad() throws {
        let (repo, overlay, global) = try makeLayout()
        let repoConfig = try write("""
        parallelWorkers: 5
        excludePatterns: ["Generated/"]
        complexity:
          cognitiveThreshold: 12
        legibility:
          minFanInForCentral: 6
        """, to: repo, named: ".quality-gate.yml")

        let resolver = ConfigResolver(
            repoRoot: repo,
            overlayConfigURL: overlay.appendingPathComponent("config.yml"),
            userGlobalConfigURL: global.appendingPathComponent("config.yml"))
        let (resolved, provenance) = try resolver.resolve()
        let legacy = try Configuration.load(from: repoConfig.path)

        #expect(resolved == legacy)
        #expect(provenance.repoConfigPath == repoConfig.path)
    }

    // MARK: - Provenance reporting

    @Test("provenance records consulted file paths")
    func provenancePaths() throws {
        let (repo, overlay, global) = try makeLayout()
        let repoConfig = try write("parallelWorkers: 3", to: repo, named: ".quality-gate.yml")
        let overlayConfig = try write("vendorPaths: [\"V/\"]", to: overlay, named: "config.yml")

        let resolver = ConfigResolver(
            repoRoot: repo,
            overlayConfigURL: overlayConfig,
            userGlobalConfigURL: global.appendingPathComponent("config.yml"))
        let (_, provenance) = try resolver.resolve()

        #expect(provenance.repoConfigPath == repoConfig.path)
        #expect(provenance.overlayConfigPath == overlayConfig.path)
        #expect(provenance.userGlobalConfigPath == nil)
    }

    @Test("renderTable names each file-sourced section with its origin")
    func renderTableGolden() throws {
        let (repo, overlay, global) = try makeLayout()
        _ = try write("parallelWorkers: 3", to: repo, named: ".quality-gate.yml")
        _ = try write("""
        legibility:
          minFanInForCentral: 4
        """, to: overlay, named: "config.yml")
        _ = try write("vendorPaths: [\"GlobalVendor/\"]", to: global, named: "config.yml")

        let resolver = ConfigResolver(
            repoRoot: repo,
            overlayConfigURL: overlay.appendingPathComponent("config.yml"),
            userGlobalConfigURL: global.appendingPathComponent("config.yml"))
        let (_, provenance) = try resolver.resolve()
        let table = provenance.renderTable()

        #expect(table.contains("parallelWorkers"))
        #expect(table.contains("legibility"))
        #expect(table.contains("vendorPaths"))
        #expect(table.contains("repo"))
        #expect(table.contains("overlay"))
        #expect(table.contains("user-global"))
        // Consulted paths appear so "which config am I running?" has one answer.
        #expect(table.contains(".quality-gate.yml"))
    }

    // MARK: - Error paths

    @Test("invalid YAML in any layer throws rather than silently falling back")
    func invalidYAMLThrows() throws {
        let (repo, overlay, global) = try makeLayout()
        _ = try write("parallelWorkers: [unclosed", to: overlay, named: "config.yml")

        let resolver = ConfigResolver(
            repoRoot: repo,
            overlayConfigURL: overlay.appendingPathComponent("config.yml"),
            userGlobalConfigURL: global.appendingPathComponent("config.yml"))
        #expect(throws: QualityGateError.self) {
            _ = try resolver.resolve()
        }
    }

    @Test("a non-mapping document throws a configuration error")
    func nonMappingThrows() throws {
        let (repo, overlay, global) = try makeLayout()
        _ = try write("- just\n- a\n- list", to: repo, named: ".quality-gate.yml")

        let resolver = ConfigResolver(
            repoRoot: repo,
            overlayConfigURL: overlay.appendingPathComponent("config.yml"),
            userGlobalConfigURL: global.appendingPathComponent("config.yml"))
        #expect(throws: QualityGateError.self) {
            _ = try resolver.resolve()
        }
    }

    @Test("an empty file contributes nothing and does not error")
    func emptyFileIsEmptyMapping() throws {
        let (repo, overlay, global) = try makeLayout()
        _ = try write("", to: overlay, named: "config.yml")
        _ = try write("parallelWorkers: 3", to: global, named: "config.yml")

        let resolver = ConfigResolver(
            repoRoot: repo,
            overlayConfigURL: overlay.appendingPathComponent("config.yml"),
            userGlobalConfigURL: global.appendingPathComponent("config.yml"))
        let (configuration, provenance) = try resolver.resolve()

        #expect(configuration.parallelWorkers == 3)
        #expect(provenance.origin(of: "parallelWorkers") == .userGlobal)
    }
}
