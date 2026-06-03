import Testing
import Foundation
@testable import IJSAggregator
import IJSSensor
import QualityGateTypes

@Suite("CalibrationClassifier")
struct CalibrationClassifierTests {

    private static let referenceDate = ISO8601DateFormatter().date(
        from: "2026-06-03T14:30:00Z"
    )!

    private func makeOverride(
        ruleId: String = "safety.force-unwrap",
        justification: String,
        filePath: String? = "Sources/Foo.swift",
        lineNumber: Int? = 42
    ) -> DiagnosticOverride {
        DiagnosticOverride(
            ruleId: ruleId,
            justification: justification,
            filePath: filePath,
            lineNumber: lineNumber
        )
    }

    private func classify(_ overrides: [DiagnosticOverride]) -> [JudgmentCalibration] {
        CalibrationClassifier.classify(
            overrides: overrides,
            decisionOwner: "jpurnell",
            practitioner: "claude",
            riskTier: .operational,
            timestamp: Self.referenceDate
        )
    }

    // MARK: - Empty input

    @Test("Empty overrides produce empty calibrations")
    func emptyOverrides() {
        let result = classify([])
        #expect(result.isEmpty)
    }

    // MARK: - False positive patterns

    @Test("Classifies 'hardcoded' justification as false-positive")
    func falsePositiveHardcoded() {
        let cal = classify([makeOverride(
            justification: "SAFETY: hardcoded executable path /usr/bin/git"
        )])
        #expect(cal.count == 1)
        #expect(cal[0].rootCauseAnalysis.rootCause == "imprecise")
        #expect(cal[0].rootCauseAnalysis.failedStep == .diagnosis)
    }

    @Test("Classifies 'constant' from silent: prefix as false-positive")
    func falsePositiveConstant() {
        let cal = classify([makeOverride(
            ruleId: "logging.silent-try",
            justification: "silent: constant regex pattern"
        )])
        #expect(cal.count == 1)
        #expect(cal[0].rootCauseAnalysis.rootCause == "imprecise")
    }

    @Test("Classifies 'validated' as false-positive")
    func falsePositiveValidated() {
        let cal = classify([makeOverride(
            justification: "SAFETY: CLI reads Package.swift from cwd; validated path"
        )])
        #expect(cal.count == 1)
        #expect(cal[0].rootCauseAnalysis.rootCause == "imprecise")
    }

    @Test("Classifies 'guaranteed' as false-positive")
    func falsePositiveGuaranteed() {
        let cal = classify([makeOverride(
            justification: "SAFETY: guard on line 42 guaranteed non-nil"
        )])
        #expect(cal.count == 1)
        #expect(cal[0].rootCauseAnalysis.rootCause == "imprecise")
    }

    // MARK: - Design constraint patterns

    @Test("Classifies 'CLI tool' justification as design-constraint")
    func designConstraintCLI() {
        let cal = classify([makeOverride(
            justification: "SAFETY: CLI tool creates local project directory"
        )])
        #expect(cal.count == 1)
        #expect(cal[0].rootCauseAnalysis.rootCause == "structural")
        #expect(cal[0].rootCauseAnalysis.failedStep == .design)
    }

    @Test("Classifies 'required by protocol' as design-constraint")
    func designConstraintProtocol() {
        let cal = classify([makeOverride(
            justification: "Justification: required by protocol conformance"
        )])
        #expect(cal.count == 1)
        #expect(cal[0].rootCauseAnalysis.rootCause == "structural")
    }

    // MARK: - Deferred patterns

    @Test("Classifies TODO as deferred")
    func deferredTodo() {
        let cal = classify([makeOverride(
            justification: "TODO: will fix in next sprint"
        )])
        #expect(cal.count == 1)
        #expect(cal[0].rootCauseAnalysis.rootCause == "deferred")
        #expect(cal[0].rootCauseAnalysis.failedStep == .doing)
    }

    @Test("Classifies 'temporary workaround' as deferred")
    func deferredWorkaround() {
        let cal = classify([makeOverride(
            justification: "temporary workaround for upstream bug"
        )])
        #expect(cal.count == 1)
        #expect(cal[0].rootCauseAnalysis.rootCause == "deferred")
    }

    // MARK: - Third-party patterns

    @Test("Classifies 'external library' as third-party")
    func thirdPartyExternal() {
        let cal = classify([makeOverride(
            justification: "external library does not support Sendable"
        )])
        #expect(cal.count == 1)
        #expect(cal[0].rootCauseAnalysis.rootCause == "external")
        #expect(cal[0].rootCauseAnalysis.failedStep == .design)
    }

