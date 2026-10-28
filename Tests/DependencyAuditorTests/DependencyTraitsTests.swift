import Foundation
import Testing
@testable import DependencyAuditor
@testable import QualityGateCore

// SwiftKeychain declares three direct dependencies, one used only under a trait that is off by
// default. SwiftPM does not resolve a dependency no enabled trait reaches, so its committed
// Package.resolved holds two pins — correctly — and `dep-unresolved` called it out of sync:
// "resolved has 2 pins, Package.swift declares 3 direct dependencies". The count has to be of
// the dependencies the configured build can reach.

private let keychainManifest = """
    // swift-tools-version: 6.1
    import PackageDescription
    let package = Package(
        name: "SwiftKeychain",
        products: [.library(name: "SwiftKeychain", targets: ["SwiftKeychain"])],
        traits: [
            .trait(name: "OAuth"),
            .trait(name: "CLIAuth", enabledTraits: ["OAuth"]),
            .default(enabledTraits: []),
        ],
        dependencies: [
            .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
            .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
            .package(url: "https://github.com/jpurnell/swift-oauth.git", from: "0.3.0"),
        ],
        targets: [
            .target(
                name: "SwiftKeychain",
                dependencies: [
                    .product(name: "Crypto", package: "swift-crypto"),
                    .product(name: "Logging", package: "swift-log"),
                    .product(name: "OAuth", package: "swift-oauth", condition: .when(traits: ["OAuth"])),
                ]
            ),
        ]
    )
    """

private func pin(_ identity: String) -> String {
    """
    {"identity": "\(identity)", "kind": "remoteSourceControl",
     "location": "https://github.com/x/\(identity).git",
     "state": {"revision": "abc", "version": "1.0.0"}}
    """
}

private func project(manifest: String, pins: [String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("qg-dep-traits-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try manifest.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    let resolved = "{\"pins\": [\(pins.map(pin).joined(separator: ","))], \"version\": 2}"
    try resolved.write(to: root.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)
    return root
}

private func unresolved(manifest: String, pins: [String], traits: [String]) async throws -> [Diagnostic] {
    let root = try project(manifest: manifest, pins: pins)
    defer { removeFixture(root) }
    var configuration = Configuration(traits: traits)
    configuration.projectRoot = root
    let result = try await DependencyAuditor().check(configuration: configuration)
    return result.diagnostics.filter { $0.ruleId == "dep-unresolved" }
}

/// Removes a temporary fixture, recording a failure instead of discarding it.
private func removeFixture(_ url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        Issue.record("could not remove the fixture at \(url.path): \(error)")
    }
}

@Suite("dependency-audit: a dependency only a disabled trait reaches need not be resolved")
struct DependencyTraitsTests {

    @Test("With default traits, a dependency gated on an off trait is not counted")
    func gatedDependencyNotCountedByDefault() async throws {
        let found = try await unresolved(
            manifest: keychainManifest, pins: ["swift-crypto", "swift-log"], traits: [])
        #expect(found.isEmpty)
    }

    @Test("With its trait configured, the gated dependency must be resolved")
    func gatedDependencyCountedWhenEnabled() async throws {
        let found = try await unresolved(
            manifest: keychainManifest, pins: ["swift-crypto", "swift-log"], traits: ["OAuth"])
        #expect(found.count == 1)
        #expect(found.first?.message.contains("Package.swift declares 3 direct dependencies") == true)
    }

    @Test("A trait that enables another reaches the other's dependencies")
    func impliedTraitIsFollowed() async throws {
        let found = try await unresolved(
            manifest: keychainManifest, pins: ["swift-crypto", "swift-log"], traits: ["CLIAuth"])
        #expect(found.count == 1)
    }

    @Test("A default trait counts unless named traits replace the defaults; `defaults` keeps them")
    func defaultTraitsFollowSwiftPM() async throws {
        let defaulted = keychainManifest.replacingOccurrences(
            of: ".default(enabledTraits: [])", with: ".default(enabledTraits: [\"OAuth\"])")
        let twoPins = ["swift-crypto", "swift-log"]
        #expect(try await unresolved(manifest: defaulted, pins: twoPins, traits: []).count == 1)
        #expect(try await unresolved(manifest: defaulted, pins: twoPins, traits: ["Other"]).isEmpty)
        #expect(try await unresolved(manifest: defaulted, pins: twoPins, traits: ["defaults"]).count == 1)
    }

    @Test("A dependency also used without a condition is always counted")
    func unconditionalUseWins() async throws {
        let alsoPlain = keychainManifest.replacingOccurrences(
            of: "dependencies: [\n                .product(name: \"Crypto\"",
            with: "dependencies: [\n                .product(name: \"OAuthCore\", package: \"swift-oauth\"),\n                .product(name: \"Crypto\"")
        #expect(alsoPlain != keychainManifest)
        let found = try await unresolved(
            manifest: alsoPlain, pins: ["swift-crypto", "swift-log"], traits: [])
        #expect(found.count == 1)
    }
}
