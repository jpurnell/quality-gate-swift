import Foundation
import Testing
@testable import DocLinter
@testable import QualityGateCore

// Where `--traits` goes in a plugin command is not obvious, and the wrong place is silent.
// Measured on Swift 6.4 against a package with a trait-gated compile error:
//
//   swift package --traits T generate-documentation   → the plugin's builds use T
//   swift package generate-documentation --traits T   → `--traits T` is handed to the plugin
//                                                        as its own argument, and ignored
//
// It must precede the subcommand.

// Justification: `recorded` is only touched under `lock`; the class holds no other state.
private final class Arguments: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []

    func record(_ arguments: [String]) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(arguments)
    }

    var all: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

@Suite("doc-lint: the configured package traits reach the DocC build")
struct DocLintTraitsTests {

    private func package() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-doclint-traits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
            // swift-tools-version: 6.1
            import PackageDescription
            let package = Package(
                name: "Core",
                products: [.library(name: "Core", targets: ["Core"])],
                targets: [.target(name: "Core")]
            )
            """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        return root
    }

    private func linter(recording seen: Arguments) -> DocLinter {
        DocLinter(launcher: ToolLauncher(
            launch: { invocation in
                seen.record(invocation.arguments)
                return .init(stdout: "", stderr: "", exitCode: 0)
            },
            monotonicSeconds: { 0 },
            load: { nil }))
    }

    @Test("Traits are package options, placed before the plugin's subcommand")
    func traitsPrecedeTheSubcommand() async throws {
        let root = try package()
        defer { try? FileManager.default.removeItem(at: root) } // silent: best-effort cleanup of a temporary fixture
        let seen = Arguments()
        var configuration = Configuration(traits: ["OAuth", "CLIAuth"])
        configuration.projectRoot = root

        _ = try await linter(recording: seen).check(configuration: configuration)

        #expect(seen.all == [[
            "package", "--traits", "OAuth,CLIAuth", "generate-documentation", "--target", "Core",
        ]])
    }

    @Test("No configured traits leave the command exactly as it was")
    func noTraitsNoArgument() async throws {
        let root = try package()
        defer { try? FileManager.default.removeItem(at: root) } // silent: best-effort cleanup of a temporary fixture
        let seen = Arguments()
        var configuration = Configuration()
        configuration.projectRoot = root

        _ = try await linter(recording: seen).check(configuration: configuration)

        #expect(seen.all == [["package", "generate-documentation", "--target", "Core"]])
    }
}
