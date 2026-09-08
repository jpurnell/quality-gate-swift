import Foundation
import Testing
@testable import QualityGateCore

/// Tests for the resolved-root artery: `Configuration.projectRoot`.
///
/// A checker is a pure function of (root, configuration). The root travels inside
/// `Configuration` — lazily falling back to the process working directory so every
/// caller that never sets it keeps today's behavior exactly.
/// See `quality-gate-swift-project/plans/proposals/CheckerRootThreading.md`.
@Suite("Configuration project root")
struct ProjectRootThreadingTests {

    @Test("The fallback is the current directory")
    func fallbackIsCurrentDirectory() throws {
        let configuration = Configuration()
        #expect(configuration.resolvedProjectRoot.path
            == URL(fileURLWithPath: FileManager.default.currentDirectoryPath).path)
    }

    @Test("An explicit root wins over the current directory")
    func explicitRootWins() throws {
        var configuration = Configuration()
        let root = URL(fileURLWithPath: "/tmp/some-other-checkout")
        configuration.projectRoot = root
        #expect(configuration.resolvedProjectRoot.path == root.path)
        #expect(configuration.resolvedProjectRoot.path != FileManager.default.currentDirectoryPath
            || FileManager.default.currentDirectoryPath == root.path)
    }

    @Test("The root is runtime state: it does not survive encoding")
    func rootIsNotEncoded() throws {
        var configuration = Configuration()
        configuration.projectRoot = URL(fileURLWithPath: "/tmp/checkout-a")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(configuration)
        let decoded = try JSONDecoder().decode(Configuration.self, from: data)
        #expect(decoded.projectRoot == nil, "a runtime-resolved root must not round-trip as configuration")
        #expect(!String(decoding: data, as: UTF8.self).contains("checkout-a"),
                "the root must not appear in encoded configuration at all")
    }

    @Test("Setting the root does not perturb the configuration salt")
    func rootDoesNotChangeSalt() throws {
        var withRoot = Configuration()
        withRoot.projectRoot = URL(fileURLWithPath: "/tmp/checkout-b")
        let without = Configuration()
        // Cache salts digest the encoded configuration; two checkouts of the same repo
        // must produce identical salts or every cache becomes location-dependent.
        #expect(CheckerFingerprint.canonicalSalt(withRoot) == CheckerFingerprint.canonicalSalt(without))
    }
}
