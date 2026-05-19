import Testing
import Foundation
@testable import IJSAggregator

@Suite("ProjectLifecycle")
struct ProjectLifecycleTests {

    // MARK: - Enum Values

    @Test("Raw values match expected strings")
    func rawValues() {
        #expect(ProjectLifecycle.active.rawValue == "active")
        #expect(ProjectLifecycle.sunset.rawValue == "sunset")
    }

    @Test("All cases contains both values")
    func allCases() {
        #expect(ProjectLifecycle.allCases.count == 2)
        #expect(ProjectLifecycle.allCases.contains(.active))
        #expect(ProjectLifecycle.allCases.contains(.sunset))
    }

    // MARK: - Codable Round-Trip

    @Test("ProjectLifecycle round-trips through JSON")
    func lifecycleCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for value in ProjectLifecycle.allCases {
            let data = try encoder.encode(value)
            let decoded = try decoder.decode(ProjectLifecycle.self, from: data)
            #expect(decoded == value)
        }
    }

    @Test("CorpusManifestEntry round-trips through JSON")
    func entryCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let entry = CorpusManifestEntry(
            lifecycle: .sunset,
            reason: "Migrated to new system",
            changedAt: Date(timeIntervalSince1970: 1747267200)
        )
        let data = try encoder.encode(entry)
        let decoded = try decoder.decode(CorpusManifestEntry.self, from: data)
        #expect(decoded == entry)
    }

    @Test("CorpusManifest round-trips through JSON")
    func manifestCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifest = CorpusManifest(projects: [
            "alpha": CorpusManifestEntry(lifecycle: .active, changedAt: Date(timeIntervalSince1970: 1747267200)),
            "beta": CorpusManifestEntry(lifecycle: .sunset, reason: "Deprecated", changedAt: Date(timeIntervalSince1970: 1747267200)),
        ])
        let data = try encoder.encode(manifest)
        let decoded = try decoder.decode(CorpusManifest.self, from: data)
        #expect(decoded == manifest)
    }

    // MARK: - Manifest Lookup

    @Test("Manifest returns lifecycle for known project")
    func manifestLookupKnown() {
        let manifest = CorpusManifest(projects: [
            "alpha": CorpusManifestEntry(lifecycle: .sunset, reason: "EOL", changedAt: Date(timeIntervalSince1970: 1747267200)),
        ])
        #expect(manifest.lifecycle(for: "alpha") == .sunset)
    }

    @Test("Manifest defaults to active for unknown project")
    func manifestLookupUnknown() {
        let manifest = CorpusManifest(projects: [:])
        #expect(manifest.lifecycle(for: "unknown") == .active)
    }

    @Test("Empty manifest treats all projects as active")
    func emptyManifest() {
        let manifest = CorpusManifest()
        #expect(manifest.projects.isEmpty)
        #expect(manifest.lifecycle(for: "anything") == .active)
    }

    // MARK: - YAML Loading

    @Test("Loads manifest from YAML file")
    func loadFromYAML() throws {
        let tmp = NSTemporaryDirectory() + "ijs-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let manifestPath = "\(tmp)/manifest.yml"
        let yaml = """
        projects:
          alpha:
            lifecycle: active
            changedAt: "2026-05-15T00:00:00Z"
          beta:
            lifecycle: sunset
            reason: "Migrated to v2"
            changedAt: "2026-05-10T00:00:00Z"
        """
        try yaml.write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let manifest = try CorpusManifest.load(from: URL(fileURLWithPath: manifestPath))
        #expect(manifest.projects.count == 2)
        #expect(manifest.lifecycle(for: "alpha") == .active)
        #expect(manifest.lifecycle(for: "beta") == .sunset)
        #expect(manifest.projects["beta"]?.reason == "Migrated to v2")
    }

    @Test("Returns empty manifest when file does not exist")
    func loadFromMissingFile() throws {
        let url = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)/manifest.yml")
        let manifest = try CorpusManifest.load(from: url)
        #expect(manifest.projects.isEmpty)
    }

    @Test("Returns empty manifest when projects section is missing")
    func loadFromYAMLWithoutProjects() throws {
        let tmp = NSTemporaryDirectory() + "ijs-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let manifestPath = "\(tmp)/manifest.yml"
        let yaml = """
        version: 1
        """
        try yaml.write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let manifest = try CorpusManifest.load(from: URL(fileURLWithPath: manifestPath))
        #expect(manifest.projects.isEmpty)
    }

    @Test("Throws on non-dictionary YAML")
    func loadFromNonDictionaryYAML() throws {
        let tmp = NSTemporaryDirectory() + "ijs-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let manifestPath = "\(tmp)/manifest.yml"
        // A plain YAML list is valid YAML but not a dictionary, triggering the error path
        try "- item1\n- item2\n".write(toFile: manifestPath, atomically: true, encoding: .utf8)

        #expect(throws: IJSError.self) {
            _ = try CorpusManifest.load(from: URL(fileURLWithPath: manifestPath))
        }
    }

    @Test("Skips entries with invalid lifecycle values")
    func loadFromYAMLWithInvalidLifecycle() throws {
        let tmp = NSTemporaryDirectory() + "ijs-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let manifestPath = "\(tmp)/manifest.yml"
        let yaml = """
        projects:
          alpha:
            lifecycle: active
            changedAt: "2026-05-15T00:00:00Z"
          broken:
            lifecycle: invalid_state
            changedAt: "2026-05-15T00:00:00Z"
        """
        try yaml.write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let manifest = try CorpusManifest.load(from: URL(fileURLWithPath: manifestPath))
        #expect(manifest.projects.count == 1)
        #expect(manifest.lifecycle(for: "alpha") == .active)
        #expect(manifest.lifecycle(for: "broken") == .active) // defaults to active since entry was skipped
    }
}
