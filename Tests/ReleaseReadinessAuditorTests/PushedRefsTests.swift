import Foundation
import Testing
@testable import QualityGateCore
@testable import ReleaseReadinessAuditor

/// Recognising a push boundary from the ref list git already hands the hook.
///
/// This parser decides whether a run may fail the gate on ref state, so its job is as much to
/// *refuse* input as to read it: everything that is not unmistakably git's `pre-push` format
/// leaves the run advisory.
@Suite("Pushed Refs")
struct PushedRefsTests {

    @Test("Git's pre-push format parses into refs")
    func parsesPrePushFormat() throws {
        let refs = try #require(PushedRefs.parse("""
        refs/heads/main aaaa111 refs/heads/main bbbb222
        refs/tags/v0.1.1 cccc333 refs/tags/v0.1.1 0000000000000000000000000000000000000000
        """))

        #expect(refs.count == 2)
        #expect(refs[0].localRef == "refs/heads/main")
        #expect(refs[1].tagName == "v0.1.1")
        #expect(refs[0].tagName == nil)
    }

    @Test("A deleted ref is recognised by its all-zero local sha")
    func deletionIsRecognised() throws {
        let refs = try #require(PushedRefs.parse(
            "refs/tags/v0.1.1 0000000000000000000000000000000000000000 refs/tags/v0.1.1 cccc333"))

        #expect(refs[0].isDeletion)
    }

    @Test("Empty input is not a push boundary")
    func emptyIsNotABoundary() {
        #expect(PushedRefs.parse("") == nil)
        #expect(PushedRefs.parse("\n  \n") == nil)
    }

    @Test("Anything that is not the ref format is refused outright")
    func foreignInputIsRefused() {
        // The reason this is strict: a run that mistakes piped YAML, a here-doc, or a CI log
        // for a ref list would start failing the gate on ref state in contexts that never
        // opted into it. One bad line rejects the whole input rather than being skipped.
        #expect(PushedRefs.parse("hello world") == nil)
        #expect(PushedRefs.parse("excludePatterns:\n  - Tests/**") == nil)
        #expect(PushedRefs.parse("refs/heads/main aaa refs/heads/main") == nil)
        #expect(PushedRefs.parse("""
        refs/heads/main aaaa111 refs/heads/main bbbb222
        not a ref line at all
        """) == nil)
    }

    @Test("A ref that does not start with refs/ is not git's format")
    func nonRefsPrefixIsRefused() {
        #expect(PushedRefs.parse("main aaaa111 main bbbb222") == nil)
    }

    @Test("A terminal is never read, so a manual run cannot hang waiting for EOF")
    func terminalIsNeverRead() {
        #expect(PushedRefs.fromStandardInput(isTerminal: true) == nil)
    }
}
