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

/// Phase 4 §2 — the shareable single-file HTML report.
@Suite("OrientRenderer HTML")
struct OrientRendererHTMLTests {

    private func fixture(watermarked: Bool) -> OrientDocument {
        OrientDocument(
            packageName: "SuperKit",
            summary: "A networking layer for people who hate networking layers.",
            builtFrom: ["swift-syntax"],
            map: LegibilityMap(
                readingOrder: ["Core", "App"],
                cards: [ModuleCard(moduleName: "Core", fanIn: 1, weightedFanIn: 3, fanOut: 0,
                                   hasOrientationDoc: true, overPublicCount: 0, role: "foundation")],
                cycles: [["A", "B"]]),
            watermarked: watermarked)
    }

    @Test("html is a self-contained single file: inline style, no external refs")
    func selfContained() {
        let html = OrientRenderer.html(fixture(watermarked: false))
        #expect(html.contains("<style>"))
        #expect(!html.contains("http://"))
        #expect(!html.contains("https://"))
        #expect(!html.contains("src="))
    }

    @Test("html carries name, summary, order, cards, cycles")
    func content() {
        let html = OrientRenderer.html(fixture(watermarked: false))
        #expect(html.contains("SuperKit"))
        #expect(html.contains("A networking layer for people who hate networking layers."))
        #expect(html.contains("Core"))
        #expect(html.contains("foundation"))
        #expect(html.contains("swift-syntax"))
        #expect(html.contains("A → B"))
    }

    @Test("the watermark renders exactly when foreign")
    func watermark() {
        #expect(OrientRenderer.html(fixture(watermarked: true))
            .contains("does not represent the project&#39;s own quality standard"))
        #expect(!OrientRenderer.html(fixture(watermarked: false))
            .contains("does not represent"))
    }

    @Test("package names are HTML-escaped")
    func escaping() {
        let doc = OrientDocument(
            packageName: "a<b & c>d",
            summary: nil, builtFrom: [],
            map: LegibilityMap(readingOrder: [], cards: [], cycles: []),
            watermarked: false)
        let html = OrientRenderer.html(doc)
        #expect(html.contains("a&lt;b &amp; c&gt;d"))
        #expect(!html.contains("a<b & c>d"))
    }
}
