import Foundation
import Testing
@testable import ControlMapping

/// Phase 3 — `standards-watch` drift detection. Detect-and-alert only: the
/// classifier never edits a catalog, and its verdicts are deterministic over an
/// injected source so the logic is tested without the network.
@Suite("StandardsWatch")
struct StandardsWatchTests {

    private func catalog(
        framework: String = "hipaa-security-rule",
        source: String = "ecfr",
        upstreamHash: String? = nil
    ) -> ControlCatalog {
        ControlCatalog(
            framework: framework, version: "v", source: source,
            sourceRef: "https://example/\(framework)", fetched: "2026-07-31",
            contentHash: "h", reviewedBy: "me", reviewed: "2026-07-31",
            superseded: false, upstreamHash: upstreamHash,
            controls: [Control(id: "X", title: "X", text: "…", checkability: .partial)])
    }

    private struct StubSource: StandardsSource {
        var texts: [String: String] = [:]
        var nilFor: Set<String> = []
        var throwFor: Set<String> = []
        struct Boom: Error {}
        func fetchUpstream(for catalog: ControlCatalog) async throws -> String? {
            if throwFor.contains(catalog.framework) { throw Boom() }
            if nilFor.contains(catalog.framework) { return nil }
            return texts[catalog.framework]
        }
    }

    // MARK: - classify (pure)

    @Test("a copyrighted source is manual-review-only, whatever the fetch returns")
    func copyrightedIsManual() {
        for src in ["aicpa", "iso"] {
            let result = StandardsWatch.classify(catalog: catalog(source: src), fetched: "anything")
            #expect(result.state == .manualReviewOnly)
        }
    }

    @Test("a fetchable source with no text is unreachable")
    func unreachable() {
        let result = StandardsWatch.classify(catalog: catalog(source: "ecfr"), fetched: nil)
        #expect(result.state == .unreachable)
    }

    @Test("first observation seeds, nothing to compare yet")
    func seeded() {
        let result = StandardsWatch.classify(catalog: catalog(upstreamHash: nil), fetched: "the rule text")
        #expect(result.state == .seeded)
    }

    @Test("matching upstream hash is unchanged")
    func unchanged() {
        let text = "45 CFR 164.312 …"
        let result = StandardsWatch.classify(
            catalog: catalog(upstreamHash: StandardsWatch.sha256Hex(text)), fetched: text)
        #expect(result.state == .unchanged)
    }

    @Test("a changed upstream is drift — the alarm")
    func drifted() {
        let result = StandardsWatch.classify(
            catalog: catalog(upstreamHash: StandardsWatch.sha256Hex("old text")),
            fetched: "new, amended text")
        #expect(result.state == .drifted)
        #expect(result.detail.contains("reconcile"))
    }

    // MARK: - sha256Hex

    @Test("hashing is deterministic and 64 hex chars")
    func hashStable() {
        let hash1 = StandardsWatch.sha256Hex("x")
        let hash2 = StandardsWatch.sha256Hex("x")
        #expect(hash1 == hash2)
        #expect(hash1.count == 64)
        #expect(hash1.allSatisfy { $0.isHexDigit })
        #expect(StandardsWatch.sha256Hex("x") != StandardsWatch.sha256Hex("y"))
    }

    // MARK: - run (orchestration)

    @Test("run classifies each catalog and never fails the whole batch on one error")
    func runOverMany() async {
        let text = "steady text"
        let catalogs = [
            catalog(framework: "hipaa-security-rule", source: "ecfr", upstreamHash: StandardsWatch.sha256Hex(text)),
            catalog(framework: "soc2-tsc", source: "aicpa"),
            catalog(framework: "iso-27001-annexa", source: "iso"),
            catalog(framework: "broken", source: "ecfr"),
        ]
        let source = StubSource(
            texts: ["hipaa-security-rule": text],
            throwFor: ["broken"])
        let results = await StandardsWatch.run(catalogs: catalogs, source: source)

        #expect(results.count == 4)
        #expect(results.first { $0.framework == "hipaa-security-rule" }?.state == .unchanged)
        #expect(results.first { $0.framework == "soc2-tsc" }?.state == .manualReviewOnly)
        #expect(results.first { $0.framework == "iso-27001-annexa" }?.state == .manualReviewOnly)
        #expect(results.first { $0.framework == "broken" }?.state == .unreachable)
    }
}
