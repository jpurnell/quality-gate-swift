import Testing
import Foundation
@testable import QualityGateCore

/// Covers the decision table in `CorpusRegistrationReminder.md` §10.
///
/// The advisor is a pure function so that every case here is a value comparison with no
/// filesystem and no clock. The probe that supplies `presence` is tested separately.
@Suite("CorpusRegistrationAdvisor")
struct CorpusRegistrationAdvisorTests {

    // MARK: - Helpers

    private func config(
        corpusPath: String? = "/corpus",
        projectID: String? = "demo",
        optOut: String? = nil
    ) -> ConsistencyCheckerConfig {
        var c = ConsistencyCheckerConfig(corpusPath: corpusPath, projectID: projectID)
        c.optOut = optOut
        return c
    }

    // MARK: - The two states that produce a nudge

    @Test("A configured project that has never emitted is named")
    func configuredButSilentIsReported() {
        let advisory = CorpusRegistrationAdvisor.advise(
            config: config(projectID: "swiftOAuth"),
            presence: .absent,
            gatePassed: true
        )
        #expect(advisory == .configuredButSilent(projectID: "swiftOAuth"))
    }

    @Test("A project with no corpusPath at all is unconfigured, not silent")
    func noCorpusPathIsUnconfigured() {
        let advisory = CorpusRegistrationAdvisor.advise(
            config: config(corpusPath: nil),
            presence: nil,
            gatePassed: true
        )
        #expect(advisory == .unconfigured)
    }

    // MARK: - The states that must stay quiet

    @Test("A project that has emitted says nothing")
    func emittingIsSilent() {
        let advisory = CorpusRegistrationAdvisor.advise(
            config: config(),
            presence: .emitting,
            gatePassed: true
        )
        #expect(advisory == .silent)
    }

    @Test("A failing gate never asks about the corpus")
    func redGateIsSilent() {
        let advisory = CorpusRegistrationAdvisor.advise(
            config: config(),
            presence: .absent,
            gatePassed: false
        )
        #expect(advisory == .silent)
    }

    @Test("An opt-out with a reason silences the question")
    func optOutWithReasonIsSilent() {
        let advisory = CorpusRegistrationAdvisor.advise(
            config: config(optOut: "too early — revisit after v1"),
            presence: .absent,
            gatePassed: true
        )
        #expect(advisory == .silent)
    }

    // MARK: - The opt-out must be a reason, not a mute button

    @Test("An empty opt-out is not an opt-out", arguments: ["", "   ", "\t\n"])
    func emptyOptOutStillAdvises(_ blank: String) {
        let advisory = CorpusRegistrationAdvisor.advise(
            config: config(projectID: "demo", optOut: blank),
            presence: .absent,
            gatePassed: true
        )
        #expect(advisory == .configuredButSilent(projectID: "demo"))
    }

    // MARK: - An unreachable corpus is never a nudge

    @Test("An unreadable corpus reports itself rather than accusing the project")
    func unreachableCorpusIsNotANudge() {
        let advisory = CorpusRegistrationAdvisor.advise(
            config: config(),
            presence: .unreadable(reason: "No such file or directory"),
            gatePassed: true
        )
        #expect(advisory == .corpusUnreachable(path: "/corpus", reason: "No such file or directory"))
    }

    // MARK: - The repeat is the mechanism

    @Test("Identical inputs produce identical output, every run")
    func adviceIsStateless() {
        let first = CorpusRegistrationAdvisor.advise(
            config: config(projectID: "demo"), presence: .absent, gatePassed: true
        )
        let second = CorpusRegistrationAdvisor.advise(
            config: config(projectID: "demo"), presence: .absent, gatePassed: true
        )
        #expect(first == second)
        #expect(first == .configuredButSilent(projectID: "demo"))
    }
}
