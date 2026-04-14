import Foundation
import Testing
@testable import QualityGateCore

/// Tests for FixResult, FileModification, and FixableChecker protocol types.
@Suite("FixableChecker Type Tests")
struct FixableCheckerTests {

    // MARK: - FixResult Tests

    @Test("FixResult.noChanges has no modifications or unfixed")
    func noChangesResult() {
        let result = FixResult.noChanges
        #expect(result.modifications.isEmpty)
        #expect(result.unfixed.isEmpty)
        #expect(!result.hasChanges)
        #expect(result.totalLinesChanged == 0)
    }

    @Test("FixResult.hasChanges is true when modifications exist")
    func hasChangesWithModifications() {
        let mod = FileModification(
            filePath: "README.md",
            description: "Updated test count",
            linesChanged: 1
        )
        let result = FixResult(modifications: [mod], unfixed: [])
        #expect(result.hasChanges)
    }

    @Test("FixResult.hasChanges is false with only unfixed diagnostics")
    func noChangesWithOnlyUnfixed() {
        let diag = Diagnostic(
            severity: .warning,
            message: "Cannot auto-fix",
            ruleId: "status.manual-fix-needed"
        )
        let result = FixResult(modifications: [], unfixed: [diag])
        #expect(!result.hasChanges)
        #expect(result.unfixed.count == 1)
    }

    @Test("FixResult.totalLinesChanged sums across all modifications")
    func totalLinesChangedSums() {
        let mods = [
            FileModification(filePath: "a.md", description: "fix a", linesChanged: 5),
            FileModification(filePath: "b.md", description: "fix b", linesChanged: 3),
            FileModification(filePath: "c.md", description: "fix c", linesChanged: 12),
        ]
        let result = FixResult(modifications: mods, unfixed: [])
        #expect(result.totalLinesChanged == 20)
    }

    // MARK: - FileModification Tests

    @Test("FileModification stores all fields")
    func fileModificationFields() {
        let mod = FileModification(
            filePath: "/project/docs/MASTER_PLAN.md",
            description: "Updated 3 module checkboxes",
            linesChanged: 3,
            backupPath: "/project/docs/MASTER_PLAN.md.2026-04-14.backup"
        )
        #expect(mod.filePath == "/project/docs/MASTER_PLAN.md")
        #expect(mod.description == "Updated 3 module checkboxes")
        #expect(mod.linesChanged == 3)
        #expect(mod.backupPath != nil)
    }

    @Test("FileModification backupPath defaults to nil")
    func fileModificationDefaultBackup() {
        let mod = FileModification(
            filePath: "README.md",
            description: "Updated test count",
            linesChanged: 1
        )
        #expect(mod.backupPath == nil)
    }

    // MARK: - Codable Tests

    @Test("FixResult round-trips through JSON encoding")
    func fixResultCodable() throws {
        let mod = FileModification(
            filePath: "MASTER_PLAN.md",
            description: "Updated checkboxes",
            linesChanged: 5,
            backupPath: "MASTER_PLAN.md.backup"
        )
        let diag = Diagnostic(
            severity: .warning,
            message: "Cannot auto-fix custom prose",
            ruleId: "status.manual"
        )
        let original = FixResult(modifications: [mod], unfixed: [diag])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FixResult.self, from: data)

        #expect(decoded == original)
        #expect(decoded.modifications.count == 1)
        #expect(decoded.unfixed.count == 1)
        #expect(decoded.hasChanges)
    }

    @Test("FileModification round-trips through JSON encoding")
    func fileModificationCodable() throws {
        let original = FileModification(
            filePath: "README.md",
            description: "Updated module list",
            linesChanged: 8,
            backupPath: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FileModification.self, from: data)

        #expect(decoded == original)
        #expect(decoded.backupPath == nil)
    }

    // MARK: - Equatable Tests

    @Test("FixResult equality compares all fields")
    func fixResultEquality() {
        let mod = FileModification(filePath: "a.md", description: "fix", linesChanged: 1)
        let a = FixResult(modifications: [mod], unfixed: [])
        let b = FixResult(modifications: [mod], unfixed: [])
        let c = FixResult(modifications: [], unfixed: [])

        #expect(a == b)
        #expect(a != c)
    }
}
