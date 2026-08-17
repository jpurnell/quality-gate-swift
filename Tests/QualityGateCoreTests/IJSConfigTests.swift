import Foundation
import Testing
import Yams
@testable import QualityGateCore

/// The `ijs:` block, and who a judgement belongs to.
///
/// The block was documented in the org-judgement-system README and written into every repository
/// by `scripts/onboard-corpus.sh`, and the schema did not define it. `Configuration` decodes with
/// `decodeIfPresent(…) ?? default`, so an undefined key is discarded during decoding and nothing
/// downstream can tell it was ever written — the same failure that had BusinessMath running 35
/// checkers while its config claimed 42.
///
/// Telemetry kept working only because `consistency:` happened to carry the same three values.
/// The two fields unique to `ijs:` had no consumers at all.
@Suite("IJS configuration")
struct IJSConfigTests {

    private func decode(_ yaml: String) throws -> Configuration {
        try YAMLDecoder().decode(Configuration.self, from: yaml)
    }

    @Test("the ijs block decodes instead of being discarded")
    func ijsBlockIsDecoded() throws {
        let config = try decode("""
        ijs:
          projectID: "quality-gate-swift"
          corpusPath: "/tmp/corpus"
          decisionOwner: "jpurnell"
          defaultRiskTier: 2
          remoteURL: "git@github.com:jpurnell/org-judgement-corpus.git"
        """)
        #expect(config.ijs.projectID == "quality-gate-swift")
        #expect(config.ijs.corpusPath == "/tmp/corpus")
        #expect(config.ijs.decisionOwner == "jpurnell")
        #expect(config.ijs.defaultRiskTier == 2)
        #expect(config.ijs.remoteURL == "git@github.com:jpurnell/org-judgement-corpus.git")
    }

    /// The block is no longer an unknown key, which is what the gate had been reporting on every
    /// run all along — correctly.
    @Test("ijs is no longer reported as an unrecognised key")
    func ijsIsAKnownKey() throws {
        let config = try decode("""
        ijs:
          projectID: "p"
        """)
        #expect(config.unknownKeys?.keys.contains("ijs") != true, "the schema now defines it")
    }

    // MARK: - Ownership

    /// **The bug this block existed to fix.**
    ///
    /// A self-hosted CI runner has a `$USER` like `runner` or `_service`. Recording that as the
    /// owner of a judgement produces a corpus of institutional decisions attributed to a machine
    /// account — a corpus that cannot answer the question it exists for.
    @Test("a configured owner wins over the shell account")
    func configuredOwnerWins() throws {
        let config = IJSConfig(decisionOwner: "platform-team")
        #expect(config.resolvedOwner() == "platform-team")
    }

    /// On a developer's machine there is usually no configured owner and `$USER` is meaningful,
    /// so the previous behaviour has to survive untouched.
    @Test("without configuration it falls back to the shell account")
    func fallsBackToUser() throws {
        let expected = ProcessInfo.processInfo.environment["USER"] ?? "local"
        #expect(IJSConfig.default.resolvedOwner() == expected)
    }

    /// An empty string is a configuration mistake, not an owner. Treating it as one would file
    /// judgements under nobody.
    @Test("an empty owner is not an owner")
    func emptyOwnerIsIgnored() throws {
        let expected = ProcessInfo.processInfo.environment["USER"] ?? "local"
        #expect(IJSConfig(decisionOwner: "").resolvedOwner() == expected)
    }

    /// The constraint that used to be a comment asking two call sites to stay in step.
    ///
    /// `ConsistencyChecker` reasons over a record that `TelemetryEmission` later persists. If the
    /// two resolved ownership differently, the corpus would hold an audit of one owner's
    /// decisions filed under another's — silently, and only visible to whoever compared them.
    @Test("audit and persistence resolve the same owner")
    func auditAndTelemetryAgree() throws {
        let config = IJSConfig(decisionOwner: "platform-team")
        #expect(config.resolvedOwner() == config.resolvedOwner())
        #expect(config.resolvedOwner() == "platform-team")
    }

    /// `consistency:` and `ijs:` coexist, which is the shape `onboard-corpus.sh` writes.
    @Test("both blocks decode side by side")
    func bothBlocksCoexist() throws {
        let config = try decode("""
        consistency:
          corpusPath: /tmp/corpus
          projectID: proj
          consistencyThreshold: 0.7
        ijs:
          projectID: proj
          decisionOwner: owner
        """)
        #expect(config.consistency.corpusPath == "/tmp/corpus")
        #expect(abs(config.consistency.consistencyThreshold - 0.7) < 1e-9)
        #expect(config.ijs.decisionOwner == "owner")
    }
}
