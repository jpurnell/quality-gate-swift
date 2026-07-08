import Foundation
import Testing
@testable import LegibilityAnalyzer

@Suite("PackageGraphLoader")
struct PackageGraphLoaderTests {

    private let manifest = """
    let package = Package(
        name: "demo",
        targets: [
            .target(
                name: "Core",
                dependencies: []
            ),
            .target(
                name: "Feature",
                dependencies: [
                    "Core",
                    .product(name: "SwiftSyntax", package: "swift-syntax"),
                ]
            ),
            .executableTarget(
                name: "App",
                dependencies: ["Core", "Feature"]
            ),
            .testTarget(
                name: "FeatureTests",
                dependencies: ["Feature"]
            ),
        ]
    )
    """

    @Test("parses target names and their quoted dependencies")
    func parsesTargets() {
        let targets = PackageGraphLoader.parseTargets(packageSource: manifest)
        let byName = Dictionary(uniqueKeysWithValues: targets.map { ($0.name, $0.dependencies) })
        #expect(Set(byName.keys) == ["Core", "Feature", "App", "FeatureTests"])
        #expect(byName["App"] == ["Core", "Feature"])
        // Feature's tail includes the external product's quoted names too.
        #expect(byName["Feature"]?.contains("Core") == true)
        #expect(byName["Feature"]?.contains("SwiftSyntax") == true)
    }

    @Test("declaredGraph keeps first-party edges and drops external products")
    func declaredGraphFiltersExternal() {
        let graph = PackageGraphLoader.declaredGraph(packageSource: manifest)
        // Feature depends on Core only (SwiftSyntax/swift-syntax are not targets).
        #expect(graph.dependencies(of: "Feature") == ["Core"])
        #expect(graph.dependencies(of: "App") == ["Core", "Feature"])
        // Core's direct dependents are Feature and App (FeatureTests depends on
        // Feature, not Core directly).
        #expect(graph.fanIn("Core") == 2)
        #expect(graph.dependencies(of: "Core").isEmpty)
    }

    @Test("declaredGraph reading order is foundation-first")
    func readingOrder() {
        let graph = PackageGraphLoader.declaredGraph(packageSource: manifest)
        #expect(graph.topologicalReadingOrder().first == "Core")
    }

    @Test("declaredGraph can exclude test targets for the human reading order")
    func excludesTestTargets() {
        let graph = PackageGraphLoader.declaredGraph(packageSource: manifest, includingTestTargets: false)
        #expect(!graph.modules.contains("FeatureTests"))
        #expect(graph.modules.contains("Feature"))
        // Default keeps them (faithful parse).
        let full = PackageGraphLoader.declaredGraph(packageSource: manifest)
        #expect(full.modules.contains("FeatureTests"))
    }

    @Test("empty or malformed manifest yields an empty graph")
    func emptyManifest() {
        #expect(PackageGraphLoader.parseTargets(packageSource: "").isEmpty)
        #expect(PackageGraphLoader.declaredGraph(packageSource: "no targets here").modules.isEmpty)
    }
}
