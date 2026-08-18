import Foundation
import Testing
import QualityGateCore
@testable import FloatingPointSafetyAuditor

/// What the floating-point walk is pointed at.
///
/// The walk was bounded to a hardcoded `Sources/`, so an unguarded division in `Plugins/` or at
/// the package root was never examined. `Tests/` is a separate matter and stays skipped by the
/// visitor's own `skipTestFiles` judgement, which `test-quality` complements — pinned below so
/// the distinction between a bound and a decision stays visible.
///
/// The `.build` case is the counterweight: pointing a walk at the root is only correct while
/// the walk still refuses build output.
@Suite("Floating-point scan scope")
struct FPScopeTests {

    private static let ruleId = "fp-division-unguarded"

    private func fixture(planting relativePath: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-fp-scope-\(UUID().uuidString)")
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "let divisor = 2.5\nlet result = value / divisor\n"
            .write(to: file, atomically: true, encoding: .utf8)
        return root
    }

    private func findings(under root: URL, excluding patterns: [String] = []) async throws -> [Diagnostic] {
        var configuration = Configuration()
        configuration.projectRoot = root
        configuration.excludePatterns = patterns
        let result = try await FloatingPointSafetyAuditor().check(configuration: configuration)
        let base = root.resolvingSymlinksInPath().path
        return result.diagnostics.filter {
            $0.ruleId == Self.ruleId
                && (($0.filePath ?? "") as NSString).resolvingSymlinksInPath.hasPrefix(base)
        }
    }

    /// `Tests/` stays skipped, and that is a stated judgement rather than the defect.
    ///
    /// `FloatingPointSafetyVisitor.skipTestFiles` documents the division of labour: `fp-safety`
    /// skips test code and `test-quality` covers it as `exact-double-equality` — "same
    /// detector, different reach". Widening the walk to the repository root does not repeal
    /// that; it adds `Plugins/` and the package root, which nothing else covered.
    @Test("Tests/ remains skipped — test-quality owns that reach")
    func skipsTestsDeliberately() async throws {
        #expect(try await findings(under: fixture(planting: "Tests/AppTests/bad.swift")).isEmpty)
    }

    @Test("An unguarded division in Plugins/ is reported")
    func findsInPlugins() async throws {
        #expect(try await findings(under: fixture(planting: "Plugins/P/bad.swift")).count == 1)
    }

    @Test("Build output is not scanned")
    func ignoresBuildOutput() async throws {
        #expect(try await findings(under: fixture(planting: ".build/checkouts/V/bad.swift")).isEmpty)
    }

    @Test("A configured exclude pattern is honoured")
    func honoursExcludePatterns() async throws {
        let root = try fixture(planting: "Sources/Generated/bad.swift")
        #expect(try await findings(under: root, excluding: ["**/Generated/**"]).isEmpty)
    }

    /// `allowedFiles` is matched against the repository-relative path, not the absolute one.
    ///
    /// Matching the absolute path would let an entry start excluding files because a directory
    /// name above the checkout happened to contain it.
    @Test("allowedFiles matches the repository-relative path")
    func allowedFilesAreRelative() async throws {
        let root = try fixture(planting: "Sources/Math/bad.swift")
        var configuration = Configuration()
        configuration.projectRoot = root
        configuration.fpSafety.allowedFiles = ["Sources/Math"]
        let result = try await FloatingPointSafetyAuditor().check(configuration: configuration)
        #expect(!result.diagnostics.contains { $0.ruleId == Self.ruleId })
    }
}
