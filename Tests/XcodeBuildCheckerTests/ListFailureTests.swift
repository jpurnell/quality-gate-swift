import Foundation
import Testing
import QualityGateCore
@testable import XcodeBuildChecker

/// A build tool that fails before it builds must say what was run and what failed.
///
/// What the 2026-10-06 failure looked like from the outside:
///
///     ✗ [xcode-build] FAILED (0ms)
///       ❌ error: Checker failed: Configuration error: xcodebuild -list failed: …
///
/// Three misdirections in two lines. "Checker failed" says the gate broke; "Configuration
/// error" says `.quality-gate.yml` is wrong; `0ms` says nothing ran. None was true:
/// `xcodebuild` ran for seconds, the configuration was fine, and the thing that failed was
/// `xcodebuild`'s own dependency resolution. The reader was left to work that out.
@Suite("Xcode build: a failed scheme listing is a finding, not a thrown configuration error")
struct ListFailureTests {

    private static let resolutionFailure = """
        2026-10-06 21:14:03.118 xcodebuild[4242:1] Writing error result bundle to /var/folders/x/ResultBundle.xcresult
        xcodebuild: error: Could not resolve package dependencies:
          fatalError
          Couldn’t check out revision ‘1abee2759f7663b8fcd4d71bb0bcd1ebe6c1677f’:
        """

    @Test("A package-resolution failure names the command, the directory and the resolution")
    func resolutionFailureIsNamedAsResolution() {
        let diagnostic = XcodeBuildChecker.listFailureDiagnostic(
            arguments: ["-list", "-json"],
            directory: "/work/Probe",
            exitCode: 74,
            output: Self.resolutionFailure)

        #expect(diagnostic.severity == .error)
        #expect(diagnostic.ruleId == "xcode-build-package-resolution")
        #expect(diagnostic.message.contains("xcodebuild -list -json"))
        #expect(diagnostic.message.contains("/work/Probe"))
        #expect(diagnostic.message.contains("exited 74"))
        #expect(diagnostic.message.contains("resolving package dependencies"))
        #expect(diagnostic.message.contains("Nothing was compiled"))
        #expect(diagnostic.message.contains("Couldn’t check out revision ‘1abee2759f7663b8fcd4d71bb0bcd1ebe6c1677f’"))
        #expect(diagnostic.suggestedFix == "Run `xcodebuild -list -json` in /work/Probe to see the full output; `xcodebuild -resolvePackageDependencies` there retries the resolution on its own.")
    }

    @Test("Any other listing failure is reported as a listing failure, without guessing at a cause")
    func otherFailureDoesNotClaimResolution() {
        let diagnostic = XcodeBuildChecker.listFailureDiagnostic(
            arguments: ["-list", "-json", "-project", "Gone.xcodeproj"],
            directory: "/work/App",
            exitCode: 66,
            output: "xcodebuild: error: 'Gone.xcodeproj' does not exist.")

        #expect(diagnostic.ruleId == "xcode-build-list-failed")
        #expect(diagnostic.message.contains("xcodebuild -list -json -project Gone.xcodeproj"))
        #expect(diagnostic.message.contains("exited 66"))
        #expect(diagnostic.message.contains("'Gone.xcodeproj' does not exist."))
        #expect(!diagnostic.message.contains("package dependencies"))
    }

    @Test("The checker returns that finding as a failed result instead of throwing")
    func checkReportsTheFailureAsAResult() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-list-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) } // silent: best-effort cleanup of a temporary fixture
        try "// swift-tools-version: 6.0\n".write(
            to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let checker = XcodeBuildChecker(
            parentEnvironment: { ["PATH": "/usr/bin:/bin"] },
            launcher: { _ in .init(stdout: "", stderr: Self.resolutionFailure, exitCode: 74) })
        var configuration = Configuration()
        configuration.projectRoot = directory

        let result = try await checker.check(configuration: configuration)

        #expect(result.status == .failed)
        #expect(result.checkerId == "xcode-build")
        #expect(result.diagnostics.map(\.ruleId) == ["xcode-build-package-resolution"])
    }
}
