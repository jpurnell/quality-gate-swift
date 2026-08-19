import Foundation
import Testing
@testable import QualityGateCore

/// A survey profile must not run the code it surveys.
///
/// `--profile code` was documented as "checkers that judge the source and write nothing" and
/// included `build`, `test` and `xcode-build`. The declarations were not wrong —
/// `CheckerEffect.readOnly` deliberately excludes compilation output — the *axis* was missing:
/// nothing answered whether a checker executes the analysed project's own code. Pointed at
/// Alamofire, `test` ran its suite for ten minutes making real network calls.
///
/// These assert against the declared property across the whole registry, never against a list
/// of ids, because the derivation is the point: a list fails silently whichever way it is
/// written.
@Suite("Survey profile — nothing in `code` executes the surveyed package")
struct SurveyProfileExecutionTests {

    /// A checker stub that declares whatever the test needs.
    private struct Stub: QualityChecker {
        let id: String
        var name: String { id }
        var summary: String { "stub" }
        var category: CheckerCategory { .specialty }
        let kind: CheckerKind
        let effect: CheckerEffect
        let executesProjectCode: Bool
        let hermeticity = Hermeticity.hermetic
        func check(configuration: Configuration) async throws -> CheckResult {
            CheckResult(checkerId: id, status: .passed, diagnostics: [], duration: .zero)
        }
    }

    @Test("A code-kind, read-only checker that executes project code is excluded from `code`")
    func executingCheckerIsExcluded() {
        let executing = Stub(id: "build-like", kind: .code, effect: .readOnly, executesProjectCode: true)
        #expect(!CheckerProfile.code.includes(executing),
                "a checker that runs the surveyed package's code must not be in a survey profile")
    }

    @Test("An otherwise identical checker that does not execute is included")
    func nonExecutingCheckerIsIncluded() {
        let analysing = Stub(id: "safety-like", kind: .code, effect: .readOnly, executesProjectCode: false)
        #expect(CheckerProfile.code.includes(analysing),
                "the new axis must not exclude ordinary static analysis")
    }

    /// The regression guard: the other two axes still decide.
    @Test("The existing axes are unchanged")
    func existingAxesStillApply() {
        #expect(!CheckerProfile.code.includes(
            Stub(id: "docs", kind: .documentation, effect: .readOnly, executesProjectCode: false)))
        #expect(!CheckerProfile.code.includes(
            Stub(id: "writer", kind: .code, effect: .writesOutsideTree, executesProjectCode: false)))
    }

    @Test("`all` still includes an executing checker")
    func allIncludesEverything() {
        #expect(CheckerProfile.all.includes(
            Stub(id: "build-like", kind: .code, effect: .readOnly, executesProjectCode: true)),
            "`all` means all; only the survey profiles narrow")
    }
}
