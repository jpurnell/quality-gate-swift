import Foundation
import Testing
import Yams
@testable import QualityGateCore

/// The advisory keys under `dependencyAudit:`.
///
/// A key the decoder discards is a setting the user wrote that had no effect, and for an
/// acknowledgement that means a finding the user believes is excused and is not — or, worse, the
/// reverse. Each key is decoded here from the YAML a person would actually type.
@Suite("dependency-advisory configuration")
struct DependencyAdvisoryConfigTests {

    private func decode(_ yaml: String) throws -> Configuration {
        try YAMLDecoder().decode(Configuration.self, from: yaml)
    }

    @Test("an absent block leaves every advisory key at its default")
    func defaults() throws {
        let config = try decode("strict: true\n").dependencyAudit
        #expect(config.acknowledgedAdvisories.isEmpty)
        #expect(config.advisorySnapshotPath == ".quality-gate/advisories/swifturl.json")
        #expect(config.advisorySnapshotMaxAgeDays == 14)
        #expect(config.ownPackages.isEmpty)
        #expect(config.offlineMode == false)
    }

    /// The proposal's own example, typed the way it is printed there — the date unquoted, which
    /// YAML reads as a timestamp and a careless decoder would refuse or reformat.
    @Test("the acknowledgement in the proposal decodes as written, unquoted date included")
    func acknowledgementDecodes() throws {
        let config = try decode("""
        dependencyAudit:
          acknowledgedAdvisories:
            - id: GHSA-g454-wj9r-jpg4
              package: github.com/marmelroy/Zip
              reason: "Transitive via polar-ble-sdk. No code path here extracts an archive."
              until: 2027-01-01
        """).dependencyAudit

        #expect(config.acknowledgedAdvisories == [
            AcknowledgedAdvisory(
                id: "GHSA-g454-wj9r-jpg4",
                package: "github.com/marmelroy/Zip",
                reason: "Transitive via polar-ble-sdk. No code path here extracts an archive.",
                until: "2027-01-01"),
        ])
    }

    /// An entry missing a field must reach the checker, which rejects it in a message that names
    /// what is missing. If decoding threw instead, the whole configuration would fall back to
    /// defaults and every other setting in the file would silently stop applying.
    @Test("an incomplete acknowledgement still decodes, with the missing fields empty")
    func incompleteAcknowledgementDecodes() throws {
        let config = try decode("""
        dependencyAudit:
          acknowledgedAdvisories:
            - id: GHSA-g454-wj9r-jpg4
        """).dependencyAudit
        #expect(config.acknowledgedAdvisories == [
            AcknowledgedAdvisory(id: "GHSA-g454-wj9r-jpg4", package: "", reason: "", until: ""),
        ])
    }

    @Test("the snapshot path, the maximum age, own packages and offline mode decode")
    func scalarKeysDecode() throws {
        let config = try decode("""
        dependencyAudit:
          advisorySnapshotPath: config/advisories.json
          advisorySnapshotMaxAgeDays: 30
          offlineMode: true
          ownPackages:
            - github.com/jpurnell/
        """).dependencyAudit
        #expect(config.advisorySnapshotPath == "config/advisories.json")
        #expect(config.advisorySnapshotMaxAgeDays == 30)
        #expect(config.offlineMode == true)
        #expect(config.ownPackages == ["github.com/jpurnell/"])
    }

    @Test("the advisory keys survive a round trip through encoding")
    func roundTrips() throws {
        var config = Configuration()
        config.dependencyAudit = DependencyAuditorConfig(
            acknowledgedAdvisories: [
                AcknowledgedAdvisory(id: "GHSA-a", package: "github.com/a/b", reason: "r", until: "2027-01-01"),
            ],
            advisorySnapshotPath: "x.json",
            advisorySnapshotMaxAgeDays: 7,
            ownPackages: ["github.com/a/"])
        let yaml = try YAMLEncoder().encode(config)
        #expect(try decode(yaml).dependencyAudit == config.dependencyAudit)
    }

    /// The existing keys were decoded before this change and must still be.
    @Test("the keys dependency-audit already had are untouched")
    func existingKeysStillDecode() throws {
        let config = try decode("""
        dependencyAudit:
          allowBranchPins: [indexstore-db]
          additionalKnownModules: [Bridging]
          maxMajorVersionsBehind: 5
        """).dependencyAudit
        #expect(config.allowBranchPins == ["indexstore-db"])
        #expect(config.additionalKnownModules == ["Bridging"])
        #expect(config.maxMajorVersionsBehind == 5)
    }
}
