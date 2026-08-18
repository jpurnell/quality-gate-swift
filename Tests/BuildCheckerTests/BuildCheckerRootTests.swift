import Foundation
import Testing
import QualityGateCore
@testable import BuildChecker

/// End-to-end proof of the spawn half of the root artery: a checker whose work happens
/// in a *subprocess* must run that subprocess in the configured root, not wherever the
/// gate process was invoked.
///
/// `BuildChecker` is the canonical case — `swift build` resolves the package from its
/// working directory. Before `runSwiftBuild` passed `currentDirectory:`, the existence
/// check looked at the configured root while the build ran against the process cwd,
/// so the two could silently examine different trees.
/// See `project/plans/proposals/CheckerRootThreading.md` §3.4.
@Suite("BuildChecker root threading")
struct BuildCheckerRootTests {

    @Test("swift build runs in the configured root, not the process cwd", .timeLimit(.minutes(2)))
    func buildsTheConfiguredRoot() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-build-root-\(UUID().uuidString)")
        let sources = fixtureRoot.appendingPathComponent("Sources/Fixture")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "Fixture",
            targets: [.target(name: "Fixture")]
        )
        """.write(to: fixtureRoot.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        public enum Fixture {
            public static let answer = 42
        }
        """.write(to: sources.appendingPathComponent("Fixture.swift"), atomically: true, encoding: .utf8)

        var configuration = Configuration()
        configuration.projectRoot = fixtureRoot

        // The process cwd is the gate's own checkout, whose build takes minutes. Only
        // the trivial fixture can pass inside this test's time limit — completing at
        // all is evidence the subprocess ran in the fixture, and the assertions pin it.
        let result = try await BuildChecker().check(configuration: configuration)

        #expect(result.status == .passed,
                "the fixture package must build clean; got \(result.status) with \(result.diagnostics.map(\.message))")
    }
}
