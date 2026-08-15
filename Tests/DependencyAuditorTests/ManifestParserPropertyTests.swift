import Foundation
import Testing
@testable import DependencyAuditor

/// Properties for the manifest and import extractors.
///
/// These read `Package.swift` and arbitrary Swift source to decide what a package
/// declares and what it imports — the inputs to the hallucinated-import check. A
/// parser that invents a name here reports a dependency defect that does not exist;
/// one that drops a name misses a real one. Both failures are silent.
///
/// The invariants are the parser ones from `test_driven_development.md` §4b: nothing
/// is invented, and arbitrary input does not trap.
@Suite("Manifest parser properties")
struct ManifestParserPropertyTests {

    private struct Seeded: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
    }

    private func pick<T>(_ options: [T], _ rng: inout Seeded) -> T {
        options[Int(rng.next() % UInt64(options.count))]
    }

    private func names(_ count: Int, prefix: String, _ rng: inout Seeded) -> [String] {
        (0..<count).map { "\(prefix)\($0)\(pick(["", "Kit", "Core", "Auditor"], &rng))" }
    }

    /// Renders a manifest of the shape SwiftPM actually accepts, including the
    /// constructs that break a naive text scan: a target *reference* inside
    /// `dependencies:`, and a product listing target names as strings.
    private func manifest(targets: [String], products: [String]) -> String {
        let targetDecls = targets.map { name in
            """
                    .target(
                        name: "\(name)",
                        dependencies: [.target(name: "SomeDependency")]
                    ),
            """
        }.joined(separator: "\n")
        let productDecls = products.map { name in
            """
                    .library(name: "\(name)", targets: \(targets.map { "\"\($0)\"" })),
            """
        }.joined(separator: "\n")
        return """
            // swift-tools-version: 6.2
            import PackageDescription
            let package = Package(
                name: "Probe",
                products: [
            \(productDecls)
                ],
                targets: [
            \(targetDecls)
                ]
            )
            """
    }

    // MARK: - Target and product extraction

    /// **Parser.** Every declared target is recovered, and nothing else is — in
    /// particular not `SomeDependency`, which appears as a `.target(name:)` *reference*
    /// inside a `dependencies:` array rather than as a declaration.
    ///
    /// That distinction is the reason this reads the tree instead of matching
    /// `.target(name:` textually, and it is exactly the shape a property pins down.
    @Test("Declared targets are recovered; references are not")
    func targetsAreDeclarationsNotReferences() {
        var rng = Seeded(seed: 20_260_815)
        for count in 1...8 {
            let targets = names(count, prefix: "Target", &rng)
            let source = manifest(targets: targets, products: names(2, prefix: "Lib", &rng))
            let recovered = DependencyAuditor.extractTargetNames(from: source)
            #expect(Set(recovered) == Set(targets),
                    "count \(count): recovered \(recovered)")
            #expect(!recovered.contains("SomeDependency"),
                    "a dependency reference was counted as a declaration")
        }
    }

    /// **Parser.** Every recovered name occurs in the source. Nothing is invented.
    @Test("Every recovered name occurs in the manifest")
    func namesComeFromTheManifest() {
        var rng = Seeded(seed: 4_242)
        for _ in 0..<60 {
            let targets = names(1 + Int(rng.next() % 6), prefix: "T", &rng)
            let products = names(1 + Int(rng.next() % 4), prefix: "P", &rng)
            let source = manifest(targets: targets, products: products)
            for name in DependencyAuditor.extractTargetNames(from: source) {
                #expect(source.contains(name))
            }
            for name in DependencyAuditor.extractProductNames(from: source) {
                #expect(source.contains(name))
            }
        }
    }

    /// **Parser.** Products and targets are distinguished. A product named the same as
    /// a target must not make either extractor report the other's population.
    @Test("Products and targets are not confused for one another")
    func productsAndTargetsAreDistinct() {
        var rng = Seeded(seed: 777)
        for count in 1...5 {
            let shared = names(count, prefix: "Shared", &rng)
            let source = manifest(targets: shared, products: shared)
            #expect(Set(DependencyAuditor.extractTargetNames(from: source)) == Set(shared))
            #expect(Set(DependencyAuditor.extractProductNames(from: source)) == Set(shared))
        }
    }

    /// **Parser.** Arbitrary text yields a result rather than trapping. A manifest
    /// reader runs over whatever is on disk, including files mid-edit.
    @Test("Arbitrary text does not trap the manifest parser")
    func manifestParserNeverTraps() {
        var rng = Seeded(seed: 5_150)
        let fragments = ["Package(", "targets:", "[", "]", ".target(", "name:", "\"A\"",
                         ",", ")", "\n", "//", "\"\"\"", "let", "="]
        for _ in 0..<300 {
            let source = (0..<Int(rng.next() % 30))
                .map { _ in pick(fragments, &rng) }
                .joined(separator: " ")
            let targets = DependencyAuditor.extractTargetNames(from: source)
            let products = DependencyAuditor.extractProductNames(from: source)
            for name in targets + products { #expect(source.contains(name)) }
        }
    }

    // MARK: - Import extraction

    /// **Parser.** Every import recovered occurs in the source, and every import
    /// written is recovered — the two halves that make a hallucinated-import finding
    /// mean something.
    @Test("Imports round-trip out of source text")
    func importsRoundTrip() {
        var rng = Seeded(seed: 31_337)
        let modules = ["Foundation", "SwiftSyntax", "QualityGateCore", "os", "Testing"]
        for count in 1...5 {
            let chosen = (0..<count).map { _ in pick(modules, &rng) }
            let source = chosen.map { "import \($0)" }.joined(separator: "\n")
                + "\n\nstruct Probe {}\n"
            let recovered = DependencyAuditor.extractImports(from: source).map(\.moduleName)
            #expect(Set(recovered) == Set(chosen), "wrote \(chosen), got \(recovered)")
            for name in recovered { #expect(source.contains(name)) }
        }
    }

    /// **Parser.** An import inside a string literal or a comment is not an import.
    /// This is the shape that defeats a line scan, and the reason the extractor walks
    /// the tree.
    @Test("Imports in comments and string literals are not counted")
    func commentedImportsAreNotImports() {
        let source = #"""
            import Foundation
            // import NotReal
            let fixture = """
                import AlsoNotReal
                """
            """#
        let recovered = DependencyAuditor.extractImports(from: source).map(\.moduleName)
        #expect(recovered == ["Foundation"], "recovered \(recovered)")
    }

    /// **Parser.** Arbitrary text does not trap the import extractor.
    @Test("Arbitrary text does not trap the import extractor")
    func importExtractorNeverTraps() {
        var rng = Seeded(seed: 909)
        let fragments = ["import", "Foundation", "\n", "//", "\"", "@testable",
                         "struct", "{", "}", "."]
        for _ in 0..<300 {
            let source = (0..<Int(rng.next() % 25))
                .map { _ in pick(fragments, &rng) }
                .joined(separator: " ")
            for statement in DependencyAuditor.extractImports(from: source) {
                #expect(source.contains(statement.moduleName))
            }
        }
    }
}
