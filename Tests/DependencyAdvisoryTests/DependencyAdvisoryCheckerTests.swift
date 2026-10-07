import Foundation
import Testing
import QualityGateCore
@testable import DependencyAdvisory

/// The checker as the gate runs it: discovery, the snapshot it picks, and the contract it declares.
@Suite("dependency-advisory: the checker")
struct DependencyAdvisoryCheckerTests {

    private typealias Pin = AdvisoryFixture.Pin

    @Test("the three checkers are identified, classified, and declare what they depend on")
    func identity() {
        let advisory = DependencyAdvisoryChecker()
        #expect(advisory.id == "dependency-advisory")
        #expect(advisory.name == "Dependency Advisory Checker")
        #expect(advisory.hermeticity == .hermetic)
        #expect(advisory.category == .safetySecurity)

        let freshness = AdvisoryFreshnessChecker()
        #expect(freshness.id == "dependency-advisory-freshness")
        #expect(freshness.hermeticity == .temporal)

        let drift = AdvisoryDriftChecker()
        #expect(drift.id == "dependency-advisory-drift")
        #expect(drift.hermeticity == .external)

        for checker in [advisory, freshness, drift] as [any QualityChecker] {
            #expect(checker.kind == .code)
            #expect(checker.effect == .readOnly)
            #expect(checker.executesProjectCode == false)
            #expect(!checker.summary.isEmpty)
        }
    }

