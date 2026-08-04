import Foundation
import QualityGateCore
import Testing
@testable import StatusAuditor

/// StatusAuditor is *mixed*: documented-vs-actual drift is derivable from the
/// working tree and must keep blocking, while "Last Updated" staleness is a
/// function of the calendar and must not. A byte-identical commit that passed
/// today has to still pass in a year.
@Suite("StatusAuditor hermeticity")
struct StatusHermeticityTests {

    private static let planPath = "/tmp/00_MASTER_PLAN.md"

    private static func validate(
        documented: [DocumentedModuleStatus] = [],
        actual: [String: ActualModuleState] = [:],
        phases: [DocumentedPhase] = [],
        lastUpdated: (date: String, line: Int)? = nil,
        now: Date
    ) -> [Diagnostic] {
        StatusValidator.validate(
            documented: documented,
            actual: actual,
            phases: phases,
            lastUpdated: lastUpdated,
            masterPlanPath: planPath,
            configuration: StatusAuditorConfig(),
            now: now)
    }

    private static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: iso) ?? Date(timeIntervalSince1970: 0)
    }

    // MARK: - Temporal findings do not block

    @Test("Staleness is a note, not a warning — a stale plan never fails the gate")
    func stalenessIsANote() {
        // 200 days past the 90-day default threshold.
        let diagnostics = Self.validate(
            lastUpdated: (date: "2026-01-01", line: 3),
            now: Self.date("2026-08-04"))

        let stale = diagnostics.filter { $0.ruleId == "status.last-updated-stale" }
        #expect(stale.count == 1)
        #expect(stale.first?.severity == .note)
        // The finding still says what it said — only its authority is removed.
        #expect(stale.first?.message.contains("2026-01-01") == true)
        #expect(stale.first?.lineNumber == 3)
    }

    @Test("A fresh plan produces no staleness finding at all")
    func freshPlanIsClean() {
        let diagnostics = Self.validate(
            lastUpdated: (date: "2026-08-01", line: 3),
            now: Self.date("2026-08-04"))

        #expect(!diagnostics.contains { $0.ruleId == "status.last-updated-stale" })
    }

    // MARK: - Hermetic findings still block (the regression that matters most)

    @Test("Documented module missing from Sources/ still warns")
    func moduleDriftStillWarns() {
        let diagnostics = Self.validate(
            documented: [
                DocumentedModuleStatus(
                    name: "GhostModule", isComplete: true, description: "",
                    claimedTestCount: nil, line: 12)
            ],
            actual: [:],
            now: Self.date("2026-08-04"))

        let drift = diagnostics.filter { $0.ruleId == "status.module-marked-complete-missing" }
        #expect(drift.count == 1)
        #expect(drift.first?.severity == .warning)
    }

    // MARK: - Determinism

    @Test("Same tree, same verdict — 400 days apart")
    func verdictIsTimeInvariant() {
        let documented = [
            DocumentedModuleStatus(
                    name: "GhostModule", isComplete: true, description: "",
                    claimedTestCount: nil, line: 12)
        ]

        let early = Self.validate(
            documented: documented,
            lastUpdated: (date: "2026-01-01", line: 3),
            now: Self.date("2026-08-04"))
        let late = Self.validate(
            documented: documented,
            lastUpdated: (date: "2026-01-01", line: 3),
            now: Self.date("2027-09-08"))

        // Messages legitimately differ (the day count moves); the rules that fired and
        // the severity each fired at must not, because the tree did not change.
        func signature(_ diagnostics: [Diagnostic]) -> [String] {
            diagnostics.map { "\($0.ruleId ?? "?"):\($0.severity)" }.sorted()
        }
        #expect(signature(early) == signature(late))

        // And the blocking subset — the part that decides pass/fail — is identical.
        func blocking(_ diagnostics: [Diagnostic]) -> [String] {
            diagnostics
                .filter { $0.severity == .error || $0.severity == .warning }
                .compactMap(\.ruleId)
                .sorted()
        }
        #expect(blocking(early) == blocking(late))
    }

    @Test("StatusAuditor declares itself hermetic — its drift rules must keep gating")
    func auditorIsHermetic() {
        #expect(StatusAuditor().hermeticity == .hermetic)
    }
}
