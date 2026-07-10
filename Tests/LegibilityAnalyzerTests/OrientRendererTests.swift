import Foundation
import Testing
@testable import LegibilityAnalyzer

/// Phase 1, workstream 3 — the `orient` document renderer.
///
/// One self-contained page per package: summary prose, what it's built from,
/// the fan-in-weighted reading order, per-module cards with roles labeled
/// *(inferred)* (role humility, §2b), and — when the analyzed repo declares
/// no config of its own — the provenance watermark.
@Suite("OrientRenderer")
struct OrientRendererTests {

    private func fixtureDocument(watermarked: Bool) -> OrientDocument {
        let map = LegibilityMap(
            readingOrder: ["Core", "App"],
            cards: [
                ModuleCard(moduleName: "Core", fanIn: 1, weightedFanIn: 3, fanOut: 0,
                           hasOrientationDoc: true, overPublicCount: 0, role: "foundation"),
                ModuleCard(moduleName: "App", fanIn: 0, weightedFanIn: 0, fanOut: 1,
                           hasOrientationDoc: false, overPublicCount: 2, role: "entry-point"),
            ],
            cycles: [])
        return OrientDocument(
            packageName: "SuperKit",
            summary: "A networking layer for people who hate networking layers.",
            builtFrom: ["swift-syntax", "swift-collections"],
            map: map,
            watermarked: watermarked)
    }

    @Test("markdown carries name, summary, composition, and reading order")
    func markdownContent() {
        let markdown = OrientRenderer.markdown(fixtureDocument(watermarked: false))
        #expect(markdown.contains("# SuperKit"))
        #expect(markdown.contains("A networking layer for people who hate networking layers."))
        #expect(markdown.contains("swift-syntax"))
        #expect(markdown.contains("swift-collections"))
        #expect(markdown.contains("1. Core"))
        #expect(markdown.contains("2. App"))
    }

    @Test("roles are explicitly labeled as inferred")
    func rolesLabeledInferred() {
        let markdown = OrientRenderer.markdown(fixtureDocument(watermarked: false))
        #expect(markdown.contains("Role (inferred)"))
        #expect(markdown.contains("foundation"))
        #expect(markdown.contains("entry-point"))
    }

    @Test("watermark appears exactly when the run is foreign to the repo's standards")
    func watermarkPresence() {
        let with = OrientRenderer.markdown(fixtureDocument(watermarked: true))
        #expect(with.contains("does not represent the project's own quality standard"))

        let without = OrientRenderer.markdown(fixtureDocument(watermarked: false))
        #expect(!without.contains("does not represent the project's own quality standard"))
    }

    @Test("a package with cycles gets the cycles section")
    func cyclesSection() {
        let map = LegibilityMap(
            readingOrder: ["A", "B"],
            cards: [],
            cycles: [["A", "B"]])
        let doc = OrientDocument(
            packageName: "Tangle", summary: nil, builtFrom: [], map: map, watermarked: false)
        let markdown = OrientRenderer.markdown(doc)
        #expect(markdown.contains("Dependency Cycles"))
        #expect(markdown.contains("A → B"))
    }

    @Test("missing summary and empty composition degrade gracefully")
    func gracefulDegradation() {
        let map = LegibilityMap(readingOrder: ["Solo"], cards: [], cycles: [])
        let doc = OrientDocument(
            packageName: "Solo", summary: nil, builtFrom: [], map: map, watermarked: false)
        let markdown = OrientRenderer.markdown(doc)
        #expect(markdown.contains("# Solo"))
        #expect(markdown.contains("1. Solo"))
        #expect(!markdown.contains("Built from"))
    }

    @Test("json round-trips the full document")
    func jsonRoundTrip() throws {
        let doc = fixtureDocument(watermarked: true)
        let json = try OrientRenderer.json(doc)
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(OrientDocument.self, from: data)
        #expect(decoded == doc)
        #expect(json.contains("SuperKit"))
    }
}
