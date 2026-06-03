import Testing
import Foundation
@testable import IJSAggregator
import IJSSensor
import QualityGateTypes

@Suite("CalibrationReport")
struct CalibrationReportTests {

    private static let referenceDate: Date = {
        guard let date = ISO8601DateFormatter().date(from: "2026-06-03T14:30:00Z") else {
            preconditionFailure("Invalid reference date literal in test fixture")
        }
        return date
    }()

    // MARK: - Test helpers

    private func makeCalibration(
        ruleId: String,
        rootCause: String = "imprecise",
        failedStep: FiveStepStage = .diagnosis
    ) -> JudgmentCalibration {
        JudgmentCalibration(
            date: Self.referenceDate,
            decisionOwner: "jpurnell",
            practitioner: "claude",
            riskTier: .operational,
            rootCauseAnalysis: RootCauseAnalysis(
                proximateCause: "Override of \(ruleId): test justification",
                chainOfInquiry: ["test inquiry"],
                rootCause: rootCause,
                failedStep: failedStep,
                isRecurringPattern: false
            ),
            redTeamDissent: "test dissent",
            proposedPolicyUpdate: nil,
            pulseContribution: "test pulse"
        )
    }

    private func makeMetadata(
        checkerIds: [String] = ["safety"],
        overrideRuleIds: [String] = []
    ) -> CheckResultMetadata {
        let results = checkerIds.map { checkerId in
            CheckResult(
                checkerId: checkerId,
                status: .passed,
                diagnostics: [],
                duration: .seconds(1)
            )
        }
        let overrides = overrideRuleIds.map { ruleId in
            OverrideRecord(
                diagnosticOverride: DiagnosticOverride(
                    ruleId: ruleId,
                    justification: "test justification"
                ),
                author: "jpurnell",
                riskTier: .operational,
                authorityLevel: .practitioner
            )
        }
        return CheckResultMetadata(
            projectID: "test-project",
            timestamp: Self.referenceDate,
            environment: .local,
            decisionOwner: "jpurnell",
            results: results,
            overrides: overrides,
            riskTier: .operational,
            ethicalFlags: [],
            consistencyScore: nil
        )
    }

    // MARK: - Status: empty input

    @Test("Empty metadata and calibrations produce empty status")
    func statusEmpty() {
        let result = CalibrationReport.status(metadata: [], calibrations: [])
        #expect(result.isEmpty)
    }

    // MARK: - Status: override counts

    @Test("Counts overrides per ruleId from metadata")
    func statusOverrideCounts() {
        let metadata = [
            makeMetadata(overrideRuleIds: ["safety.force-unwrap", "safety.force-unwrap"]),
            makeMetadata(overrideRuleIds: ["concurrency.unchecked"]),
        ]
        let result = CalibrationReport.status(metadata: metadata, calibrations: [])
        let forceUnwrap = result.first { $0.ruleId == "safety.force-unwrap" }
        let unchecked = result.first { $0.ruleId == "concurrency.unchecked" }
        #expect(forceUnwrap?.overrideCount == 2)
        #expect(unchecked?.overrideCount == 1)
    }

    // MARK: - Status: unclassified calibrations

    @Test("Counts unclassified calibrations per rule")
    func statusUnclassifiedCount() {
        let calibrations = [
            makeCalibration(ruleId: "safety.force-unwrap", rootCause: "unclassified"),
        ]
        let result = CalibrationReport.status(metadata: [], calibrations: calibrations)
        let entry = result.first { $0.ruleId == "safety.force-unwrap" }
        #expect(entry?.unclassifiedCount == 1)
        #expect(entry?.calibratedCount == 1)
    }

    // MARK: - Status: sorted by ruleId

    @Test("Status results are sorted by ruleId")
    func statusSorted() {
        let calibrations = [
            makeCalibration(ruleId: "z-rule"),
            makeCalibration(ruleId: "a-rule"),
            makeCalibration(ruleId: "m-rule"),
        ]
        let result = CalibrationReport.status(metadata: [], calibrations: calibrations)
        let ids = result.map(\.ruleId)
        #expect(ids == ["a-rule", "m-rule", "z-rule"])
    }

