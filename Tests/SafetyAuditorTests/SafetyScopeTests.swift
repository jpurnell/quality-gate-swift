import Foundation
import Testing
import QualityGateCore
@testable import SafetyAuditor

/// What the safety walk is pointed at.
///
/// `safety` appended a literal `Sources` to the resolved root, so a force unwrap in
/// `Plugins/` or `Tests/` passed a gate that claims to forbid it — the same narrow-scope
/// class that let six deadlocks sit under `process-safety` for months. A rule the gate
/// states unconditionally must be checked everywhere the repository owns code.
///
/// The `.build` case is the counterweight: widening a walk by pointing it at the root is
/// only correct if the walk itself still refuses build output and vendored trees.
@Suite("Safety scan scope")
struct SafetyScopeTests {

    /// Builds a fixture package containing one file at `relativePath` with a force unwrap.
    private func fixture(planting relativePath: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-safety-scope-\(UUID().uuidString)")
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        let values: [Int] = [1, 2, 3]
        let first = values.first!
        """.write(to: file, atomically: true, encoding: .utf8)
        return root
    }

    /// Force-unwrap findings the auditor reported inside `root`.
    ///
    /// The prefix is taken from the **symlink-resolved** root. `SourceWalker` enumerates URLs,
    /// which resolves macOS's `/var` → `/private/var` link, so a diagnostic's path and the
    /// root a test just built name the same file in two spellings. Comparing the raw strings
    /// silently matches nothing, which reads exactly like a checker that found nothing.
    private func forceUnwraps(under root: URL) async throws -> [Diagnostic] {
        var configuration = Configuration()
        configuration.projectRoot = root
        let result = try await SafetyAuditor().check(configuration: configuration)
        let base = root.resolvingSymlinksInPath().path
        return result.diagnostics.filter {
            ($0.ruleId ?? "").contains("force-unwrap")
                && (($0.filePath ?? "") as NSString).resolvingSymlinksInPath.hasPrefix(base)
        }
    }

    @Test("A force unwrap in Plugins/ is reported")
    func findsTrapInPlugins() async throws {
        let root = try fixture(planting: "Plugins/GatePlugin/bad.swift")
        let found = try await forceUnwraps(under: root)
        #expect(found.count == 1, "Plugins/ was not scanned; found \(found.count) force unwraps")
    }

    @Test("A force unwrap in Tests/ is reported")
    func findsTrapInTests() async throws {
        let root = try fixture(planting: "Tests/AppTests/bad.swift")
        let found = try await forceUnwraps(under: root)
        #expect(found.count == 1, "Tests/ was not scanned; found \(found.count) force unwraps")
    }

    @Test("A force unwrap at the package root is reported")
    func findsTrapAtRoot() async throws {
        let root = try fixture(planting: "bad.swift")
        let found = try await forceUnwraps(under: root)
        #expect(found.count == 1, "the root itself was not scanned; found \(found.count)")
    }

    /// The widened walk must not start auditing build output.
    ///
    /// Pointing a walk at the root is the whole fix, and it is wrong unless the walk keeps
    /// refusing `.build` — which holds checked-out dependency sources this repository does
    /// not own and cannot fix.
    @Test("A force unwrap inside .build is not reported")
    func ignoresBuildOutput() async throws {
        let root = try fixture(planting: ".build/checkouts/Vendor/bad.swift")
        let found = try await forceUnwraps(under: root)
        #expect(found.isEmpty, "build output was scanned; found \(found.count) force unwraps")
    }

    /// Silence must distinguish "found nothing" from "examined nothing".
    @Test("The result states how many files were examined")
    func statesCoverage() async throws {
        let root = try fixture(planting: "Sources/App/bad.swift")
        var configuration = Configuration()
        configuration.projectRoot = root
        let result = try await SafetyAuditor().check(configuration: configuration)
        let coverage = result.diagnostics.first { $0.ruleId == "safety.coverage" }
        let message = try #require(coverage?.message, "expected a safety.coverage note")
        #expect(message.contains("1 file"), "expected a file count in: \(message)")
    }
}