    @Test("Classifies 'upstream dependency' as third-party")
    func thirdPartyUpstream() {
        let cal = classify([makeOverride(
            justification: "upstream dependency requires this cast"
        )])
        #expect(cal.count == 1)
        #expect(cal[0].rootCauseAnalysis.rootCause == "external")
    }

    // MARK: - Acceptable risk patterns

    @Test("Classifies 'acknowledged risk' as acceptable-risk")
    func acceptableRisk() {
        let cal = classify([makeOverride(
            justification: "acknowledged risk: race condition acceptable for debug counter"
        )])
        #expect(cal.count == 1)
        #expect(cal[0].rootCauseAnalysis.rootCause == "expedient")
        #expect(cal[0].rootCauseAnalysis.failedStep == .diagnosis)
    }

    // MARK: - Unclassified

    @Test("Classifies unrecognized text as unclassified")
    func unclassified() {
        let cal = classify([makeOverride(
            justification: "some random text that matches no pattern"
        )])
        #expect(cal.count == 1)
        #expect(cal[0].rootCauseAnalysis.rootCause == "unclassified")
        #expect(cal[0].rootCauseAnalysis.failedStep == .diagnosis)
    }

    // MARK: - Case insensitivity

    @Test("Classification is case-insensitive")
    func caseInsensitive() {
        let cal = classify([makeOverride(
            justification: "SAFETY: HARDCODED value that NEVER changes"
        )])
        #expect(cal.count == 1)
        #expect(cal[0].rootCauseAnalysis.rootCause == "imprecise")
    }

    // MARK: - Multiple overrides

    @Test("Multiple overrides produce multiple calibrations")
    func multipleOverrides() {
        let overrides = [
            makeOverride(ruleId: "safety.force-unwrap",
                         justification: "SAFETY: hardcoded path"),
            makeOverride(ruleId: "concurrency.unchecked",
                         justification: "TODO: will fix next sprint"),
            makeOverride(ruleId: "logging.silent-try",
                         justification: "some unrecognized text"),
        ]
        let cals = classify(overrides)
        #expect(cals.count == 3)
        #expect(cals[0].rootCauseAnalysis.rootCause == "imprecise")
        #expect(cals[1].rootCauseAnalysis.rootCause == "deferred")
        #expect(cals[2].rootCauseAnalysis.rootCause == "unclassified")
    }

    // MARK: - Metadata pass-through

    @Test("Calibration carries correct metadata from parameters")
    func metadataPassthrough() {
        let cal = classify([makeOverride(
            justification: "SAFETY: hardcoded path"
        )])
        #expect(cal.count == 1)
        #expect(cal[0].decisionOwner == "jpurnell")
        #expect(cal[0].practitioner == "claude")
        #expect(cal[0].riskTier == .operational)
        #expect(cal[0].date == Self.referenceDate)
    }

    @Test("Calibration has non-empty redTeamDissent")
    func redTeamDissentPopulated() {
        let cal = classify([makeOverride(
            justification: "SAFETY: hardcoded path"
        )])
        #expect(!cal[0].redTeamDissent.isEmpty)
    }

    @Test("Calibration has non-empty pulseContribution")
    func pulseContributionPopulated() {
        let cal = classify([makeOverride(
            justification: "SAFETY: hardcoded path"
        )])
        #expect(!cal[0].pulseContribution.isEmpty)
    }

    @Test("isRecurringPattern defaults to false")
    func isRecurringPatternFalse() {
        let cal = classify([makeOverride(
            justification: "SAFETY: hardcoded path"
        )])
        #expect(cal[0].rootCauseAnalysis.isRecurringPattern == false)
    }

    @Test("chainOfInquiry is non-empty")
    func chainOfInquiryPopulated() {
        let cal = classify([makeOverride(
            justification: "SAFETY: hardcoded path"
        )])
        #expect(!cal[0].rootCauseAnalysis.chainOfInquiry.isEmpty)
    }

    @Test("proximateCause references the rule ID")
    func proximateCauseReferencesRule() {
        let cal = classify([makeOverride(
            ruleId: "safety.force-unwrap",
            justification: "SAFETY: hardcoded path"
        )])
        #expect(cal[0].rootCauseAnalysis.proximateCause.contains("safety.force-unwrap"))
    }
}
