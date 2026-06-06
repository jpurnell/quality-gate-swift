import Testing
import Foundation
import Yams
@testable import IJSAggregator
@testable import IJSSensor

@Suite("Tier Override")
struct TierOverrideTests {

    // MARK: - CorpusManifestEntry

    @Test("CorpusManifestEntry with tierOverride round-trips through JSON")
    func entryWithTierOverrideRoundTrips() throws {
        let entry = CorpusManifestEntry(
            lifecycle: .active,
            changedAt: Date(timeIntervalSince1970: 1747267200),
            tierOverride: .baseline
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CorpusManifestEntry.self, from: data)
        #expect(decoded.tierOverride == .baseline)
        #expect(decoded.lifecycle == .active)
    }

    @Test("CorpusManifestEntry without tierOverride decodes as nil")
    func entryWithoutTierOverrideDecodesNil() throws {
        let entry = CorpusManifestEntry(
            lifecycle: .active,
            changedAt: Date(timeIntervalSince1970: 1747267200)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CorpusManifestEntry.self, from: data)
        #expect(decoded.tierOverride == nil)
    }

    // MARK: - YAML Load

    @Test("CorpusManifest.load parses tierOverride from YAML")
    func loadParsesTierOverride() throws {
        let yaml = """
projects:
  BioFeedbackKit-EdgeBLE:
    lifecycle: active
    changedAt: 2026-06-05T17:07:43Z
    tierOverride: baseline
groups: {}
"""
        let url = try writeTemporaryYAML(yaml)
        let manifest = try CorpusManifest.load(from: url)
        #expect(manifest.projects["BioFeedbackKit-EdgeBLE"]?.tierOverride == .baseline)
    }

    @Test("CorpusManifest.load without tierOverride defaults to nil")
    func loadDefaultsToNil() throws {
        let yaml = """
projects:
  SomeProject:
    lifecycle: active
    changedAt: 2026-06-05T17:07:43Z
groups: {}
"""
        let url = try writeTemporaryYAML(yaml)
        let manifest = try CorpusManifest.load(from: url)
        #expect(manifest.projects["SomeProject"]?.tierOverride == nil)
    }

    // MARK: - YAML Save

    @Test("CorpusManifest.save writes tierOverride when present")
    func saveWritesTierOverride() throws {
        var manifest = CorpusManifest()
        manifest.projects["TestProject"] = CorpusManifestEntry(
            lifecycle: .active,
            changedAt: Date(timeIntervalSince1970: 1747267200),
            tierOverride: .baseline
        )
        let url = temporaryFileURL()
        try manifest.save(to: url)
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("tierOverride: baseline"))
    }

    @Test("CorpusManifest.save omits tierOverride when nil")
    func saveOmitsTierOverrideWhenNil() throws {
        var manifest = CorpusManifest()
        manifest.projects["TestProject"] = CorpusManifestEntry(
            lifecycle: .active,
            changedAt: Date(timeIntervalSince1970: 1747267200)
        )
        let url = temporaryFileURL()
        try manifest.save(to: url)
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(!content.contains("tierOverride"))
    }

    @Test("CorpusManifest.save round-trips with load")
    func saveLoadRoundTrip() throws {
        var manifest = CorpusManifest()
        manifest.projects["ProjectA"] = CorpusManifestEntry(
            lifecycle: .active,
            changedAt: Date(timeIntervalSince1970: 1747267200),
            tierOverride: .dormant
        )
        manifest.projects["ProjectB"] = CorpusManifestEntry(
            lifecycle: .active,
            changedAt: Date(timeIntervalSince1970: 1747267200)
        )
        manifest.groups = ["G": ["ProjectA", "ProjectB"]]
        let url = temporaryFileURL()
        try manifest.save(to: url)
        let loaded = try CorpusManifest.load(from: url)
        #expect(loaded.projects["ProjectA"]?.tierOverride == .dormant)
        #expect(loaded.projects["ProjectB"]?.tierOverride == nil)
        #expect(loaded.groups["G"]?.count == 2)
    }

    // MARK: - Helpers

    private func writeTemporaryYAML(_ content: String) throws -> URL {
        let url = temporaryFileURL()
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func temporaryFileURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("test_manifest_\(UUID().uuidString).yml")
    }
}
