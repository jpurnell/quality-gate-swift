import Testing
import Foundation
@testable import QualityGateCore

/// The advisory's text is load-bearing, so it is asserted rather than eyeballed.
///
/// Three properties matter and each has a reason on the page in
/// `CorpusRegistrationReminder.md`: it says nothing is wrong, because nothing is; it gives
/// the command rather than the concept, because "register with the corpus" is the exact
/// instruction that produced three unregistered projects; and it never offers the
/// onboarding command when onboarding is not the answer.
@Suite("CorpusAdvisory rendering")
struct CorpusAdvisoryRenderingTests {

    @Test("Silence renders nothing at all")
    func silentRendersNil() {
        #expect(CorpusAdvisory.silent.rendered() == nil)
    }

    @Test("The nudge names the project, says nothing is wrong, and gives the command")
    func configuredButSilentRendersFully() throws {
        let text = try #require(CorpusAdvisory.configuredButSilent(projectID: "swiftOAuth").rendered())
        #expect(text.contains("swiftOAuth"))
        #expect(text.contains("Nothing is wrong"))
        #expect(text.contains("quality-gate onboard-corpus"))
        #expect(text.contains("optOut"))
    }

    @Test("An unconfigured project is offered the same command")
    func unconfiguredOffersOnboarding() throws {
        let text = try #require(CorpusAdvisory.unconfigured.rendered())
        #expect(text.contains("quality-gate onboard-corpus"))
    }

    @Test("An unreachable corpus never offers onboarding")
    func unreachableNeverOffersOnboarding() throws {
        let text = try #require(
            CorpusAdvisory.corpusUnreachable(path: "/corpus", reason: "not found").rendered()
        )
        #expect(text.contains("/corpus"))
        #expect(text.contains("not found"))
        #expect(!text.contains("onboard-corpus"))
    }

    @Test("Every rendered advisory is a delimited block, not a note")
    func renderedAdvisoriesAreBlocks() throws {
        let advisories: [CorpusAdvisory] = [
            .unconfigured,
            .configuredButSilent(projectID: "demo"),
            .corpusUnreachable(path: "/corpus", reason: "not found")
        ]
        for advisory in advisories {
            let text = try #require(advisory.rendered())
            #expect(text.contains("Corpus"), "block heading missing from \(advisory)")
            #expect(!text.contains("note:"), "must not masquerade as a note: \(advisory)")
        }
    }
}
