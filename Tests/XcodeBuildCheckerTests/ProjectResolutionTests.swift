import Foundation
import Testing
import QualityGateCore
@testable import XcodeBuildChecker

/// What `xcodebuild` is pointed at, and what happens when there is nothing to point it at.
///
/// A plain Swift package used to resolve to nothing, and nothing reported as `✓ PASSED`:
/// BioFeedbackKit-HealthKit, configured with a scheme and a watchOS destination, passed in
/// 0 ms having built nothing. `xcodebuild` builds a package from its own directory with no
/// `-project` or `-workspace`, so a package is a container in all but name.
@Suite("Xcode build project resolution")
struct ProjectResolutionTests {

    @Test("A Swift package is built from its directory, with no container arguments")
    func packageNeedsNoContainerArguments() {
        let arguments = XcodeBuildChecker.projectArguments(
            config: .default,
            directoryContents: ["Package.swift", "Sources", "Tests"]
        )
        #expect(arguments == [])
    }

    @Test("A project or workspace beside Package.swift still wins, so nothing that builds today changes")
    func containerWinsOverPackage() {
        #expect(XcodeBuildChecker.projectArguments(
            config: .default,
            directoryContents: ["Package.swift", "App.xcodeproj"]
        ) == ["-project", "App.xcodeproj"])
        #expect(XcodeBuildChecker.projectArguments(
            config: .default,
            directoryContents: ["Package.swift", "App.xcodeproj", "App.xcworkspace"]
        ) == ["-workspace", "App.xcworkspace"])
    }

    @Test("A configured workspace or project wins over discovery")
    func configuredContainerWins() {
        #expect(XcodeBuildChecker.projectArguments(
            config: XcodeBuildCheckerConfig(project: "Other.xcodeproj"),
            directoryContents: ["Package.swift"]
        ) == ["-project", "Other.xcodeproj"])
        #expect(XcodeBuildChecker.projectArguments(
            config: XcodeBuildCheckerConfig(project: "Other.xcodeproj", workspace: "W.xcworkspace"),
            directoryContents: ["Package.swift"]
        ) == ["-workspace", "W.xcworkspace"])
    }

    @Test("With no project, workspace or package there is nothing to build")
    func nothingToBuild() {
        #expect(XcodeBuildChecker.projectArguments(
            config: .default,
            directoryContents: ["README.md", "Sources"]
        ) == nil)
    }

    @Test("Nothing to build is reported as skipped, never as passed")
    func nothingToBuildIsSkipped() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-build-skip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // silent: best-effort temp cleanup
        try Data("# empty\n".utf8).write(to: root.appendingPathComponent("README.md"))

        var configuration = Configuration()
        configuration.projectRoot = root
        let result = try await XcodeBuildChecker().check(configuration: configuration)

        #expect(result.status == .skipped)
        #expect(result.diagnostics.contains { $0.message.contains("Package.swift") })
    }
}
