import Foundation
import Testing
import QualityGateCore
@testable import ConcurrencyAuditor

/// What the concurrency walk is pointed at.
///
/// `concurrency` appended a literal `Sources` to the resolved root, so an unjustified
/// `@unchecked Sendable` in `Plugins/` or `Tests/` passed a gate that demands a justification
/// for it everywhere. Its private enumerator was worse than `safety`'s: it honoured no
/// `excludePatterns` at all, so a path the configuration excluded was audited anyway.
///
/// The `.build` case is the counterweight — widening a walk by pointing it at the root is only
/// correct while the walk still refuses build output.
@Suite("Concurrency scan scope")
struct ConcurrencyScopeTests {

    private static let ruleId = "concurrency.unchecked-sendable-no-justification"

    private func fixture(planting relativePath: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-concurrency-scope-\(UUID().uuidString)")
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "final class Foo: @unchecked Sendable {}\n"
            .write(to: file, atomically: true, encoding: .utf8)
        return root
    }

    private func findings(under root: URL, excluding patterns: [String] = []) async throws -> [Diagnostic] {
        var configuration = Configuration()
        configuration.projectRoot = root
        configuration.excludePatterns = patterns
        // Pass 2 needs a built index store; this suite is about which files pass 1 reads.
        configuration.concurrency.useIndexStore = false
        let result = try await ConcurrencyAuditor().check(configuration: configuration)
        let base = root.resolvingSymlinksInPath().path
        return result.diagnostics.filter {
            $0.ruleId == Self.ruleId
                && (($0.filePath ?? "") as NSString).resolvingSymlinksInPath.hasPrefix(base)
        }
    }

    @Test("An unjustified @unchecked Sendable in Plugins/ is reported")
    func findsInPlugins() async throws {
        let root = try fixture(planting: "Plugins/GatePlugin/bad.swift")
        #expect(try await findings(under: root).count == 1)
    }

    @Test("An unjustified @unchecked Sendable in Tests/ is reported")
    func findsInTests() async throws {
        let root = try fixture(planting: "Tests/AppTests/bad.swift")
        #expect(try await findings(under: root).count == 1)
    }

    @Test("An unjustified @unchecked Sendable at the package root is reported")
    func findsAtRoot() async throws {
        let root = try fixture(planting: "bad.swift")
        #expect(try await findings(under: root).count == 1)
    }

    @Test("Build output is not scanned")
    func ignoresBuildOutput() async throws {
        let root = try fixture(planting: ".build/checkouts/Vendor/bad.swift")
        #expect(try await findings(under: root).isEmpty)
    }

    /// The old private enumerator ignored `excludePatterns` entirely.
    @Test("A configured exclude pattern is honoured")
    func honoursExcludePatterns() async throws {
        let root = try fixture(planting: "Sources/Generated/bad.swift")
        #expect(try await findings(under: root, excluding: ["**/Generated/**"]).isEmpty)
    }
}
