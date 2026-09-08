import Testing
import Foundation
@testable import QualityGateCore

/// The config half of onboarding. Kept as a pure string transform so the interesting
/// cases — idempotence, and never emitting a block nothing reads — are assertable without
/// touching disk.
@Suite("CorpusConfigWriter")
struct CorpusConfigWriterTests {

    @Test("An absent config gains a consistency block")
    func createsConfigWhenAbsent() throws {
        let result = CorpusConfigWriter.ensureConsistencyBlock(
            in: nil, corpusPath: "/corpus", projectID: "demo"
        )
        let content = try #require(result.content)
        #expect(result.changed)
        #expect(content.contains("consistency:"))
        #expect(content.contains("corpusPath: /corpus"))
        #expect(content.contains("projectID: demo"))
    }

    @Test("An existing config without the block gains one, keeping what was there")
    func appendsToExistingConfig() throws {
        let existing = "build:\n  configuration: debug\n"
        let result = CorpusConfigWriter.ensureConsistencyBlock(
            in: existing, corpusPath: "/corpus", projectID: "demo"
        )
        let content = try #require(result.content)
        #expect(result.changed)
        #expect(content.contains("build:"))
        #expect(content.contains("configuration: debug"))
        #expect(content.contains("consistency:"))
    }

    @Test("A config that already has the block is left exactly alone")
    func idempotentWhenBlockPresent() {
        let existing = "consistency:\n  corpusPath: /elsewhere\n  projectID: other\n"
        let result = CorpusConfigWriter.ensureConsistencyBlock(
            in: existing, corpusPath: "/corpus", projectID: "demo"
        )
        #expect(!result.changed)
        #expect(result.content == nil, "no rewrite should be proposed when the block exists")
    }

    @Test("A CRLF config is still recognised as already having the block")
    func idempotentWithWindowsLineEndings() {
        // The original implementation split on "\n". In Swift "\r\n" is ONE Character, so a
        // CRLF file came back as a single element, the prefix check failed, and onboarding
        // appended a second `consistency:` block — inverting the guarantee the code above
        // promises. Nothing threw; the config simply became invalid.
        // `consistency:` deliberately NOT the first line. With the "\n" split the whole file
        // collapses to one element; if that element happened to start with `consistency:` the
        // prefix check passed by accident and the defect stayed hidden. Putting another key
        // first is what makes this test able to fail.
        let existing = "build:\r\n  configuration: debug\r\nconsistency:\r\n  corpusPath: /elsewhere\r\n"
        let result = CorpusConfigWriter.ensureConsistencyBlock(
            in: existing, corpusPath: "/corpus", projectID: "demo"
        )
        #expect(!result.changed)
        #expect(result.content == nil, "a CRLF config already declaring the block must not gain a second one")
    }

    // MARK: - The block nothing reads

    @Test("An ijs: block is never written", arguments: [nil, "build:\n  configuration: debug\n"])
    func neverWritesIJSBlock(_ existing: String?) throws {
        let result = CorpusConfigWriter.ensureConsistencyBlock(
            in: existing, corpusPath: "/corpus", projectID: "demo"
        )
        let content = try #require(result.content)
        // scripts/onboard-corpus.sh appended `ijs:` alongside `consistency:` for every
        // project it touched. Configuration decodes 30 sub-config blocks and `ijs` is not
        // one of them, so Codable drops it silently — inert config that reads as
        // authoritative. Onboarding must not propagate it.
        #expect(!content.contains("ijs:"))
    }

    @Test("A file ending without a newline still yields a parseable append")
    func handlesMissingTrailingNewline() throws {
        let result = CorpusConfigWriter.ensureConsistencyBlock(
            in: "build:\n  configuration: debug", corpusPath: "/corpus", projectID: "demo"
        )
        let content = try #require(result.content)
        #expect(content.contains("debug\n"), "must not glue the block onto the last line")
        #expect(content.contains("\nconsistency:"))
    }
}
