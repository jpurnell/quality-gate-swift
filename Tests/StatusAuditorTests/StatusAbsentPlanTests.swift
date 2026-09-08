import Foundation
import QualityGateCore
import Testing
@testable import StatusAuditor

/// What `status` reports when the Master Plan is not there to be read.
///
/// This repository's plan moved to a private companion when the code was published, so an
/// absent plan stopped being a hypothetical and became the default for anyone cloning
/// without access. The checker used to answer `.passed` — the same defect a sweep had just
/// removed from eighteen other checkers, which reported success on files they never opened.
@Suite("StatusAuditor without a Master Plan")
struct StatusAbsentPlanTests {

    private static func emptyProject() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("status-absent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func run(in root: URL) async throws -> CheckResult {
        var configuration = Configuration()
        configuration.projectRoot = root
        return try await StatusAuditor().check(configuration: configuration)
    }

    @Test("An unreadable plan is skipped, never passed")
    func absentPlanIsSkipped() async throws {
        let root = try Self.emptyProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await Self.run(in: root)

        // `.passed` here would be a claim about drift between a plan and a tree, made without
        // ever opening the plan. `.skipped` is the only honest answer.
        #expect(result.status == .skipped)
        #expect(result.status != .passed)
    }

    @Test("The skip states the path it could not read")
    func skipNamesTheMissingPath() async throws {
        let root = try Self.emptyProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await Self.run(in: root)

        // A reader of a green run has to be able to tell *why* nothing ran, and where to look
        // — for this repository, that the companion is not cloned beside the code. So the
        // assertions are on the words that carry that, not on the note merely existing.
        #expect(result.diagnostics.count == 1)
        let note = try #require(result.diagnostics.first { $0.ruleId == "status.no-master-plan" })
        #expect(note.severity == .note)
        #expect(note.message.contains("Master Plan"))
        #expect(note.message.contains("this is not a pass"))
        #expect(note.message.contains("companion repository"))
    }

    @Test("Skipping is not a finding — the run stays clean")
    func skipRaisesNothingBlocking() async throws {
        let root = try Self.emptyProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await Self.run(in: root)

        // The distinction being drawn is between *passed* and *skipped*, not between passed
        // and failed. A contributor without the companion must still get a usable gate.
        #expect(!result.diagnostics.contains { $0.severity == .error || $0.severity == .warning })
    }
}