    // MARK: - Coverage: empty input

    @Test("Empty metadata produces empty coverage")
    func coverageEmpty() {
        let result = CalibrationReport.coverage(metadata: [], calibrations: [])
        #expect(result.isEmpty)
    }

    // MARK: - Coverage: sample counting and preliminary validity

    @Test("Five metadata entries with safety checker give sampleCount 5 and preliminary validity")
    func coveragePreliminary() {
        let metadata = (0..<5).map { _ in makeMetadata(checkerIds: ["safety"]) }
        let result = CalibrationReport.coverage(metadata: metadata, calibrations: [])
        let safety = result.first { $0.checkerId == "safety" }
        #expect(safety?.sampleCount == 5)
        #expect(safety?.validity == .preliminary)
    }

    // MARK: - Coverage: valid threshold

    @Test("31 metadata entries give validity .valid")
    func coverageValid() {
        let metadata = (0..<31).map { _ in makeMetadata(checkerIds: ["safety"]) }
        let result = CalibrationReport.coverage(metadata: metadata, calibrations: [])
        let safety = result.first { $0.checkerId == "safety" }
        #expect(safety?.sampleCount == 31)
        #expect(safety?.validity == .valid)
    }

    // MARK: - Coverage: nil false-positive rate when no calibrations

    @Test("No calibrations for a checker gives nil falsePositiveRate")
    func coverageNilFPRate() {
        let metadata = [makeMetadata(checkerIds: ["safety"])]
        let result = CalibrationReport.coverage(metadata: metadata, calibrations: [])
        let safety = result.first { $0.checkerId == "safety" }
        #expect(safety?.falsePositiveRate == nil)
        #expect(safety?.calibrationCount == 0)
    }

    // MARK: - Coverage: false-positive rate calculation

    @Test("Three calibrations with two imprecise gives falsePositiveRate near 0.667")
    func coverageFPRate() {
        let calibrations = [
            makeCalibration(ruleId: "safety.force-unwrap", rootCause: "imprecise"),
            makeCalibration(ruleId: "safety.force-cast", rootCause: "imprecise"),
            makeCalibration(ruleId: "safety.try-bang", rootCause: "structural"),
        ]
        let metadata = [makeMetadata(checkerIds: ["safety"])]
        let result = CalibrationReport.coverage(metadata: metadata, calibrations: calibrations)
        let safety = result.first { $0.checkerId == "safety" }
        #expect(safety?.calibrationCount == 3)
        guard let rate = safety?.falsePositiveRate else {
            Issue.record("Expected non-nil falsePositiveRate")
            return
        }
        #expect(abs(rate - 2.0 / 3.0) < 1e-6)
    }

    // MARK: - Coverage: sorted by checkerId

    @Test("Coverage results are sorted by checkerId")
    func coverageSorted() {
        let metadata = [
            makeMetadata(checkerIds: ["z-checker", "a-checker", "m-checker"]),
        ]
        let result = CalibrationReport.coverage(metadata: metadata, calibrations: [])
        let ids = result.map(\.checkerId)
        #expect(ids == ["a-checker", "m-checker", "z-checker"])
    }

    // MARK: - Coverage: multiple checkers in same metadata

    @Test("Multiple checkers in one metadata entry are counted separately")
    func coverageMultipleCheckers() {
        let metadata = [
            makeMetadata(checkerIds: ["safety", "concurrency"]),
        ]
        let result = CalibrationReport.coverage(metadata: metadata, calibrations: [])
        #expect(result.count == 2)
        let safety = result.first { $0.checkerId == "safety" }
        let concurrency = result.first { $0.checkerId == "concurrency" }
        #expect(safety?.sampleCount == 1)
        #expect(concurrency?.sampleCount == 1)
    }
}
