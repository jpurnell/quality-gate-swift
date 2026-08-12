import Foundation
import Testing
@testable import DocCodeAuditor
@testable import QualityGateCore

/// A project laid out with `Source/` must not be reported as a project with nothing to check.
///
/// The dependency half of this was fixed for C modulemaps, where the cost is a barrier — loud,
/// and the diagnostic says the count means nothing. This is the project-under-test half, where
/// the cost is zero discovered articles, which is reported exactly as "nothing wrong" and passes.
@Suite("Source layout")
struct SourceLayoutTests {

    private static func project(spelling: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("layout-\(UUID().uuidString)")
        let catalogue = root
            .appendingPathComponent(spelling).appendingPathComponent("Alpha")
            .appendingPathComponent("Alpha.docc")
        try FileManager.default.createDirectory(at: catalogue, withIntermediateDirectories: true)
        try "# ``Alpha``\n\nAn article.\n"
            .write(to: catalogue.appendingPathComponent("Alpha.md"), atomically: true, encoding: .utf8)
        return root
    }

    @Test("A catalogue under `Sources/` is found", arguments: ["Sources", "Source", "src"])
    func cataloguesAreFoundUnderEverySpelling(spelling: String) throws {
        let root = try Self.project(spelling: spelling)
        defer { try? FileManager.default.removeItem(at: root) }

        let catalogues = ArticleDiscovery.catalogues(
            projectRoot: root, configuration: Configuration())

        #expect(catalogues.count == 1)
        #expect(catalogues.first?.moduleName == "Alpha")
    }

    @Test("A module path is attributed under every spelling")
    func moduleAttributionAcceptsEverySpelling() {
        #expect(SourceLayout.isSourceRoot("Sources"))
        #expect(SourceLayout.isSourceRoot("Source"))
        #expect(SourceLayout.isSourceRoot("src"))
        #expect(!SourceLayout.isSourceRoot("Tests"))
        #expect(!SourceLayout.isSourceRoot("Documentation"))
    }

    @Test("A project with no catalogue anywhere still yields nothing, and that is honest")
    func genuinelyUndocumentedProjectYieldsNothing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/Alpha"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The distinction this whole change is about: *this* project really has nothing to
        // check, and the emptiness is a fact rather than a missed directory. `doc-lint`'s
        // coverage diagnostic is what tells the two apart at the checker level.
        #expect(ArticleDiscovery.catalogues(
            projectRoot: root, configuration: Configuration()).isEmpty)
    }
}