    @Test("lockfiles are found at the root, in nested packages and in Xcode's workspace copy — not in build output")
    func discovery() async throws {
        let project = try AdvisoryTestProject()
        defer { project.remove() }
        let nio = AdvisoryFixture.lockfileText([.version("swift-nio", "https://github.com/apple/swift-nio.git", "2.99.0")])
        try project.write(nio, to: "Package.resolved")
        try project.write(nio, to: "Tools/helper/Package.resolved")
        try project.write(nio, to: "App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        try project.write(nio, to: ".build/checkouts/swift-nio/Package.resolved")
        try project.write(nio, to: ".claude/worktrees/other/Package.resolved")
        try project.write(nio, to: "DerivedData/App/SourcePackages/checkouts/x/Package.resolved")
        try project.write("not a lockfile", to: "Broken/Package.resolved")

        let checker = DependencyAdvisoryChecker(environment: .fixed(
            bundled: try AdvisoryFixture.candidate(records: [AdvisoryFixture.nioHeaderBlocks])))
        let result = try await checker.check(configuration: project.configuration())

        let findings = result.diagnostics.filter { $0.ruleId == "dep-advisory.vulnerable-pin" }
        #expect(findings.map(\.filePath) == [
            "App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
            "Package.resolved",
            "Tools/helper/Package.resolved",
        ])
        #expect(result.diagnostics.filter { $0.ruleId == "dep-advisory.unevaluable" }.map(\.filePath) == [
            "Broken/Package.resolved",
        ])
        #expect(result.diagnostics.last?.message.hasPrefix(
            "dependency-advisory examined 3 lockfiles · 3 pins · 3 third-party · 3 evaluable by version · "
                + "0 unevaluable · 3 affected by 1 advisory · 0 acknowledged · ") == true)
        #expect(result.status == .failed)
        #expect(result.checkerId == "dependency-advisory")
    }

    @Test("a project with no lockfile is skipped, and says there was nothing to check")
    func noLockfile() async throws {
        let project = try AdvisoryTestProject()
        defer { project.remove() }
        try project.write("// swift-tools-version: 6.0\n", to: "Package.swift")

        let result = try await DependencyAdvisoryChecker(environment: .fixed(
            bundled: try AdvisoryFixture.candidate(records: [])))
            .check(configuration: project.configuration())

        #expect(result.status == .skipped)
        #expect(result.diagnostics == [
            Diagnostic(
                severity: .note,
                message: "No Package.resolved was found under the project root, so there are no pins to check "
                    + "against advisories.",
                ruleId: "dep-advisory.coverage"),
        ])
    }

    @Test("a committed snapshot at the configured path is read, and used when it is the newer one")
    func committedSnapshot() async throws {
        let project = try AdvisoryTestProject()
        defer { project.remove() }
        try project.write(
            AdvisoryFixture.lockfileText([.version("zip", "https://github.com/marmelroy/Zip.git", "2.1.2")]),
            to: "Package.resolved")
        try project.write(
            try AdvisoryFixture.snapshotData(fetched: "2026-10-05", records: [AdvisoryFixture.zipTraversal]),
            to: "config/advisories.json")

        let checker = DependencyAdvisoryChecker(environment: .fixed(
            bundled: try AdvisoryFixture.candidate(fetched: "2026-09-01", records: [])))
        let result = try await checker.check(
            configuration: project.configuration(DependencyAuditorConfig(advisorySnapshotPath: "config/advisories.json")))

        #expect(result.diagnostics.map(\.ruleId) == ["dep-advisory.vulnerable-pin", "dep-advisory.coverage"])
        #expect(result.diagnostics.last?.message.hasSuffix(
            "snapshot osv/SwiftURL fetched 2026-10-05 (1 record, 0 withdrawn, 1 package; committed)") == true)
    }

    @Test("an acknowledgement in the configuration reaches the result as an override")
    func acknowledgementReachesTheResult() async throws {
        let project = try AdvisoryTestProject()
        defer { project.remove() }
        try project.write(
            AdvisoryFixture.lockfileText([.version("zip", "https://github.com/marmelroy/Zip.git", "2.1.2")]),
            to: "Package.resolved")

        let result = try await DependencyAdvisoryChecker(environment: .fixed(
            bundled: try AdvisoryFixture.candidate(records: [AdvisoryFixture.zipTraversal])))
            .check(configuration: project.configuration(DependencyAuditorConfig(acknowledgedAdvisories: [
                AcknowledgedAdvisory(
                    id: "GHSA-g454-wj9r-jpg4", package: "github.com/marmelroy/Zip",
                    reason: "Transitive via polar-ble-sdk. No code path here extracts an archive.",
                    until: "2027-01-01"),
            ])))

        #expect(result.status == .passed)
        #expect(result.overrides.map(\.ruleId) == ["dep-advisory.vulnerable-pin"])
    }

    /// The hermeticity contract's own test. A checker that may fail a build must give the same
    /// answer for the same tree whatever the calendar says.
    @Test("23. the same tree at two dates 400 days apart gives identical status and diagnostics")
    func determinism() async throws {
        let project = try AdvisoryTestProject()
        defer { project.remove() }
        try project.write(
            AdvisoryFixture.lockfileText([
                .version("swift-nio", "https://github.com/apple/swift-nio.git", "2.99.0"),
                .version("zip", "https://github.com/marmelroy/Zip.git", "2.1.2"),
            ]),
            to: "Package.resolved")
        let configuration = project.configuration(DependencyAuditorConfig(acknowledgedAdvisories: [
            AcknowledgedAdvisory(
                id: "GHSA-g454-wj9r-jpg4", package: "github.com/marmelroy/Zip",
                reason: "Transitive via polar-ble-sdk. No code path here extracts an archive.",
                until: "2026-12-01"),
        ]))
        let snapshot = try AdvisoryFixture.candidate(
            fetched: "2026-10-01", records: [AdvisoryFixture.nioHeaderBlocks, AdvisoryFixture.zipTraversal])

        let early = try await DependencyAdvisoryChecker(environment: .fixed(bundled: snapshot, today: "2026-10-06"))
            .check(configuration: configuration)
        // 400 days on: past the acknowledgement's `until`, and far past any staleness threshold.
        let late = try await DependencyAdvisoryChecker(environment: .fixed(bundled: snapshot, today: "2027-11-10"))
            .check(configuration: configuration)

        #expect(early.status == .failed)
        #expect(early.status == late.status)
        #expect(early.diagnostics == late.diagnostics)
        #expect(early.overrides == late.overrides)
        #expect(early.diagnostics.map(\.ruleId) == ["dep-advisory.vulnerable-pin", "dep-advisory.coverage"])
    }

    @Test("the hermetic checker never touches the transport")
    func hermeticCheckerStaysOffTheNetwork() async throws {
        let project = try AdvisoryTestProject()
        defer { project.remove() }
        try project.write(
            AdvisoryFixture.lockfileText([.version("swift-nio", "https://github.com/apple/swift-nio.git", "2.99.0")]),
            to: "Package.resolved")
        let transport = RecordingTransport { _ in Data() }

        _ = try await DependencyAdvisoryChecker(environment: .fixed(
            bundled: try AdvisoryFixture.candidate(records: [AdvisoryFixture.nioHeaderBlocks]), transport: transport))
            .check(configuration: project.configuration())
        _ = try await AdvisoryFreshnessChecker(environment: .fixed(
            bundled: try AdvisoryFixture.candidate(records: [AdvisoryFixture.nioHeaderBlocks]), transport: transport))
            .check(configuration: project.configuration())

        #expect(await transport.requests.isEmpty)
    }
}
