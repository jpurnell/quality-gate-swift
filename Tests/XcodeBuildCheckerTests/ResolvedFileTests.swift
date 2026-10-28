import Foundation
import Synchronization
import Testing
import QualityGateCore
@testable import XcodeBuildChecker

/// `xcodebuild` must not rewrite a package's `Package.resolved`.
///
/// Found 2026-10-28 in SwiftKeychain, whose integrations sit behind package traits. `xcodebuild`
/// builds with default traits only, so it re-resolved and wrote back the two pins the default
/// build needs, dropping the 27 the traits do. `dependency-audit` then failed on a file the gate
/// itself had just changed. Earlier runs had passed only because `dependency-audit` replayed a
/// cached result. With `-onlyUsePackageVersionsFromResolvedFile`, `xcodebuild` builds from the
/// committed pins and leaves the file alone (checked by hand against SwiftKeychain).
@Suite("Xcode build: a package's Package.resolved is left as committed")
struct ResolvedFileTests {

    private static func makePackageDirectory(withResolved: Bool) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-resolved-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\n".write(
            to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        if withResolved {
            try #"{"pins":[],"version":3}"#.write(
                to: directory.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)
        }
        return directory
    }

    private static func answer(to invocation: XcodeBuildChecker.Invocation) -> XcodeBuildChecker.ToolOutput {
        if invocation.arguments.contains("-list") {
            return .init(stdout: #"{"workspace":{"name":"Probe","schemes":["Probe"]}}"#, stderr: "", exitCode: 0)
        }
        if invocation.arguments.contains("-showBuildSettings") {
            return .init(stdout: #"[{"buildSettings":{"SUPPORTED_PLATFORMS":"macosx"}}]"#, stderr: "", exitCode: 0)
        }
        return .init(stdout: "", stderr: "", exitCode: 0)
    }

    private static func launches(withResolved: Bool) async throws -> [XcodeBuildChecker.Invocation] {
        let directory = try makePackageDirectory(withResolved: withResolved)
        defer { try? FileManager.default.removeItem(at: directory) } // silent: best-effort cleanup of a temporary fixture
        let launches = Mutex<[XcodeBuildChecker.Invocation]>([])
        let checker = XcodeBuildChecker(
            parentEnvironment: { ["PATH": "/usr/bin:/bin"] },
            launcher: { invocation in
                launches.withLock { $0.append(invocation) }
                return answer(to: invocation)
            })
        var configuration = Configuration()
        configuration.projectRoot = directory
        let result = try await checker.check(configuration: configuration)
        #expect(result.status == .passed)
        return launches.withLock { $0 }
    }

    @Test("Every launch for a package with a Package.resolved uses only its pins")
    func pinnedPackage() async throws {
        let recorded = try await Self.launches(withResolved: true)
        #expect(recorded.map { $0.arguments.first } == ["-list", "-showBuildSettings", "build"])
        for launch in recorded {
            #expect(launch.arguments.contains("-onlyUsePackageVersionsFromResolvedFile"),
                    "xcodebuild \(launch.arguments.first ?? "?") could rewrite Package.resolved")
        }
    }

    /// With no file to keep, the flag would make xcodebuild refuse to resolve at all.
    @Test("A package with no Package.resolved resolves as before")
    func unpinnedPackage() async throws {
        let recorded = try await Self.launches(withResolved: false)
        #expect(recorded.count == 3)
        #expect(recorded.allSatisfy { !$0.arguments.contains("-onlyUsePackageVersionsFromResolvedFile") })
    }

    @Test("An Xcode project keeps its own resolution", arguments: [["-project", "App.xcodeproj"], ["-workspace", "App.xcworkspace"]])
    func projectsUnchanged(_ container: [String]) {
        #expect(XcodeBuildChecker.resolutionArguments(projectArguments: container, packageIsPinned: true) == [])
        #expect(XcodeBuildChecker.resolutionArguments(projectArguments: [], packageIsPinned: true)
                == ["-onlyUsePackageVersionsFromResolvedFile"])
    }
}
