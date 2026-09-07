import Foundation
import Testing
@testable import DocGeneratedAuditor
@testable import QualityGateCore

/// The headline counts, derived so they cannot drift again.
///
/// These numbers were wrong in three documents simultaneously, in three different directions,
/// before this generator existed. On its first run against the real tree it rejected a
/// hand-written `46 registered checkers` — a figure introduced hours earlier while *correcting*
/// the same line — and demanded the 45 the registry actually declares.
@Suite("Scale Generator")
struct ScaleGeneratorTests {

    /// A manifest shaped like the real one: mixed target kinds, a product `targets:` list that
    /// must not be counted, and a dependency `.target(name:)` that declares nothing.
    private static let manifest = """
    // swift-tools-version: 6.2
    import PackageDescription

    let package = Package(
        name: "Example",
        products: [
            .library(name: "Alpha", targets: ["Alpha"])
        ],
        dependencies: [
            .package(url: "https://example.com/dep.git", from: "1.0.0")
        ],
        targets: [
            .target(name: "Alpha"),
            .executableTarget(name: "alpha-cli"),
            .testTarget(name: "AlphaTests"),
            .testTarget(name: "BetaTests")
        ]
    )
    """

    private static let registry = """
    enum QualityGateCLI {
        static func checkerRegistry(configuration: Configuration) -> [any QualityChecker] {
            return [
                Alpha(),
                // A comment between entries, which the parser must step over.
                Beta(config: configuration.beta),
                Gamma()
            ]
        }
    }
    """

    private static func fixture() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scale-\(UUID().uuidString)", isDirectory: true)
        let cli = root.appendingPathComponent("Sources/QualityGateCLI", isDirectory: true)
        try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: true)
        try manifest.write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try registry.write(
            to: cli.appendingPathComponent("QualityGateCLI.swift"), atomically: true, encoding: .utf8)
        return root
    }

    @Test("Counts source and test targets separately, and their sum")
    func countsTargets() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try ScaleGenerator().generate(
            projectRoot: root, currentBody: "", configuration: Configuration())

        #expect(body.contains("**4 targets** — 2 source, 2 test"))
    }

    @Test("Counts the registry's entries, not every call in the file")
    func countsCheckers() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try ScaleGenerator().generate(
            projectRoot: root, currentBody: "", configuration: Configuration())

        #expect(body.contains("**3 registered checkers**"))
    }

    @Test("A product's targets: list is not a target declaration")
    func productListIsNotCounted() throws {
        // `.library(name: "Alpha", targets: ["Alpha"])` names a target that is already counted
        // once. Counting the mention would report 5 targets for a package that declares 4.
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try ScaleGenerator().generate(
            projectRoot: root, currentBody: "", configuration: Configuration())

        #expect(!body.contains("5 targets"))
    }

    @Test("Ignores whatever the region currently says")
    func currentBodyIsNotConsulted() throws {
        // Unlike the roster generators, nothing here is the author's to preserve. A stale body
        // must not survive into the output, which is the entire point of the region.
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let generator = ScaleGenerator()
        let fromStale = try generator.generate(
            projectRoot: root,
            currentBody: "- **999 targets** — 1 source, 1 test\n- **999 registered checkers**",
            configuration: Configuration())
        let fromEmpty = try generator.generate(
            projectRoot: root, currentBody: "", configuration: Configuration())

        #expect(fromStale == fromEmpty)
        #expect(!fromStale.contains("999"))
    }

    @Test("An absent manifest is ungeneratable, not zero")
    func absentManifestThrows() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scale-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Zero would be a claim the tree does not support. `doc-generated` reports a throw as a
        // finding, so the failure is visible rather than becoming a confident "0 targets".
        #expect(throws: RegionGeneratorError.self) {
            try ScaleGenerator().generate(
                projectRoot: root, currentBody: "", configuration: Configuration())
        }
    }

    @Test("A registry with no entries is ungeneratable, not zero checkers")
    func emptyRegistryThrows() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("Sources/QualityGateCLI/QualityGateCLI.swift")
        try "enum QualityGateCLI {}".write(to: cli, atomically: true, encoding: .utf8)

        #expect(throws: RegionGeneratorError.self) {
            try ScaleGenerator().generate(
                projectRoot: root, currentBody: "", configuration: Configuration())
        }
    }

    @Test("The generator is registered, so a `scale` region is not 'unknown'")
    func isRegistered() {
        // Asserting the identity rather than mere presence: an unregistered id makes the
        // region "unknown" and silently ungoverned, and a *wrongly* registered one would
        // regenerate it from the wrong source while still passing a nil check.
        let generator = RegionGeneratorRegistry.generator(for: "scale")
        #expect(generator is ScaleGenerator)
        #expect(generator?.id == "scale")
        #expect(generator?.derivedFrom == ScaleGenerator().derivedFrom)
        #expect(RegionGeneratorRegistry.ids.filter { $0 == "scale" }.count == 1)
    }
}
