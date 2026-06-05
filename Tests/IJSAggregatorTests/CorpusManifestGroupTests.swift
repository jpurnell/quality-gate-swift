import Testing
import Foundation
@testable import IJSAggregator

@Suite("CorpusManifestGroup")
struct CorpusManifestGroupTests {

    // MARK: - YAML Loading with Groups

    @Test("Loads manifest YAML with groups section")
    func loadWithGroups() throws {
        let tmp = NSTemporaryDirectory() + "ijs-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let manifestPath = "\(tmp)/manifest.yml"
        let yaml = """
        projects:
          BusinessMath:
            lifecycle: active
            changedAt: "2026-06-01T00:00:00Z"
          IconquerApp:
            lifecycle: active
            changedAt: "2026-06-01T00:00:00Z"
          IconquerCLI:
            lifecycle: sunset
            reason: "Merged into IconquerApp"
            changedAt: "2026-05-20T00:00:00Z"

        groups:
          BusinessMath:
            - BusinessMath
            - BusinessMathExcel
          Iconquer:
            - IconquerApp
            - IconquerCLI
        """
        try yaml.write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let manifest = try CorpusManifest.load(from: URL(fileURLWithPath: manifestPath))
        #expect(manifest.groups.count == 2)
        #expect(manifest.groups["BusinessMath"] == ["BusinessMath", "BusinessMathExcel"])
        #expect(manifest.groups["Iconquer"]?.count == 2)
        #expect(manifest.groups["Iconquer"]?.contains("IconquerApp") == true)
        #expect(manifest.groups["Iconquer"]?.contains("IconquerCLI") == true)
    }

    @Test("Loads manifest YAML without groups section (backward compat)")
    func loadWithoutGroups() throws {
        let tmp = NSTemporaryDirectory() + "ijs-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let manifestPath = "\(tmp)/manifest.yml"
        let yaml = """
        projects:
          alpha:
            lifecycle: active
            changedAt: "2026-05-15T00:00:00Z"
        """
        try yaml.write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let manifest = try CorpusManifest.load(from: URL(fileURLWithPath: manifestPath))
        #expect(manifest.projects.count == 1)
        #expect(manifest.groups.isEmpty)
    }

    // MARK: - group(for:) Lookup

    @Test("group(for:) returns correct group name for grouped project")
    func groupForGroupedProject() {
        let manifest = CorpusManifest(
            projects: [:],
            groups: [
                "BusinessMath": ["BusinessMath", "BusinessMathExcel"],
                "Iconquer": ["IconquerApp", "IconquerCLI"],
            ]
        )
        #expect(manifest.group(for: "BusinessMath") == "BusinessMath")
        #expect(manifest.group(for: "BusinessMathExcel") == "BusinessMath")
        #expect(manifest.group(for: "IconquerApp") == "Iconquer")
        #expect(manifest.group(for: "IconquerCLI") == "Iconquer")
    }

    @Test("group(for:) returns nil for ungrouped project")
    func groupForUngroupedProject() {
        let manifest = CorpusManifest(
            projects: [:],
            groups: [
                "BusinessMath": ["BusinessMath", "BusinessMathExcel"],
            ]
        )
        #expect(manifest.group(for: "SomeOtherProject") == nil)
        #expect(manifest.group(for: "IconquerApp") == nil)
    }

    // MARK: - Codable Round-Trip

    @Test("CorpusManifest with groups round-trips through JSON")
    func codableRoundTripWithGroups() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifest = CorpusManifest(
            projects: [
                "alpha": CorpusManifestEntry(
                    lifecycle: .active,
                    changedAt: Date(timeIntervalSince1970: 1_747_267_200)
                ),
                "beta": CorpusManifestEntry(
                    lifecycle: .sunset,
                    reason: "Deprecated",
                    changedAt: Date(timeIntervalSince1970: 1_747_267_200)
                ),
            ],
            groups: [
                "AlphaGroup": ["alpha", "alpha-ui"],
                "BetaGroup": ["beta"],
            ]
        )

        let data = try encoder.encode(manifest)
        let decoded = try decoder.decode(CorpusManifest.self, from: data)
        #expect(decoded == manifest)
        #expect(decoded.groups["AlphaGroup"] == ["alpha", "alpha-ui"])
        #expect(decoded.groups["BetaGroup"] == ["beta"])
    }
}
